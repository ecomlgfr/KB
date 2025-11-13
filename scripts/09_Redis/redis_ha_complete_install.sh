#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          REDIS_HA_COMPLETE_INSTALL - Installation complète         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/redis_complete_$TIMESTAMP.log"

mkdir -p "$LOG_DIR" "$CREDS_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Installation Redis HA - 3 nœuds + Sentinel + Load Balancer"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS PRÉALABLES
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier servers.tsv
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Compter les serveurs
REDIS_COUNT=$(grep -E "redis-0[1-3]" "$SERVERS_TSV" | wc -l)
HAPROXY_COUNT=$(grep -E "haproxy-0[1-2]" "$SERVERS_TSV" | wc -l)

echo "  Serveurs Redis trouvés: $REDIS_COUNT"
echo "  Serveurs HAProxy trouvés: $HAPROXY_COUNT"

[ "$REDIS_COUNT" -lt 3 ] && { echo -e "$KO Il faut 3 serveurs Redis"; exit 1; }
[ "$HAPROXY_COUNT" -lt 2 ] && { echo -e "$KO Il faut 2 serveurs HAProxy"; exit 1; }

# Installer redis-cli localement si nécessaire
if ! command -v redis-cli &>/dev/null; then
    echo "  Installation de redis-cli sur install-01..."
    apt-get update -qq && apt-get install -y -qq redis-tools
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: GESTION DES CREDENTIALS (SÉCURISÉ)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Gestion sécurisée des credentials                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ -f "$CREDS_DIR/redis.env" ]; then
    echo "  Chargement des credentials existants..."
    source "$CREDS_DIR/redis.env"
    echo "  Hash du mot de passe: $(echo -n "$REDIS_PASSWORD" | sha256sum | cut -c1-16)..."
else
    echo "  Génération d'un nouveau mot de passe sécurisé..."
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/\n" | cut -c1-32)
    
    cat > "$CREDS_DIR/redis.env" <<EOF
#!/bin/bash
# Redis Credentials - NE JAMAIS COMMITER
# Généré le $(date)
export REDIS_PASSWORD="$REDIS_PASSWORD"
export REDIS_MASTER_NAME="mymaster"
export REDIS_SENTINEL_QUORUM="2"
EOF
    chmod 600 "$CREDS_DIR/redis.env"
    
    # Ajouter à secrets.json
    if [ -f "$CREDS_DIR/secrets.json" ]; then
        jq ".redis_password = \"$REDIS_PASSWORD\"" "$CREDS_DIR/secrets.json" > /tmp/secrets.tmp && \
        mv /tmp/secrets.tmp "$CREDS_DIR/secrets.json"
    else
        echo "{\"redis_password\": \"$REDIS_PASSWORD\"}" | jq '.' > "$CREDS_DIR/secrets.json"
    fi
    chmod 600 "$CREDS_DIR/secrets.json"
    
    echo "  Mot de passe généré et sécurisé (hash: $(echo -n "$REDIS_PASSWORD" | sha256sum | cut -c1-16)...)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: PRÉPARATION DES SERVEURS REDIS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Préparation des serveurs Redis                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "$KO IP de $host non trouvée"; continue; }
    
    echo "  Préparation de $host ($IP_PRIV)..."
    
    # Copier les credentials de manière sécurisée
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "mkdir -p /opt/keybuzz-installer/credentials"
    scp -q "$CREDS_DIR/redis.env" root@"$IP_PRIV":/opt/keybuzz-installer/credentials/
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'PREPARE'
# Charger les credentials
source /opt/keybuzz-installer/credentials/redis.env

BASE="/opt/keybuzz/redis"

# Arrêter et nettoyer les anciens containers
docker stop $(docker ps -aq --filter "name=redis") 2>/dev/null
docker rm $(docker ps -aq --filter "name=redis") 2>/dev/null
docker stop $(docker ps -aq --filter "name=sentinel") 2>/dev/null
docker rm $(docker ps -aq --filter "name=sentinel") 2>/dev/null

# Créer la structure
mkdir -p "$BASE"/{data,config,logs,status,backups}

# Permissions correctes AVANT de démarrer Redis
chmod -R 777 "$BASE/data" "$BASE/logs"

# Copier les credentials localement
cp /opt/keybuzz-installer/credentials/redis.env "$BASE/.env"
chmod 600 "$BASE/.env"

echo "    ✓ Préparé et nettoyé"
PREPARE
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: DÉPLOIEMENT REDIS + SENTINEL
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Déploiement Redis et Sentinel                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

