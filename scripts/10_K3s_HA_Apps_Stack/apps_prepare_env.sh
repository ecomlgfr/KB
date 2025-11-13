#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         K3S HA APPS - Préparation Environnements & Secrets        ║"
echo "║            (n8n, Chatwoot, ERPNext, LiteLLM, Qdrant, Superset)   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
APPS_DIR="/opt/keybuzz-installer/apps"

# Vérifications préalables
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
mkdir -p "$LOG_DIR" "$CREDENTIALS_DIR" "$APPS_DIR"

LOG_FILE="$LOG_DIR/apps_prepare_env.log"

# Récupérer l'IP du master-01
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable"
    exit 1
fi

echo "" | tee -a "$LOG_FILE"
echo "═══ Configuration ═══" | tee -a "$LOG_FILE"
echo "  Master-01         : $IP_MASTER01" | tee -a "$LOG_FILE"
echo "  Credentials DIR   : $CREDENTIALS_DIR" | tee -a "$LOG_FILE"
echo "  Apps DIR          : $APPS_DIR" | tee -a "$LOG_FILE"
echo "  Log               : $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# Fonction pour extraire une valeur d'un fichier .env
# ═══════════════════════════════════════════════════════════════════════════
get_env_value() {
    local file="$1"
    local key="$2"
    local default="$3"
    
    if [ -f "$file" ]; then
        # Chercher la variable dans le fichier
        local value=$(grep -E "^${key}=" "$file" | cut -d'=' -f2- | sed 's/^["\x27]//;s/["\x27]$//' | head -n1)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    echo "$default"
}

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Vérifier les credentials de la data-plane
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 1/5 : Vérification des credentials data-plane ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Charger les credentials PostgreSQL
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "  $OK postgres.env trouvé" | tee -a "$LOG_FILE"
    
    # Extraire les valeurs
    POSTGRES_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_PASSWORD" "KeyBuzz2024Secure!")
    POSTGRES_VERSION=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_VERSION" "16")
    POSTGRES_HOST=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_HOST" "10.0.0.10")
    POSTGRES_PORT_POOL=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_PORT_POOL" "4632")
    POSTGRES_PORT_RW=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_PORT_RW" "5432")
    POSTGRES_PORT_RO=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_PORT_RO" "5433")
else
    echo -e "  $WARN postgres.env introuvable, création..." | tee -a "$LOG_FILE"
    
    POSTGRES_PASSWORD="KeyBuzz2024Secure!"
    POSTGRES_VERSION="16"
    POSTGRES_HOST="10.0.0.10"
    POSTGRES_PORT_POOL="4632"
    POSTGRES_PORT_RW="5432"
    POSTGRES_PORT_RO="5433"
    
    cat > "$CREDENTIALS_DIR/postgres.env" <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_VERSION=$POSTGRES_VERSION
POSTGRES_HOST=$POSTGRES_HOST
POSTGRES_PORT_POOL=$POSTGRES_PORT_POOL
POSTGRES_PORT_RW=$POSTGRES_PORT_RW
POSTGRES_PORT_RO=$POSTGRES_PORT_RO
EOF
    chmod 600 "$CREDENTIALS_DIR/postgres.env"
fi

# Charger les credentials Redis
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    echo -e "  $OK redis.env trouvé" | tee -a "$LOG_FILE"
    
    REDIS_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/redis.env" "REDIS_PASSWORD" "$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)")
    REDIS_HOST=$(get_env_value "$CREDENTIALS_DIR/redis.env" "REDIS_HOST" "10.0.0.10")
    REDIS_PORT=$(get_env_value "$CREDENTIALS_DIR/redis.env" "REDIS_PORT" "6379")
else
    echo -e "  $WARN redis.env introuvable, création..." | tee -a "$LOG_FILE"
    
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    REDIS_HOST="10.0.0.10"
    REDIS_PORT="6379"
    
    cat > "$CREDENTIALS_DIR/redis.env" <<EOF
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT
EOF
    chmod 600 "$CREDENTIALS_DIR/redis.env"
fi

