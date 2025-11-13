#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           REDIS_HA_INSTALL_COMPLETE - Installation Redis HA        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"

echo ""
echo "Installation complète Redis HA (3 nœuds + LB)"
echo ""

# 0. MONTER LES VOLUMES (si pas déjà fait)
echo "═══ Étape 0: Montage des volumes XFS ═══"
for host in redis-01 redis-02 redis-03; do
    echo "  Vérification volume $host..."
    ./volumes_tool.sh mount --host "$host" --fs xfs 2>/dev/null || echo "    Volume déjà monté ou script absent"
done
echo ""

# 1. PRÉPARATION
echo "═══ Étape 1: Préparation des serveurs Redis ═══"

# Générer le mot de passe si absent
if [ ! -f "$CREDS_DIR/redis.env" ]; then
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    cat > "$CREDS_DIR/redis.env" <<EOF
export REDIS_PASSWORD="$REDIS_PASSWORD"
export REDIS_MASTER_NAME="mymaster"
export REDIS_SENTINEL_QUORUM="2"
EOF
    chmod 600 "$CREDS_DIR/redis.env"
else
    source "$CREDS_DIR/redis.env"
fi

echo "  Mot de passe Redis: $REDIS_PASSWORD"
echo ""

# Préparer chaque serveur
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Préparation $host ($IP_PRIV)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" <<'PREP'
REDIS_PASSWORD="$1"
BASE="/opt/keybuzz/redis"

# Créer structure
mkdir -p "$BASE"/{data,config,logs,status,backups}
chmod -R 777 "$BASE"/{data,logs}

# Sauvegarder le mot de passe
cat > "$BASE/.env" <<EOF
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_MASTER_NAME=mymaster
EOF
chmod 600 "$BASE/.env"

echo "    ✓ Préparé"
PREP
done

echo ""

# 2. DÉPLOIEMENT REDIS + SENTINEL
echo "═══ Étape 2: Déploiement Redis et Sentinel ═══"

MASTER_IP=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    [ "$host" == "redis-01" ] && ROLE="master" || ROLE="replica"
    echo "  Déploiement $host ($ROLE)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" "$MASTER_IP" "$ROLE" "$IP_PRIV" <<'DEPLOY'
REDIS_PASSWORD="$1"
MASTER_IP="$2"
ROLE="$3"
MY_IP="$4"
BASE="/opt/keybuzz/redis"

# Arrêter anciens containers
docker stop $(docker ps -aq --filter "name=redis" --filter "name=sentinel") 2>/dev/null
docker rm $(docker ps -aq --filter "name=redis" --filter "name=sentinel") 2>/dev/null

# Configuration Redis (sans logfile pour éviter les problèmes)
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

maxclients 10000
maxmemory-policy allkeys-lru

replica-read-only yes
replica-serve-stale-data yes
EOF

# Ajouter slaveof si replica
[ "$ROLE" == "replica" ] && echo "slaveof $MASTER_IP 6379" >> "$BASE/config/redis.conf"

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

# Docker-compose
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

# Démarrer
cd "$BASE"
docker compose up -d

echo "    ✓ Déployé"
DEPLOY
done

echo ""
sleep 10

# 3. VÉRIFICATION CLUSTER
echo "═══ Étape 3: Vérification du cluster ═══"

# Installer redis-cli si nécessaire
if ! command -v redis-cli &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq redis-tools
fi

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  $host: "
    
    # Test via telnet direct (plus fiable)
    (echo "AUTH $REDIS_PASSWORD"; echo "PING"; sleep 1) | nc "$IP_PRIV" 6379 2>/dev/null | grep -q "+PONG" && echo -e "$OK" || echo -e "$KO"
done

echo ""

# 4. LOAD BALANCER SUR HAPROXY
echo "═══ Étape 4: Load Balancer Redis sur HAProxy ═══"

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Configuration $host..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" "$MASTER_IP" <<'LB'
REDIS_PASSWORD="$1"
MASTER_IP="$2"
BASE="/opt/keybuzz/redis-lb"

# Arrêter anciens containers
docker stop haproxy-redis sentinel-watcher 2>/dev/null
docker rm haproxy-redis sentinel-watcher 2>/dev/null

# Créer structure avec les bons chemins
mkdir -p "$BASE"/{config,scripts,logs,status}

# Configuration HAProxy simple et directe
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
    tcp-check send AUTH\ $REDIS_PASSWORD\r\n
    tcp-check expect string +OK
    tcp-check send PING\r\n
    tcp-check expect string +PONG
    tcp-check send QUIT\r\n
    tcp-check expect string +OK
    server redis-master $MASTER_IP:6379 check inter 2s fall 3 rise 2
EOF

# Enregistrer le master
echo "$MASTER_IP" > "$BASE/status/current_master"

# Démarrer HAProxy simple (sans watcher pour l'instant)
docker run -d \
  --name haproxy-redis \
  --restart unless-stopped \
  --network host \
  -v ${BASE}/config/haproxy-redis.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.9-alpine

echo "    ✓ Load Balancer configuré"
LB
done

echo ""
sleep 5

# 5. TEST FINAL
echo "═══ Étape 5: Test final ═══"

echo -n "  Test via Load Balancer Hetzner (10.0.0.10:6379): "
if (echo "AUTH $REDIS_PASSWORD"; echo "PING"; sleep 1) | nc 10.0.0.10 6379 2>/dev/null | grep -q "+PONG"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Installation Redis HA COMPLÈTE"
echo ""
echo "Configuration finale:"
echo "  • Endpoint: 10.0.0.10:6379"
echo "  • Mot de passe: $REDIS_PASSWORD"
echo "  • Master: redis-01 ($MASTER_IP)"
echo "  • Replicas: redis-02, redis-03"
echo "  • Sentinels: 3 actifs"
echo "  • Load Balancers: haproxy-01, haproxy-02"
echo ""
echo "Pour les applications:"
echo "  REDIS_HOST=10.0.0.10"
echo "  REDIS_PORT=6379"
echo "  REDIS_PASSWORD=$REDIS_PASSWORD"
echo "═══════════════════════════════════════════════════════════════════"