MASTER_IP=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")
echo "  Master initial: redis-01 ($MASTER_IP)"
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ "$host" == "redis-01" ] && ROLE="master" || ROLE="replica"
    
    echo "  Déploiement $host ($ROLE)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$MASTER_IP" "$IP_PRIV" "$ROLE" <<'DEPLOY'
MASTER_IP="$1"
MY_IP="$2"
ROLE="$3"

# Charger les credentials
source /opt/keybuzz-installer/credentials/redis.env
BASE="/opt/keybuzz/redis"

# Configuration Redis SANS logfile pour éviter les problèmes de permissions
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
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

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
repl-diskless-sync no
repl-diskless-sync-delay 5
EOF

# Ajouter slaveof uniquement pour les replicas
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

# Docker-compose.yml
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
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "--no-auth-warning", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

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

sleep 5

# Vérification
docker ps | grep -E "redis|sentinel" | wc -l
DEPLOY
    
    CONTAINERS=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "docker ps | grep -E 'redis|sentinel' | wc -l")
    if [ "$CONTAINERS" -eq 2 ]; then
        echo "    ✓ Redis + Sentinel démarrés"
    else
        echo "    ✗ Problème de démarrage"
    fi
done

echo ""
echo "  Attente de stabilisation du cluster (15s)..."
sleep 15

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: VÉRIFICATION DU CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Vérification du cluster Redis                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Test de connexion Redis:"
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host: "
    
    # Test avec telnet qui est plus fiable
    if (echo "AUTH $REDIS_PASSWORD"; echo "PING"; sleep 1) | nc "$IP_PRIV" 6379 2>/dev/null | grep -q "+PONG"; then
        # Obtenir le rôle
        ROLE=$(echo -e "AUTH $REDIS_PASSWORD\nINFO replication\nQUIT" | nc "$IP_PRIV" 6379 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
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
    
    MASTER=$(echo "SENTINEL get-master-addr-by-name mymaster" | nc "$IP_PRIV" 26379 2>/dev/null | grep -A1 "\*2" | tail -1 | tr -d '$\r')
    if [ -n "$MASTER" ]; then
        echo -e "$OK (voit master: $MASTER)"
    else
        echo -e "$KO"
    fi
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: LOAD BALANCER SUR HAPROXY
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Configuration Load Balancer sur HAProxy               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "$KO IP de $host non trouvée"; continue; }
    
    echo "  Configuration $host ($IP_PRIV)..."
    
    # Copier les credentials
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "mkdir -p /opt/keybuzz-installer/credentials"
    scp -q "$CREDS_DIR/redis.env" root@"$IP_PRIV":/opt/keybuzz-installer/credentials/
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$MASTER_IP" <<'HAPROXY'
MASTER_IP="$1"

# Charger les credentials
source /opt/keybuzz-installer/credentials/redis.env
BASE="/opt/keybuzz/redis-lb"

# Nettoyer anciens containers
docker stop haproxy-redis sentinel-watcher 2>/dev/null
docker rm haproxy-redis sentinel-watcher 2>/dev/null

# Créer structure
mkdir -p "$BASE"/{config,scripts,logs,status}

# Configuration HAProxy avec auth depuis variable
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

# Enregistrer le master actuel
echo "$MASTER_IP" > "$BASE/status/current_master"

# Script de mise à jour du master (avec credentials depuis fichier)
cat > "$BASE/scripts/update_master.sh" <<'SCRIPT'
#!/bin/bash
# Charger les credentials
source /opt/keybuzz-installer/credentials/redis.env

SENTINELS="10.0.0.123:26379 10.0.0.124:26379 10.0.0.125:26379"
CONFIG_FILE="/config/haproxy-redis.cfg"
CURRENT_MASTER_FILE="/status/current_master"