# Charger les credentials RabbitMQ
if [ -f "$CREDENTIALS_DIR/rabbitmq.env" ]; then
    echo -e "  $OK rabbitmq.env trouvé" | tee -a "$LOG_FILE"
    
    RABBITMQ_USER=$(get_env_value "$CREDENTIALS_DIR/rabbitmq.env" "RABBITMQ_USER" "keybuzz")
    RABBITMQ_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/rabbitmq.env" "RABBITMQ_PASSWORD" "$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)")
    RABBITMQ_HOST=$(get_env_value "$CREDENTIALS_DIR/rabbitmq.env" "RABBITMQ_HOST" "10.0.0.10")
    RABBITMQ_PORT=$(get_env_value "$CREDENTIALS_DIR/rabbitmq.env" "RABBITMQ_PORT" "5672")
    RABBITMQ_MANAGEMENT_PORT=$(get_env_value "$CREDENTIALS_DIR/rabbitmq.env" "RABBITMQ_MANAGEMENT_PORT" "15672")
else
    echo -e "  $WARN rabbitmq.env introuvable, création..." | tee -a "$LOG_FILE"
    
    RABBITMQ_USER="keybuzz"
    RABBITMQ_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    RABBITMQ_HOST="10.0.0.10"
    RABBITMQ_PORT="5672"
    RABBITMQ_MANAGEMENT_PORT="15672"
    
    cat > "$CREDENTIALS_DIR/rabbitmq.env" <<EOF
RABBITMQ_USER=$RABBITMQ_USER
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
RABBITMQ_HOST=$RABBITMQ_HOST
RABBITMQ_PORT=$RABBITMQ_PORT
RABBITMQ_MANAGEMENT_PORT=$RABBITMQ_MANAGEMENT_PORT
EOF
    chmod 600 "$CREDENTIALS_DIR/rabbitmq.env"
fi

# MinIO credentials
if [ -f "$CREDENTIALS_DIR/minio.env" ]; then
    echo -e "  $OK minio.env trouvé" | tee -a "$LOG_FILE"
    
    MINIO_ROOT_USER=$(get_env_value "$CREDENTIALS_DIR/minio.env" "MINIO_ROOT_USER" "keybuzz")
    MINIO_ROOT_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/minio.env" "MINIO_ROOT_PASSWORD" "$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)")
    MINIO_ENDPOINT=$(get_env_value "$CREDENTIALS_DIR/minio.env" "MINIO_ENDPOINT" "http://s3.keybuzz.io:9000")
    MINIO_BUCKET=$(get_env_value "$CREDENTIALS_DIR/minio.env" "MINIO_BUCKET" "keybuzz-backups")
else
    echo -e "  $WARN minio.env introuvable, création..." | tee -a "$LOG_FILE"
    
    MINIO_ROOT_USER="keybuzz"
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    MINIO_ENDPOINT="http://s3.keybuzz.io:9000"
    MINIO_BUCKET="keybuzz-backups"
    
    cat > "$CREDENTIALS_DIR/minio.env" <<EOF
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
MINIO_ENDPOINT=$MINIO_ENDPOINT
MINIO_BUCKET=$MINIO_BUCKET
EOF
    chmod 600 "$CREDENTIALS_DIR/minio.env"
fi

echo "" | tee -a "$LOG_FILE"
echo "Résumé des credentials :" | tee -a "$LOG_FILE"
echo "  PostgreSQL : ${POSTGRES_HOST}:${POSTGRES_PORT_POOL} (POOL)" | tee -a "$LOG_FILE"
echo "  Redis      : ${REDIS_HOST}:${REDIS_PORT}" | tee -a "$LOG_FILE"
echo "  RabbitMQ   : ${RABBITMQ_HOST}:${RABBITMQ_PORT}" | tee -a "$LOG_FILE"
echo "  MinIO      : ${MINIO_ENDPOINT}" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Test de connectivité data-plane depuis K3s workers
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 2/5 : Test connectivité data-plane ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Test depuis un worker K3s
WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "Test depuis k3s-worker-01 ($WORKER_IP) :" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Test PostgreSQL
echo -n "  PostgreSQL ${POSTGRES_HOST}:${POSTGRES_PORT_POOL} ... " | tee -a "$LOG_FILE"
if ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "timeout 3 nc -zv ${POSTGRES_HOST} ${POSTGRES_PORT_POOL} 2>&1" | grep -q succeeded; then
    echo -e "$OK" | tee -a "$LOG_FILE"
