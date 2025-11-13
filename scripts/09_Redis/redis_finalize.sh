#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║            REDIS_FINALIZE - Finalisation cluster Redis             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

# Récupérer le mot de passe généré depuis les logs
echo "1. Récupération du mot de passe Redis existant..."
REDIS_PASSWORD="Lm1wszsUh07xuU9pttHw9YZOB"

# Mettre à jour les credentials
cat > "$CREDS_DIR/redis.env" <<EOF
export REDIS_PASSWORD="$REDIS_PASSWORD"
export REDIS_MASTER_NAME="mymaster"
export REDIS_SENTINEL_QUORUM="2"
EOF
chmod 600 "$CREDS_DIR/redis.env"

# Mettre à jour secrets.json
if [ -f "$CREDS_DIR/secrets.json" ]; then
    jq ".redis_password = \"$REDIS_PASSWORD\"" "$CREDS_DIR/secrets.json" > /tmp/secrets.tmp && \
    mv /tmp/secrets.tmp "$CREDS_DIR/secrets.json"
else
    echo "{\"redis_password\": \"$REDIS_PASSWORD\"}" | jq '.' > "$CREDS_DIR/secrets.json"
fi
chmod 600 "$CREDS_DIR/secrets.json"

echo "  Mot de passe: $REDIS_PASSWORD (sauvegardé)"
echo ""

# Master IP
MASTER_IP=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")

echo "2. Nettoyage et configuration des nœuds..."
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  Configuration $host ($IP_PRIV)..."
    
    # Déterminer le rôle
    if [ "$host" == "redis-01" ]; then
        ROLE="master"
    else
        ROLE="replica"
    fi
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" "$MASTER_IP" "$ROLE" "$IP_PRIV" <<'FINALIZE'
REDIS_PASSWORD="$1"
MASTER_IP="$2"
ROLE="$3"
MY_IP="$4"
BASE="/opt/keybuzz/redis"

# Arrêter tous les containers Redis existants
docker stop $(docker ps -aq --filter "name=redis" --filter "name=sentinel") 2>/dev/null
docker rm $(docker ps -aq --filter "name=redis" --filter "name=sentinel") 2>/dev/null

# Configuration Redis finale
cat > "$BASE/config/redis.conf" <<EOF
bind 0.0.0.0
protected-mode no
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300

requirepass $REDIS_PASSWORD
masterauth $REDIS_PASSWORD

dir /data
dbfilename dump.rdb
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

databases 16
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes

maxclients 10000
maxmemory-policy allkeys-lru

replica-read-only yes
replica-serve-stale-data yes
EOF

# Ajouter slaveof si replica
if [ "$ROLE" == "replica" ]; then
    echo "slaveof $MASTER_IP 6379" >> "$BASE/config/redis.conf"
fi

# Configuration Sentinel
cat > "$BASE/config/sentinel.conf" <<EOF
port 26379
bind 0.0.0.0
protected-mode no

sentinel monitor mymaster $MASTER_IP 6379 2
sentinel auth-pass mymaster $REDIS_PASSWORD
sentinel down-after-milliseconds mymaster 5000
sentinel parallel-syncs mymaster 1
sentinel failover-timeout mymaster 60000

sentinel announce-ip $MY_IP
sentinel announce-port 26379

dir /tmp
EOF

# Docker-compose final
cat > "$BASE/docker-compose.yml" <<EOF
version: '3.8'

services:
  redis:
    image: redis:7.2-alpine
    container_name: redis
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${BASE}/data:/data
      - ${BASE}/config/redis.conf:/usr/local/etc/redis/redis.conf:ro
    command: redis-server /usr/local/etc/redis/redis.conf

  sentinel:
    image: redis:7.2-alpine
    container_name: sentinel
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${BASE}/config:/etc/redis
    command: redis-sentinel /etc/redis/sentinel.conf
    depends_on:
      - redis
EOF

# Démarrer les services
cd "$BASE"
docker compose up -d

sleep 3

# Vérifier
echo -n "    Redis: "
if docker ps | grep -q "redis" && ! docker logs redis 2>&1 | tail -5 | grep -q "FATAL"; then
    echo "✓"
else
    echo "✗"
fi

echo -n "    Sentinel: "
if docker ps | grep -q "sentinel"; then
    echo "✓"
else
    echo "✗"
fi
FINALIZE
    
    echo ""
done

echo "3. Attente de stabilisation (10s)..."
sleep 10

echo ""
echo "4. Test du cluster Redis..."
echo ""

# Test Redis
echo "  Test des nœuds Redis:"
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "    $host: "
    if redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        ROLE=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        echo -e "$OK (role: $ROLE)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "  Test des Sentinels:"
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "    $host: "
    MASTER_INFO=$(redis-cli -h "$IP_PRIV" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
    if [ -n "$MASTER_INFO" ]; then
        echo -e "$OK (master vu: $MASTER_INFO)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "5. Test de réplication..."

# Écrire sur le master
echo -n "  Écriture sur master: "
TEST_VALUE="test_$(date +%s)"
if redis-cli -h "$MASTER_IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET test_final "$TEST_VALUE" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
    
    sleep 2
    
    # Lire sur les replicas
    for host in redis-02 redis-03; do
        IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
        echo -n "  Lecture sur $host: "
        
        VALUE=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning GET test_final 2>/dev/null)
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

# Compter les succès
REDIS_OK=0
SENTINEL_OK=0

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING &>/dev/null && ((REDIS_OK++))
    redis-cli -h "$IP_PRIV" -p 26379 SENTINEL masters &>/dev/null && ((SENTINEL_OK++))
done

if [ "$REDIS_OK" -eq 3 ] && [ "$SENTINEL_OK" -eq 3 ]; then
    echo -e "$OK Redis Sentinel cluster OPÉRATIONNEL !"
    echo ""
    echo "Configuration:"
    echo "  • Master: redis-01 ($MASTER_IP:6379)"
    echo "  • Replicas: redis-02, redis-03"
    echo "  • Sentinels: 3 actifs (quorum: 2)"
    echo "  • Mot de passe: $REDIS_PASSWORD"
    echo ""
    echo "Credentials sauvegardés dans:"
    echo "  • $CREDS_DIR/redis.env"
    echo "  • $CREDS_DIR/secrets.json"
    echo ""
    echo "Prochaine étape OBLIGATOIRE:"
    echo "  Créer le Load Balancer Redis sur 10.0.0.10:6379"
    echo "  ./redis_master_lb_deploy.sh --hosts haproxy-01,haproxy-02 --sentinels redis-01,redis-02"
else
    echo -e "$KO Cluster partiellement fonctionnel"
    echo "  Redis OK: $REDIS_OK/3"
    echo "  Sentinel OK: $SENTINEL_OK/3"
fi
echo "═══════════════════════════════════════════════════════════════════"