get_master() {
    for sentinel in $SENTINELS; do
        MASTER=$(redis-cli -h ${sentinel%:*} -p ${sentinel#*:} SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
        [ -n "$MASTER" ] && echo "$MASTER" && return 0
    done
    return 1
}

while true; do
    NEW_MASTER=$(get_master)
    if [ -n "$NEW_MASTER" ]; then
        CURRENT_MASTER=""
        [ -f "$CURRENT_MASTER_FILE" ] && CURRENT_MASTER=$(cat "$CURRENT_MASTER_FILE")
        
        if [ "$NEW_MASTER" != "$CURRENT_MASTER" ]; then
            echo "[$(date)] Master changed: $CURRENT_MASTER -> $NEW_MASTER"
            
            # Mettre à jour config avec le mot de passe depuis la variable
            cat > "$CONFIG_FILE" <<EOF
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
    server redis-master $NEW_MASTER:6379 check inter 2s fall 3 rise 2
EOF
            
            echo "$NEW_MASTER" > "$CURRENT_MASTER_FILE"
            docker kill -s HUP haproxy-redis 2>/dev/null
        fi
    fi
    sleep 5
done
SCRIPT

chmod +x "$BASE/scripts/update_master.sh"

# Docker-compose pour HAProxy + Watcher
cat > "$BASE/docker-compose.yml" <<EOF
version: '3.8'

services:
  haproxy-redis:
    image: haproxy:2.9-alpine
    container_name: haproxy-redis
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${BASE}/config:/usr/local/etc/haproxy:ro
    command: haproxy -f /usr/local/etc/haproxy/haproxy-redis.cfg

  sentinel-watcher:
    image: redis:7.2-alpine
    container_name: sentinel-watcher
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${BASE}/scripts:/scripts:ro
      - ${BASE}/config:/config
      - ${BASE}/status:/status
      - /opt/keybuzz-installer/credentials:/opt/keybuzz-installer/credentials:ro
    entrypoint: ["/bin/sh", "-c"]
    command: ["apk add --no-cache bash && /scripts/update_master.sh"]
    depends_on:
      - haproxy-redis
EOF

# Démarrer
cd "$BASE"
docker compose up -d

echo "    ✓ Load Balancer configuré"
HAPROXY
done

echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: TEST FINAL
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Tests finaux                                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Test HAProxy locaux:"
for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host: "
    
    if (echo "AUTH $REDIS_PASSWORD"; echo "PING"; sleep 1) | nc "$IP_PRIV" 6379 2>/dev/null | grep -q "+PONG"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "  Test via Load Balancer Hetzner:"
echo -n "    10.0.0.10:6379: "
if (echo "AUTH $REDIS_PASSWORD"; echo "PING"; sleep 1) | nc 10.0.0.10 6379 2>/dev/null | grep -q "+PONG"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "  Test de réplication:"
TEST_KEY="test_replication_$(date +%s)"
TEST_VALUE="redis_ha_ok"

echo -n "    Écriture sur master via LB: "
if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET "$TEST_KEY" "$TEST_VALUE" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
    
    sleep 2
    
    # Vérifier sur les replicas
    for host in redis-02 redis-03; do
        IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
        echo -n "    Lecture sur $host: "
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

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Créer le résumé sans mot de passe visible
cat > "$CREDS_DIR/redis-summary.txt" <<EOF
REDIS HA - INSTALLATION COMPLÈTE
═══════════════════════════════════════════════════════════════════

Date: $(date)

ARCHITECTURE:
  • 3 nœuds Redis (1 master, 2 replicas)
  • 3 Sentinels pour le failover
  • 2 HAProxy pour le load balancing
  • 1 VIP sur Load Balancer Hetzner

ENDPOINT UNIQUE:
  Host: 10.0.0.10
  Port: 6379
  Protocol: Redis

CREDENTIALS:
  Fichier: $CREDS_DIR/redis.env
  Usage: source $CREDS_DIR/redis.env

CONNEXION:
  redis-cli -h 10.0.0.10 -p 6379 -a "\$REDIS_PASSWORD" --no-auth-warning

CONFIGURATION APPLICATIONS:
  REDIS_HOST=10.0.0.10
  REDIS_PORT=6379
  REDIS_PASSWORD=\${REDIS_PASSWORD}

SÉCURITÉ:
  • Ne jamais hardcoder les mots de passe
  • Toujours charger depuis redis.env
  • Permissions 600 sur les fichiers de credentials
EOF

if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING &>/dev/null; then
    echo -e "$OK REDIS HA INSTALLATION COMPLÈTE ET OPÉRATIONNELLE"
    echo ""
    echo "Endpoint: 10.0.0.10:6379"
    echo "Credentials: $CREDS_DIR/redis.env"
    echo ""
    echo "Pour tester:"
    echo '  source /opt/keybuzz-installer/credentials/redis.env'
    echo '  redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING'
else
    echo -e "$KO Installation incomplète"
    echo "Vérifier les logs: $MAIN_LOG"
fi
echo "═══════════════════════════════════════════════════════════════════"
