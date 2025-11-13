#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      REDIS_MASTER_LB_DEPLOY - Load Balancer Redis OBLIGATOIRE      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
HOSTS=""
SENTINELS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --hosts) HOSTS="$2"; shift 2 ;;
        --sentinels) SENTINELS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$HOSTS" ] && { echo -e "$KO Usage: $0 --hosts haproxy-01,haproxy-02 --sentinels redis-01,redis-02"; exit 1; }
[ -z "$SENTINELS" ] && SENTINELS="redis-01,redis-02"

# Charger les credentials
source "$CREDS_DIR/redis.env"

LOG_FILE="$LOG_DIR/redis_lb_deploy.log"
mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo ""
echo "Déploiement Load Balancer Redis"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "HAProxy hosts: $HOSTS"
echo "Sentinels: $SENTINELS"
echo ""

# Convertir en arrays
IFS=',' read -ra HOST_ARRAY <<< "$HOSTS"
IFS=',' read -ra SENTINEL_ARRAY <<< "$SENTINELS"

# Récupérer les IPs des sentinels
SENTINEL_IPS=""
for sentinel in "${SENTINEL_ARRAY[@]}"; do
    IP=$(awk -F'\t' -v h="$sentinel" '$2==h {print $3}' "$SERVERS_TSV")
    [ -n "$IP" ] && SENTINEL_IPS="$SENTINEL_IPS$IP:26379 "
done
SENTINEL_IPS=$(echo "$SENTINEL_IPS" | xargs)

echo "IPs des Sentinels: $SENTINEL_IPS"
echo ""

# 1. Déployer sur chaque HAProxy
echo "1. Déploiement du Load Balancer Redis..."
echo ""

for host in "${HOST_ARRAY[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "  $KO IP de $host non trouvée"; continue; }
    
    echo "  Configuration sur $host ($IP_PRIV)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" "$SENTINEL_IPS" <<'DEPLOY_LB'
REDIS_PASSWORD="$1"
SENTINEL_IPS="$2"
BASE="/opt/keybuzz/redis-lb"

# Créer la structure
mkdir -p "$BASE"/{config,scripts,logs,status}

# Script de mise à jour du master
cat > "$BASE/scripts/update_master.sh" <<'SCRIPT'
#!/bin/bash
SENTINELS="SENTINEL_IPS_PLACEHOLDER"
REDIS_PASSWORD="REDIS_PASSWORD_PLACEHOLDER"
HAPROXY_CONFIG="/opt/keybuzz/redis-lb/config/haproxy-redis.cfg"
CURRENT_MASTER_FILE="/opt/keybuzz/redis-lb/status/current_master"