else
    echo -e "$WARN (port fermé ou data-plane non déployée)" | tee -a "$LOG_FILE"
fi

# Test Redis
echo -n "  Redis ${REDIS_HOST}:${REDIS_PORT} ... " | tee -a "$LOG_FILE"
if ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "timeout 3 nc -zv ${REDIS_HOST} ${REDIS_PORT} 2>&1" | grep -q succeeded; then
    echo -e "$OK" | tee -a "$LOG_FILE"
else
    echo -e "$WARN (port fermé ou data-plane non déployée)" | tee -a "$LOG_FILE"
fi

# Test RabbitMQ
echo -n "  RabbitMQ ${RABBITMQ_HOST}:${RABBITMQ_PORT} ... " | tee -a "$LOG_FILE"
if ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "timeout 3 nc -zv ${RABBITMQ_HOST} ${RABBITMQ_PORT} 2>&1" | grep -q succeeded; then
    echo -e "$OK" | tee -a "$LOG_FILE"
else
    echo -e "$WARN (port fermé ou data-plane non déployée)" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Génération des .env pour chaque application
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 3/5 : Génération des .env applicatifs ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ─── n8n ───────────────────────────────────────────────────────────────────

echo "→ Génération n8n.env" | tee -a "$LOG_FILE"

N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '=+/')

cat > "$APPS_DIR/n8n.env" <<EOF
# n8n Configuration - KeyBuzz Production
# Generated: $(date)

# Database (PostgreSQL via PgBouncer POOL)
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=${POSTGRES_HOST}
DB_POSTGRESDB_PORT=${POSTGRES_PORT_POOL}
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
N8N_POSTGRESDB_QUERY_MODE=simple

# Redis Queue
QUEUE_BULL_REDIS_HOST=${REDIS_HOST}
QUEUE_BULL_REDIS_PORT=${REDIS_PORT}
QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
EXECUTIONS_MODE=queue

# Security
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_DISABLED=false

# Webhook & URLs
WEBHOOK_URL=https://n8n.keybuzz.io/
N8N_PROTOCOL=https
N8N_HOST=n8n.keybuzz.io
N8N_PORT=5678

# Timezone
GENERIC_TIMEZONE=Europe/Paris
TZ=Europe/Paris

# Logs
N8N_LOG_LEVEL=info
N8N_LOG_OUTPUT=console
EOF

chmod 600 "$APPS_DIR/n8n.env"
echo -e "  $OK n8n.env créé" | tee -a "$LOG_FILE"

# ─── Chatwoot ──────────────────────────────────────────────────────────────

echo "→ Génération chatwoot.env" | tee -a "$LOG_FILE"

CHATWOOT_SECRET_KEY_BASE=$(openssl rand -hex 64)

cat > "$APPS_DIR/chatwoot.env" <<EOF
# Chatwoot Configuration - KeyBuzz Production
# Generated: $(date)

# Database (PostgreSQL DIRECT - incompatible avec PgBouncer session pooling)
DATABASE_URL=postgresql://chatwoot:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT_RW}/chatwoot
PGBOUNCER=false
PREPARED_STATEMENTS=true

# Redis (Sentinel aware via HAProxy TCP 6379)
REDIS_URL=redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/0

# Security
SECRET_KEY_BASE=${CHATWOOT_SECRET_KEY_BASE}

# URLs
FRONTEND_URL=https://chat.keybuzz.io
FORCE_SSL=false

# Storage (MinIO S3)
ACTIVE_STORAGE_SERVICE=s3_compatible
AWS_ACCESS_KEY_ID=${MINIO_ROOT_USER}
AWS_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD}
AWS_REGION=us-east-1
AWS_BUCKET=chatwoot-files
AWS_ENDPOINT=http://s3.keybuzz.io:9000
AWS_FORCE_PATH_STYLE=true

# SMTP
SMTP_ADDRESS=mail.keybuzz.io
SMTP_PORT=587
SMTP_USERNAME=noreply@keybuzz.io
SMTP_PASSWORD=changeme
SMTP_DOMAIN=keybuzz.io

# Rails
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
RAILS_MAX_THREADS=5

# Timezone
TZ=Europe/Paris
EOF

chmod 600 "$APPS_DIR/chatwoot.env"
echo -e "  $OK chatwoot.env créé" | tee -a "$LOG_FILE"

