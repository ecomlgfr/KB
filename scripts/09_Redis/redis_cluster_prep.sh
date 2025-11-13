#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                 REDIS_CLUSTER_PREP - Préparation Redis HA          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
HOST=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$HOST" ] && { echo -e "$KO Usage: $0 --host redis-01|redis-02|redis-03"; exit 1; }

# Récupérer l'IP privée depuis servers.tsv
IP_PRIV=$(awk -F'\t' -v h="$HOST" '$2==h {print $3}' "$SERVERS_TSV")
[ -z "$IP_PRIV" ] && { echo -e "$KO $HOST non trouvé dans servers.tsv"; exit 1; }

# Log file
LOG_FILE="$LOG_DIR/redis_prep_${HOST}.log"
mkdir -p "$LOG_DIR"

# Redirection des logs
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo ""
echo "Préparation Redis sur $HOST ($IP_PRIV)"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. Générer/charger le mot de passe Redis
echo "1. Gestion des credentials Redis..."

if [ -f "$CREDS_DIR/redis.env" ]; then
    source "$CREDS_DIR/redis.env"
    echo "  Credentials chargés depuis redis.env"
elif [ -f "$CREDS_DIR/secrets.json" ] && jq -e '.redis_password' "$CREDS_DIR/secrets.json" >/dev/null 2>&1; then
    REDIS_PASSWORD=$(jq -r '.redis_password' "$CREDS_DIR/secrets.json")
    echo "  Credentials chargés depuis secrets.json"
else
    # Générer nouveau mot de passe
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    # Sauvegarder dans redis.env
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
    
    echo "  Nouveau mot de passe généré et sauvegardé"
fi

# 2. Préparer le serveur Redis
echo ""
echo "2. Préparation du serveur $HOST..."

ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" "$HOST" <<'REMOTE_PREP'
REDIS_PASSWORD="$1"
HOST_NAME="$2"

echo "  Création de la structure des répertoires..."

# Créer les répertoires
BASE="/opt/keybuzz/redis"
mkdir -p "$BASE"/{data,config,logs,status,backups}

# Vérifier si le volume est monté (XFS)
echo ""
echo "  Vérification du volume:"
if mountpoint -q "$BASE/data" 2>/dev/null; then
    echo "    ✓ Volume déjà monté sur $BASE/data"
    df -hT "$BASE/data" | tail -1 | sed 's/^/    /'
else
    echo "    ⚠ Volume non monté sur $BASE/data"
    echo "    Les données seront sur le disque système"
fi

# Créer la configuration Redis
echo ""
echo "  Création de la configuration Redis..."

cat > "$BASE/config/redis.conf" <<EOF
# Redis Configuration - $HOST_NAME
bind 0.0.0.0
protected-mode yes
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300

# Authentification
requirepass $REDIS_PASSWORD
masterauth $REDIS_PASSWORD

# Persistence
dir /data
dbfilename dump.rdb
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# Logs
loglevel notice
logfile /var/log/redis/redis-server.log
syslog-enabled no

# Performance
databases 16
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes

# Limits
maxclients 10000
maxmemory-policy allkeys-lru

# Replication
replica-read-only yes
replica-serve-stale-data yes
repl-diskless-sync no
repl-diskless-sync-delay 5
EOF

# Configuration Sentinel
cat > "$BASE/config/sentinel.conf" <<EOF
# Sentinel Configuration - $HOST_NAME
bind 0.0.0.0
port 26379
sentinel announce-ip $(hostname -I | awk '{print $1}')
sentinel announce-port 26379

# Monitor Redis master (sera mis à jour lors du déploiement)
# sentinel monitor mymaster <master-ip> 6379 2
# sentinel auth-pass mymaster $REDIS_PASSWORD

sentinel down-after-milliseconds mymaster 5000
sentinel parallel-syncs mymaster 1
sentinel failover-timeout mymaster 60000

# Logs
logfile /var/log/redis/sentinel.log
EOF

# Créer le fichier .env pour Docker
cat > "$BASE/.env" <<EOF
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_MASTER_NAME=mymaster
HOST_NAME=$HOST_NAME
EOF

# Permissions
chmod 644 "$BASE/config/redis.conf"
chmod 644 "$BASE/config/sentinel.conf"
chmod 600 "$BASE/.env"

# Installer Docker si nécessaire
if ! command -v docker &>/dev/null; then
    echo "  Installation de Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable docker
    systemctl start docker
fi

# Vérifier Docker
if docker --version &>/dev/null; then
    echo "  ✓ Docker disponible: $(docker --version | cut -d' ' -f3)"
else
    echo "  ✗ Docker non disponible"
    exit 1
fi

# État initial
echo "OK" > "$BASE/status/STATE"
echo "Préparation terminée à $(date)" >> "$BASE/status/STATE"

echo ""
echo "  ✓ Serveur $HOST_NAME préparé"
REMOTE_PREP

# 3. Vérification
echo ""
echo "3. Vérification de la préparation..."

# Vérifier la connectivité
echo -n "  Connectivité SSH: "
if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@"$IP_PRIV" "echo OK" &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

# Vérifier les répertoires
echo -n "  Structure créée: "
if ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "[ -d /opt/keybuzz/redis/config ] && [ -f /opt/keybuzz/redis/.env ]" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

# Vérifier Docker
echo -n "  Docker disponible: "
if ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "docker --version" &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# État final
echo ""
echo "═══════════════════════════════════════════════════════════════════"
if ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "grep -q OK /opt/keybuzz/redis/status/STATE 2>/dev/null"; then
    echo -e "$OK Préparation réussie pour $HOST"
    echo ""
    echo "Prochaine étape:"
    echo "  $0 --host redis-02  (si pas fait)"
    echo "  $0 --host redis-03  (si pas fait)"
    echo ""
    echo "Puis déployer Redis Sentinel:"
    echo "  ./redis_sentinel_deploy.sh --hosts redis-01,redis-02,redis-03 --master redis-01"
else
    echo -e "$KO Préparation échouée pour $HOST"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Logs (50 dernières lignes):"
echo "----------------------------"
tail -n 50 "$LOG_FILE"