# Fonction pour obtenir le master depuis les sentinels
get_master() {
    for sentinel in $SENTINELS; do
        RESULT=$(timeout 2 redis-cli -h ${sentinel%:*} -p ${sentinel#*:} SENTINEL get-master-addr-by-name mymaster 2>/dev/null)
        if [ -n "$RESULT" ]; then
            echo "$RESULT" | head -1
            return 0
        fi
    done
    return 1
}

# Boucle principale
while true; do
    NEW_MASTER=$(get_master)
    
    if [ -n "$NEW_MASTER" ]; then
        # Lire le master actuel
        CURRENT_MASTER=""
        [ -f "$CURRENT_MASTER_FILE" ] && CURRENT_MASTER=$(cat "$CURRENT_MASTER_FILE")
        
        # Si le master a changé
        if [ "$NEW_MASTER" != "$CURRENT_MASTER" ]; then
            echo "[$(date)] Master changé: $CURRENT_MASTER -> $NEW_MASTER"
            
            # Mettre à jour la config HAProxy
            cat > "$HAPROXY_CONFIG" <<EOF
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global

# Redis Master (TCP mode)
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
    server redis-master $NEW_MASTER:6379 check inter 2s fall 3 rise 2
EOF
            
            # Sauvegarder le nouveau master
            echo "$NEW_MASTER" > "$CURRENT_MASTER_FILE"
            
            # Recharger HAProxy
            docker kill -s HUP haproxy-redis 2>/dev/null || true
        fi
    fi
    
    sleep 5
done
SCRIPT

# Remplacer les placeholders
sed -i "s/SENTINEL_IPS_PLACEHOLDER/$SENTINEL_IPS/" "$BASE/scripts/update_master.sh"
sed -i "s/REDIS_PASSWORD_PLACEHOLDER/$REDIS_PASSWORD/" "$BASE/scripts/update_master.sh"
chmod +x "$BASE/scripts/update_master.sh"

# Configuration HAProxy initiale (sera mise à jour par le watcher)
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

# Redis Master placeholder
listen redis_master
    bind 0.0.0.0:6379
    mode tcp
    balance first
    server placeholder 127.0.0.1:6379 disabled
EOF

# Docker-compose pour HAProxy Redis
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
    entrypoint: ["/bin/sh", "-c"]
    command: ["apk add --no-cache bash && /scripts/update_master.sh"]
    depends_on:
      - haproxy-redis
EOF

# Arrêter les anciens containers
docker stop haproxy-redis sentinel-watcher 2>/dev/null || true
docker rm haproxy-redis sentinel-watcher 2>/dev/null || true

# Démarrer les services
cd "$BASE"
docker compose up -d

sleep 5

# Vérifier
echo -n "    HAProxy Redis: "
if docker ps | grep -q "haproxy-redis"; then
    echo "✓"
else
    echo "✗"
fi

echo -n "    Sentinel Watcher: "
if docker ps | grep -q "sentinel-watcher"; then
    echo "✓"
else
    echo "✗"
fi

# État
echo "OK" > "$BASE/status/STATE"
DEPLOY_LB
    
    echo ""
done

echo "2. Attente de stabilisation (10s)..."
sleep 10

echo ""
echo "3. Test du Load Balancer..."
echo ""

# Installer redis-cli si nécessaire
if ! command -v redis-cli &>/dev/null; then
    echo "  Installation de redis-cli..."
    apt-get update -qq && apt-get install -y -qq redis-tools
fi

# Test sur chaque HAProxy
for host in "${HOST_ARRAY[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $host - Redis LB (6379): "
    if redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        ROLE=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        echo -e "$OK (redirige vers: $ROLE)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "4. Test via Load Balancer Hetzner (10.0.0.10)..."
echo ""

echo -n "  Redis via LB (10.0.0.10:6379): "
if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
    echo -e "$OK"
    
    # Info sur le master
    INFO=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO server 2>/dev/null | grep "tcp_port\|run_id" | head -2)
    echo "    $INFO" | sed 's/^/    /'
else
    echo -e "$KO"
fi

echo ""
echo "5. Test de failover..."
echo ""

# Identifier le master actuel
CURRENT_MASTER_IP=$(redis-cli -h "${SENTINEL_IPS%% *}" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
echo "  Master actuel: $CURRENT_MASTER_IP"

# Écrire une clé test
TEST_KEY="failover_test_$(date +%s)"
TEST_VALUE="before_failover"
redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET "$TEST_KEY" "$TEST_VALUE" &>/dev/null

echo "  Simulation failover (arrêt du master)..."
MASTER_HOST=$(awk -F'\t' -v ip="$CURRENT_MASTER_IP" '$3==ip {print $2}' "$SERVERS_TSV" | head -1)
if [ -n "$MASTER_HOST" ]; then
    ssh -o StrictHostKeyChecking=no root@"$CURRENT_MASTER_IP" "docker stop redis" &>/dev/null
    
    echo "  Attente bascule (20s)..."
    sleep 20
    
    # Vérifier le nouveau master
    NEW_MASTER_IP=$(redis-cli -h "${SENTINEL_IPS%% *}" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
    echo "  Nouveau master: $NEW_MASTER_IP"
    
    # Test lecture via LB
    echo -n "  Lecture après failover: "
    VALUE=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning GET "$TEST_KEY" 2>/dev/null)
    if [ "$VALUE" = "$TEST_VALUE" ]; then
        echo -e "$OK (données préservées)"
    else
        echo -e "$KO"
    fi
    
    # Redémarrer l'ancien master
    echo "  Redémarrage ancien master..."
    ssh -o StrictHostKeyChecking=no root@"$CURRENT_MASTER_IP" "docker start redis" &>/dev/null
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Résumé
SUCCESS=0
for host in "${HOST_ARRAY[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING &>/dev/null && ((SUCCESS++))
done

if [ "$SUCCESS" -eq "${#HOST_ARRAY[@]}" ]; then
    echo -e "$OK Load Balancer Redis OPÉRATIONNEL sur 10.0.0.10:6379"
    echo ""
    echo "Configuration finale:"
    echo "  • Endpoint unique: 10.0.0.10:6379"
    echo "  • Mot de passe: $REDIS_PASSWORD"
    echo "  • Failover automatique via Sentinel"
    echo "  • HAProxy actifs: ${#HOST_ARRAY[@]}"
    echo ""
    echo "Variables pour les applications:"
    echo "  REDIS_HOST=10.0.0.10"
    echo "  REDIS_PORT=6379"
    echo "  REDIS_PASSWORD=$REDIS_PASSWORD"
else
    echo -e "$KO Load Balancer partiellement fonctionnel ($SUCCESS/${#HOST_ARRAY[@]})"
fi
echo "═══════════════════════════════════════════════════════════════════"