# ─── ERPNext ───────────────────────────────────────────────────────────────

echo "→ Génération erpnext.env" | tee -a "$LOG_FILE"

cat > "$APPS_DIR/erpnext.env" <<EOF
# ERPNext Configuration - KeyBuzz Production
# Generated: $(date)

# Database (PgBouncer POOL)
DB_HOST=${POSTGRES_HOST}
DB_PORT=${POSTGRES_PORT_POOL}
DB_NAME=erpnext
DB_USER=erpnext
DB_PASSWORD=${POSTGRES_PASSWORD}

# Redis (différentes DB pour chaque service)
REDIS_CACHE=redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/1
REDIS_QUEUE=redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/2
REDIS_SOCKETIO=redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/3

# Site
SITE_NAME=erp.keybuzz.io
ADMIN_PASSWORD=${POSTGRES_PASSWORD}

# Storage S3 (MinIO)
S3_ENDPOINT=http://s3.keybuzz.io:9000
S3_ACCESS_KEY=${MINIO_ROOT_USER}
S3_SECRET_KEY=${MINIO_ROOT_PASSWORD}
S3_BUCKET=erpnext-files
S3_REGION=us-east-1

# SMTP
SMTP_HOST=mail.keybuzz.io
SMTP_PORT=587
SMTP_USER=noreply@keybuzz.io
SMTP_PASSWORD=changeme

# Timezone
TZ=Europe/Paris
EOF

chmod 600 "$APPS_DIR/erpnext.env"
echo -e "  $OK erpnext.env créé" | tee -a "$LOG_FILE"

# ─── LiteLLM Router ────────────────────────────────────────────────────────

echo "→ Génération litellm.env" | tee -a "$LOG_FILE"

LITELLM_MASTER_KEY=$(openssl rand -base64 32 | tr -d '=+/')

cat > "$APPS_DIR/litellm.env" <<EOF
# LiteLLM Router Configuration - KeyBuzz Production
# Generated: $(date)

# Database (PgBouncer POOL)
DATABASE_URL=postgresql://litellm:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT_POOL}/litellm

# Master Key
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}

# Redis Cache
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Configuration
UI_USERNAME=admin
UI_PASSWORD=${POSTGRES_PASSWORD}
STORE_MODEL_IN_DB=true

# Logging
LITELLM_LOG=INFO
EOF

chmod 600 "$APPS_DIR/litellm.env"
echo -e "  $OK litellm.env créé" | tee -a "$LOG_FILE"

# ─── Qdrant ────────────────────────────────────────────────────────────────

echo "→ Génération qdrant.env" | tee -a "$LOG_FILE"

QDRANT_API_KEY=$(openssl rand -base64 32 | tr -d '=+/')

cat > "$APPS_DIR/qdrant.env" <<EOF
# Qdrant Vector Database Configuration - KeyBuzz Production
# Generated: $(date)

# API Key
QDRANT__SERVICE__API_KEY=${QDRANT_API_KEY}

# Telemetry
QDRANT__TELEMETRY_DISABLED=true

# Storage
QDRANT__STORAGE__STORAGE_PATH=/qdrant/storage
QDRANT__STORAGE__SNAPSHOTS_PATH=/qdrant/snapshots

# Performance
QDRANT__SERVICE__MAX_REQUEST_SIZE_MB=32
QDRANT__SERVICE__HTTP_PORT=6333
QDRANT__SERVICE__GRPC_PORT=6334
EOF

chmod 600 "$APPS_DIR/qdrant.env"
echo -e "  $OK qdrant.env créé" | tee -a "$LOG_FILE"

# ─── Superset ──────────────────────────────────────────────────────────────

echo "→ Génération superset.env" | tee -a "$LOG_FILE"

SUPERSET_SECRET_KEY=$(openssl rand -base64 32 | tr -d '=+/')

cat > "$APPS_DIR/superset.env" <<EOF
# Apache Superset Configuration - KeyBuzz Production
# Generated: $(date)

# Database (PgBouncer POOL)
SQLALCHEMY_DATABASE_URI=postgresql://superset:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT_POOL}/superset

# Redis Cache
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Secret Key
SECRET_KEY=${SUPERSET_SECRET_KEY}

