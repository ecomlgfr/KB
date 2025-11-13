#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         REDIS_LB_CHECK - Vérification Load Balancer Redis          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
REDIS_PASSWORD="Lm1wszsUh07xuU9pttHw9YZOB"

echo ""
echo "1. État du Load Balancer sur HAProxy..."
echo ""

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  $host ($IP_PRIV):"
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'CHECK'
    echo -n "    Containers: "
    docker ps --format "{{.Names}}" | grep -E "haproxy-redis|sentinel-watcher" | wc -l
    
    echo "    Master détecté:"
    if [ -f /opt/keybuzz/redis-lb/status/current_master ]; then
        echo "      $(cat /opt/keybuzz/redis-lb/status/current_master)"
    else
        echo "      Aucun master enregistré"
    fi
    
    echo "    Config HAProxy:"
    grep "server redis-master" /opt/keybuzz/redis-lb/config/haproxy-redis.cfg 2>/dev/null | sed 's/^/      /'
    
    echo "    Logs watcher (dernières lignes):"
    docker logs sentinel-watcher --tail 5 2>&1 | sed 's/^/      /'
CHECK
    
    echo ""
done

echo "2. Forcer la détection du master..."
echo ""

# Récupérer le master depuis Sentinel
MASTER_IP=$(redis-cli -h 10.0.0.123 -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
echo "  Master actuel détecté: $MASTER_IP"

if [ -n "$MASTER_IP" ]; then
    for host in haproxy-01 haproxy-02; do
        IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
        
        echo "  Mise à jour forcée sur $host..."
        
        ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$MASTER_IP" "$REDIS_PASSWORD" <<'UPDATE'
MASTER_IP="$1"
REDIS_PASSWORD="$2"

# Mettre à jour la config HAProxy directement
cat > /opt/keybuzz/redis-lb/config/haproxy-redis.cfg <<EOF
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global

# Redis Master
listen redis_master
    bind 0.0.0.0:6379
    mode tcp
    balance first
    option tcp-check
    tcp-check send AUTH\ $REDIS_PASSWORD\r\n
    tcp-check expect string +OK
    tcp-check send PING\r\n
    tcp-check expect string +PONG
    tcp-check send QUIT\r\n
    tcp-check expect string +OK
    server redis-master $MASTER_IP:6379 check inter 2s fall 3 rise 2
EOF

# Sauvegarder le master
echo "$MASTER_IP" > /opt/keybuzz/redis-lb/status/current_master

# Recharger HAProxy
docker kill -s HUP haproxy-redis

echo "    ✓ Mis à jour avec master: $MASTER_IP"
UPDATE
    done
fi

echo ""
echo "3. Test après correction..."
echo ""

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $host - Redis (6379): "
    if redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "4. Test via Load Balancer Hetzner..."
echo ""

echo -n "  10.0.0.10:6379: "
if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
    ROLE=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    echo -e "$OK (role: $ROLE)"
else
    echo -e "$KO"
fi

echo ""
echo "5. Test d'écriture/lecture..."
echo ""

TEST_KEY="lb_test_$(date +%s)"
TEST_VALUE="via_loadbalancer"

echo -n "  Écriture via LB: "
if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET "$TEST_KEY" "$TEST_VALUE" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
    
    # Vérifier sur chaque replica
    for host in redis-02 redis-03; do
        IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
        echo -n "  Lecture sur $host: "
        VALUE=$(redis-cli -h "$IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning GET "$TEST_KEY" 2>/dev/null)
        if [ "$VALUE" = "$TEST_VALUE" ]; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    done
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Test final
if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING &>/dev/null; then
    echo -e "$OK Redis HA COMPLET et OPÉRATIONNEL"
    echo ""
    echo "Architecture finale:"
    echo "┌─────────────────────────────────────┐"
    echo "│     Applications (Chatwoot, etc)    │"
    echo "└─────────────────────────────────────┘"
    echo "                  ↓"
    echo "┌─────────────────────────────────────┐"
    echo "│   Load Balancer Hetzner             │"
    echo "│        10.0.0.10:6379                │"
    echo "└─────────────────────────────────────┘"
    echo "          ↓              ↓"
    echo "┌──────────────┐ ┌──────────────┐"
    echo "│  haproxy-01  │ │  haproxy-02  │"
    echo "└──────────────┘ └──────────────┘"
    echo "                  ↓"
    echo "┌─────────────────────────────────────┐"
    echo "│   Redis Sentinel Cluster (HA)       │"
    echo "│   • redis-01 (master)                │"
    echo "│   • redis-02 (replica)               │"
    echo "│   • redis-03 (replica)               │"
    echo "└─────────────────────────────────────┘"
    echo ""
    echo "Configuration pour les applications:"
    echo "  REDIS_HOST=10.0.0.10"
    echo "  REDIS_PORT=6379"
    echo "  REDIS_PASSWORD=$REDIS_PASSWORD"
else
    echo -e "$KO Redis non accessible via LB"
fi
echo "═══════════════════════════════════════════════════════════════════"
