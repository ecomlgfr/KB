#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║            REDIS_SENTINEL_DEPLOY - Déploiement Redis HA            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
HOSTS=""
MASTER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --hosts) HOSTS="$2"; shift 2 ;;
        --master) MASTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$HOSTS" ] && { echo -e "$KO Usage: $0 --hosts redis-01,redis-02,redis-03 --master redis-01"; exit 1; }
[ -z "$MASTER" ] && MASTER="redis-01"

# Charger les credentials
source "$CREDS_DIR/redis.env"

# Log file
LOG_FILE="$LOG_DIR/redis_sentinel_deploy.log"
mkdir -p "$LOG_DIR"

# Redirection des logs
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo ""
echo "Déploiement Redis Sentinel"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Hosts: $HOSTS"
echo "Master initial: $MASTER"
echo ""

# Récupérer l'IP du master
MASTER_IP=$(awk -F'\t' -v h="$MASTER" '$2==h {print $3}' "$SERVERS_TSV")
[ -z "$MASTER_IP" ] && { echo -e "$KO IP du master $MASTER non trouvée"; exit 1; }

echo "Master IP: $MASTER_IP"
echo ""

# Convertir la liste des hosts en array
IFS=',' read -ra HOST_ARRAY <<< "$HOSTS"

# 1. Déployer Redis sur chaque nœud
echo "1. Déploiement de Redis sur chaque nœud..."
echo ""

for host in "${HOST_ARRAY[@]}"; do
    echo "  Déploiement sur $host..."
    
    # Récupérer l'IP privée
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "    $KO IP de $host non trouvée"; continue; }
    
    # Déterminer le rôle (master ou replica)
    if [ "$host" == "$MASTER" ]; then
        ROLE="master"
        SLAVEOF_CMD=""
    else
        ROLE="replica"
        SLAVEOF_CMD="slaveof $MASTER_IP 6379"
    fi
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" "$MASTER_IP" "$host" "$ROLE" "$IP_PRIV" <<'DEPLOY_REDIS'
REDIS_PASSWORD="$1"
MASTER_IP="$2"
HOST_NAME="$3"
ROLE="$4"
MY_IP="$5"

BASE="/opt/keybuzz/redis"

echo "    Configuration du rôle: $ROLE"

# Mise à jour de redis.conf selon le rôle
if [ "$ROLE" == "replica" ]; then
    echo "slaveof $MASTER_IP 6379" >> "$BASE/config/redis.conf"
fi

# Créer docker-compose.yml
cat > "$BASE/docker-compose.yml" <<EOF
version: '3.8'

services:
  redis:
    image: redis:7.2-alpine
    container_name: redis
    hostname: ${HOST_NAME}-redis
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${BASE}/data:/data
      - ${BASE}/config/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - ${BASE}/logs:/var/log/redis
    command: redis-server /usr/local/etc/redis/redis.conf
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD}

  sentinel:
    image: redis:7.2-alpine
    container_name: sentinel
    hostname: ${HOST_NAME}-sentinel
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${BASE}/config:/etc/redis
      - ${BASE}/logs:/var/log/redis
    command: redis-sentinel /etc/redis/sentinel.conf
    depends_on:
      - redis
EOF

# Mettre à jour sentinel.conf avec le master
cat > "$BASE/config/sentinel.conf" <<SENTINEL
# Sentinel Configuration - $HOST_NAME
bind 0.0.0.0
port 26379
protected-mode yes
sentinel announce-ip $MY_IP
sentinel announce-port 26379

# Monitor master
sentinel monitor mymaster $MASTER_IP 6379 2
sentinel auth-pass mymaster $REDIS_PASSWORD
sentinel down-after-milliseconds mymaster 5000
sentinel parallel-syncs mymaster 1
sentinel failover-timeout mymaster 60000

# Log
logfile /var/log/redis/sentinel.log
dir /tmp
SENTINEL

# Démarrer les services
cd "$BASE"
docker compose down 2>/dev/null || true
docker compose up -d

sleep 3

# Vérification
echo -n "    Redis: "
if docker ps | grep -q "redis"; then
    echo "✓ Démarré"
else
    echo "✗ Échec"
    docker logs redis --tail 10 2>&1
fi

echo -n "    Sentinel: "
if docker ps | grep -q "sentinel"; then
    echo "✓ Démarré"
else
    echo "✗ Échec"
    docker logs sentinel --tail 10 2>&1
fi

# Mise à jour de l'état
echo "OK - Redis $ROLE déployé" > "$BASE/status/STATE"
DEPLOY_REDIS

    echo ""
done

# 2. Attendre que tout soit stable
echo "2. Attente de stabilisation (10s)..."
sleep 10

# 3. Vérification du cluster
echo ""
echo "3. Vérification du cluster Redis Sentinel..."
echo ""

# Test de chaque nœud Redis
echo "  Test des nœuds Redis:"
for host in "${HOST_ARRAY[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "    $host ($IP_PRIV): "
    if redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        # Vérifier le rôle
        ROLE=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        echo -e "$OK (role: $ROLE)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "  Test des Sentinels:"
for host in "${HOST_ARRAY[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "    $host ($IP_PRIV): "
    MASTER_INFO=$(redis-cli -h "$IP_PRIV" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null)
    if [ -n "$MASTER_INFO" ]; then
        DETECTED_MASTER=$(echo "$MASTER_INFO" | head -1)
        echo -e "$OK (master: $DETECTED_MASTER)"
    else
        echo -e "$KO"
    fi
done

# 4. Test de réplication
echo ""
echo "4. Test de réplication..."

# Insérer une clé sur le master
echo -n "  Écriture sur master: "
if redis-cli -h "$MASTER_IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET test_key "test_value_$(date +%s)" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
    
    # Vérifier sur les replicas
    echo "  Lecture sur les replicas:"
    for host in "${HOST_ARRAY[@]}"; do
        if [ "$host" != "$MASTER" ]; then
            IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
            echo -n "    $host: "
            
            VALUE=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning GET test_key 2>/dev/null)
            if [ -n "$VALUE" ]; then
                echo -e "$OK (valeur répliquée)"
            else
                echo -e "$KO"
            fi
        fi
    done
else
    echo -e "$KO"
fi

# 5. État final
echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Compter les succès
SUCCESS=0
for host in "${HOST_ARRAY[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    if ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "grep -q OK /opt/keybuzz/redis/status/STATE 2>/dev/null"; then
        ((SUCCESS++))
    fi
done

if [ "$SUCCESS" -eq "${#HOST_ARRAY[@]}" ]; then
    echo -e "$OK Redis Sentinel déployé avec succès"
    echo ""
    echo "Configuration:"
    echo "  Master: $MASTER ($MASTER_IP)"
    echo "  Replicas: ${#HOST_ARRAY[@]} nœuds au total"
    echo "  Sentinel quorum: 2"
    echo ""
    echo "Prochaine étape:"
    echo "  Déployer le Load Balancer Redis sur HAProxy:"
    echo "  ./redis_master_lb_deploy.sh --hosts haproxy-01,haproxy-02 --sentinels redis-01,redis-02"
else
    echo -e "$KO Déploiement partiel ($SUCCESS/${#HOST_ARRAY[@]} nœuds OK)"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Logs (50 dernières lignes):"
echo "----------------------------"
tail -n 50 "$LOG_FILE"