# Admin
ADMIN_USERNAME=admin
ADMIN_EMAIL=admin@keybuzz.io
ADMIN_FIRSTNAME=Admin
ADMIN_LASTNAME=KeyBuzz
ADMIN_PASSWORD=${POSTGRES_PASSWORD}

# Configuration
SUPERSET_WEBSERVER_PORT=8088
SUPERSET_LOAD_EXAMPLES=false
EOF

chmod 600 "$APPS_DIR/superset.env"
echo -e "  $OK superset.env créé" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo -e "  $OK 6 fichiers .env créés dans $APPS_DIR" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : Création des secrets Kubernetes
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 4/5 : Création des secrets Kubernetes ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Script pour créer les secrets sur master-01
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'SECRETS_SCRIPT' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Création des namespaces..."

# Créer les namespaces
for ns in n8n chatwoot erpnext litellm qdrant superset; do
    kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    echo "  ✓ Namespace $ns"
done

echo ""
echo "[$(date '+%F %T')] Création des secrets depuis les .env..."

# Note: Les .env seront copiés et les secrets créés via le script suivant
echo "  ℹ Les secrets seront créés lors du déploiement Helm"
echo "  ℹ Fichiers .env disponibles dans /opt/keybuzz-installer/apps"

SECRETS_SCRIPT

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 5 : Génération du résumé
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 5/5 : Génération du résumé ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

cat > "$CREDENTIALS_DIR/apps-summary.txt" <<SUMMARY
KeyBuzz Apps - Configuration Summary
=====================================
Generated: $(date)

Applications configurées :
  1. n8n          - Automatisation workflows
  2. Chatwoot     - Customer Support
  3. ERPNext      - ERP/CRM
  4. LiteLLM      - LLM Router
  5. Qdrant       - Vector Database
  6. Superset     - Business Intelligence

Fichiers .env :
  $APPS_DIR/n8n.env
  $APPS_DIR/chatwoot.env
  $APPS_DIR/erpnext.env
  $APPS_DIR/litellm.env
  $APPS_DIR/qdrant.env
  $APPS_DIR/superset.env

Data-plane (endpoints) :
  PostgreSQL POOL : ${POSTGRES_HOST}:${POSTGRES_PORT_POOL}
  PostgreSQL RW   : ${POSTGRES_HOST}:${POSTGRES_PORT_RW}
  PostgreSQL RO   : ${POSTGRES_HOST}:${POSTGRES_PORT_RO}
  Redis           : ${REDIS_HOST}:${REDIS_PORT}
  RabbitMQ        : ${RABBITMQ_HOST}:${RABBITMQ_PORT}
  MinIO           : ${MINIO_ENDPOINT}

Namespaces Kubernetes :
  - n8n
  - chatwoot
  - erpnext
  - litellm
  - qdrant
  - superset

Prochaine étape :
  ./apps_helm_deploy.sh
SUMMARY

echo -e "  $OK Résumé créé : $CREDENTIALS_DIR/apps-summary.txt" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# Résumé final
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo -e "$OK PRÉPARATION DES ENVIRONNEMENTS TERMINÉE" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Fichiers créés :" | tee -a "$LOG_FILE"
echo "  - 4 credentials : postgres, redis, rabbitmq, minio" | tee -a "$LOG_FILE"
echo "  - 6 apps .env   : n8n, chatwoot, erpnext, litellm, qdrant, superset" | tee -a "$LOG_FILE"
echo "  - 6 namespaces K8s créés" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Commandes utiles :" | tee -a "$LOG_FILE"
echo "  # Voir les .env générés" | tee -a "$LOG_FILE"
echo "  ls -lh $APPS_DIR/" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Voir le résumé" | tee -a "$LOG_FILE"
echo "  cat $CREDENTIALS_DIR/apps-summary.txt" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Voir les namespaces" | tee -a "$LOG_FILE"
echo "  ssh root@$IP_MASTER01 kubectl get namespaces" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Prochaine étape :" | tee -a "$LOG_FILE"
echo "  ./apps_helm_deploy.sh" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "═══════════════════════════════════════════════════════════════════"
echo "Log complet (50 dernières lignes) :"
echo "═══════════════════════════════════════════════════════════════════"
tail -n 50 "$LOG_FILE"

exit 0
