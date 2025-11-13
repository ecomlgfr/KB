#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          REDIS_QUICK_FIX - Correction rapide Redis                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

# Charger les credentials
source "$CREDS_DIR/redis.env"

echo ""
echo "Le script précédent semble bloqué. Terminons l'installation..."
echo ""

# Tuer le script bloqué
pkill -f redis_ha_complete_install.sh 2>/dev/null

MASTER_IP=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")

# 1. Vérification rapide du cluster
echo "1. État actuel du cluster Redis..."
echo ""

for host in redis-01 redis-02 redis-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  $host: "
    
    # Test avec timeout court
    if timeout 2 redis-cli -h "$IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        ROLE=$(timeout 2 redis-cli -h "$IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        echo -e "$OK (role: $ROLE)"
    else
        echo -e "$KO"
    fi
done

echo ""

# 2. Configuration rapide des Load Balancers
echo "2. Configuration des Load Balancers HAProxy..."
echo ""

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  Configuration $host..."
    
    # Copier les credentials
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "mkdir -p /opt/keybuzz-installer/credentials" 2>/dev/null
    scp -q "$CREDS_DIR/redis.env" root@"$IP_PRIV":/opt/keybuzz-installer/credentials/ 2>/dev/null
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$MASTER_IP" "$REDIS_PASSWORD" <<'HAPROXY_FIX'
MASTER_IP="$1"
REDIS_PASSWORD="$2"
BASE="/opt/keybuzz/redis-lb"

# Nettoyer
docker stop haproxy-redis 2>/dev/null
docker rm haproxy-redis 2>/dev/null

# Créer structure
mkdir -p "$BASE/config"

# Config HAProxy simple
cat > "$BASE/config/haproxy-redis.cfg" <<EOF
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global

listen redis_master
    bind 0.0.0.0:6379
    mode tcp
    balance first
    option tcp-check
    tcp-check send AUTH\ ${REDIS_PASSWORD}\r\n
    tcp-check expect string +OK
    tcp-check send PING\r\n
    tcp-check expect string +PONG
    tcp-check send QUIT\r\n
    tcp-check expect string +OK
    server redis-master $MASTER_IP:6379 check inter 2s fall 3 rise 2
EOF

# Démarrer HAProxy
docker run -d \
  --name haproxy-redis \
  --restart unless-stopped \
  --network host \
  -v ${BASE}/config/haproxy-redis.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.9-alpine

echo "    ✓ Configuré"
HAPROXY_FIX
done

echo ""
sleep 5

# 3. Test final
echo "3. Tests finaux..."
echo ""

echo -n "  HAProxy-01: "
timeout 2 redis-cli -h 10.0.0.11 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG" && echo -e "$OK" || echo -e "$KO"

echo -n "  HAProxy-02: "
timeout 2 redis-cli -h 10.0.0.12 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG" && echo -e "$OK" || echo -e "$KO"

echo -n "  Load Balancer Hetzner (10.0.0.10): "
timeout 2 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"

if timeout 2 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
    echo -e "$OK REDIS HA OPÉRATIONNEL"
    echo ""
    echo "Configuration:"
    echo "  • Endpoint: 10.0.0.10:6379"
    echo "  • Credentials: $CREDS_DIR/redis.env"
    echo ""
    echo "Test de connexion:"
    echo '  source /opt/keybuzz-installer/credentials/redis.env'
    echo '  redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning'
else
    echo -e "$KO Redis non accessible"
fi
echo "═══════════════════════════════════════════════════════════════════"
