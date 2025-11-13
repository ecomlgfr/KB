#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         K3S HA APPS - Préparation Environnements & Secrets (V2)   ║"
echo "║            (n8n, Chatwoot, LiteLLM, Qdrant, Superset)             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
APPS_DIR="/opt/keybuzz-installer/apps"
LOG_DIR="/opt/keybuzz-installer/logs"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
mkdir -p "$APPS_DIR" "$LOG_DIR"

LOG_FILE="$LOG_DIR/apps_prepare_env.log"

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
# ÉTAPE 1 : Charger les credentials data-plane
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 1/4 : Chargement credentials data-plane ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# PostgreSQL
if [ ! -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "$KO postgres.env introuvable" | tee -a "$LOG_FILE"
    exit 1
fi

echo -e "  $OK postgres.env trouvé" | tee -a "$LOG_FILE"
source "$CREDENTIALS_DIR/postgres.env"

# Définir les valeurs par défaut
POSTGRES_HOST=${POSTGRES_HOST:-10.0.0.10}
POSTGRES_PORT_RW=${POSTGRES_PORT_RW:-5432}
POSTGRES_PORT_RO=${POSTGRES_PORT_RO:-5433}
POSTGRES_PORT_POOL=${POSTGRES_PORT_POOL:-4632}

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "$KO POSTGRES_PASSWORD non défini" | tee -a "$LOG_FILE"
    exit 1
fi

# Redis
if [ ! -f "$CREDENTIALS_DIR/redis.env" ]; then
    echo -e "$KO redis.env introuvable" | tee -a "$LOG_FILE"
    exit 1
fi

echo -e "  $OK redis.env trouvé" | tee -a "$LOG_FILE"
source "$CREDENTIALS_DIR/redis.env"

REDIS_HOST=${REDIS_HOST:-10.0.0.10}
REDIS_PORT=${REDIS_PORT:-6379}

if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo -e "$KO REDIS_PASSWORD non défini" | tee -a "$LOG_FILE"
    exit 1
fi

# RabbitMQ (optionnel)
if [ -f "$CREDENTIALS_DIR/rabbitmq.env" ]; then
    echo -e "  $OK rabbitmq.env trouvé" | tee -a "$LOG_FILE"
    source "$CREDENTIALS_DIR/rabbitmq.env"
    
    RABBITMQ_HOST=${RABBITMQ_HOST:-10.0.0.10}
    RABBITMQ_PORT=${RABBITMQ_PORT:-5672}
else
    echo -e "  $WARN rabbitmq.env introuvable (optionnel)" | tee -a "$LOG_FILE"
fi

# MinIO
if [ -f "$CREDENTIALS_DIR/minio.env" ]; then
    echo -e "  $OK minio.env trouvé" | tee -a "$LOG_FILE"
    source "$CREDENTIALS_DIR/minio.env"
else
    echo -e "  $WARN minio.env introuvable, création..." | tee -a "$LOG_FILE"
    
    MINIO_ROOT_USER="keybuzz"
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    MINIO_ENDPOINT="http://s3.keybuzz.io:9000"
    
    cat > "$CREDENTIALS_DIR/minio.env" <<EOF
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
MINIO_ENDPOINT=$MINIO_ENDPOINT
EOF
    chmod 600 "$CREDENTIALS_DIR/minio.env"
fi

MINIO_ROOT_USER=${MINIO_ROOT_USER:-keybuzz}
MINIO_ENDPOINT=${MINIO_ENDPOINT:-http://s3.keybuzz.io:9000}

echo "" | tee -a "$LOG_FILE"
echo "Résumé des credentials :" | tee -a "$LOG_FILE"
echo "  PostgreSQL : ${POSTGRES_HOST}:${POSTGRES_PORT_POOL} (POOL)" | tee -a "$LOG_FILE"
echo "  Redis      : ${REDIS_HOST}:${REDIS_PORT}" | tee -a "$LOG_FILE"
echo "  MinIO      : ${MINIO_ENDPOINT}" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Test de connectivité
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 2/4 : Test connectivité data-plane ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "Test depuis k3s-worker-01 ($WORKER_IP) :" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Test PostgreSQL
echo -n "  PostgreSQL ${POSTGRES_HOST}:${POSTGRES_PORT_POOL} ... " | tee -a "$LOG_FILE"
if ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "timeout 3 bash -c '</dev/tcp/${POSTGRES_HOST}/${POSTGRES_PORT_POOL}'" 2>/dev/null; then
    echo -e "$OK" | tee -a "$LOG_FILE"
else
    echo -e "$WARN" | tee -a "$LOG_FILE"
fi

# Test Redis
echo -n "  Redis ${REDIS_HOST}:${REDIS_PORT} ... " | tee -a "$LOG_FILE"
if ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "timeout 3 bash -c '</dev/tcp/${REDIS_HOST}/${REDIS_PORT}'" 2>/dev/null; then
    echo -e "$OK" | tee -a "$LOG_FILE"
else
    echo -e "$WARN" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Génération des .env applicatifs
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 3/4 : Génération des .env applicatifs ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ─── n8n ───────────────────────────────────────────────────────────────────

echo "→ Génération n8n.env" | tee -a "$LOG_FILE"

N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

cat > "$APPS_DIR/n8n.env" <<EOF
# n8n Configuration - KeyBuzz Production

# Database (PgBouncer POOL)
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=${POSTGRES_HOST}
DB_POSTGRESDB_PORT=${POSTGRES_PORT_POOL}
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
DB_POSTGRESDB_SCHEMA=public

# Queue (Bull with Redis)
QUEUE_BULL_REDIS_HOST=${REDIS_HOST}
QUEUE_BULL_REDIS_PORT=${REDIS_PORT}
QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
QUEUE_BULL_REDIS_DB=0
EXECUTIONS_MODE=queue

# URLs
WEBHOOK_URL=https://n8n.keybuzz.io/
N8N_PROTOCOL=https
N8N_HOST=n8n.keybuzz.io
N8N_PORT=5678

# Security
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

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

# Database (PostgreSQL DIRECT - incompatible avec PgBouncer session pooling)
DATABASE_URL=postgresql://chatwoot:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT_RW}/chatwoot
PGBOUNCER=false
PREPARED_STATEMENTS=true

# Redis (avec mot de passe)
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
AWS_ENDPOINT=${MINIO_ENDPOINT}
AWS_FORCE_PATH_STYLE=true

# Rails
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
RAILS_MAX_THREADS=5

# Timezone
TZ=Europe/Paris
EOF

chmod 600 "$APPS_DIR/chatwoot.env"
echo -e "  $OK chatwoot.env créé" | tee -a "$LOG_FILE"

# ─── LiteLLM ───────────────────────────────────────────────────────────────

echo "→ Génération litellm.env" | tee -a "$LOG_FILE"

LITELLM_MASTER_KEY=$(openssl rand -base64 32 | tr -d '=+/')

cat > "$APPS_DIR/litellm.env" <<EOF
# LiteLLM Configuration - KeyBuzz Production

# Database (PgBouncer POOL)
DATABASE_URL=postgresql://litellm:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT_POOL}/litellm

# Redis
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Security
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}

# Config
STORE_MODEL_IN_DB=true
EOF

chmod 600 "$APPS_DIR/litellm.env"
echo -e "  $OK litellm.env créé" | tee -a "$LOG_FILE"

# ─── Qdrant ────────────────────────────────────────────────────────────────

echo "→ Génération qdrant.env" | tee -a "$LOG_FILE"

QDRANT_API_KEY=$(openssl rand -base64 32 | tr -d '=+/')

cat > "$APPS_DIR/qdrant.env" <<EOF
# Qdrant Configuration - KeyBuzz Production

QDRANT__SERVICE__API_KEY=${QDRANT_API_KEY}
QDRANT__TELEMETRY_DISABLED=true
QDRANT__SERVICE__HTTP_PORT=6333
QDRANT__SERVICE__GRPC_PORT=6334
EOF

chmod 600 "$APPS_DIR/qdrant.env"
echo -e "  $OK qdrant.env créé" | tee -a "$LOG_FILE"

# ─── Superset ──────────────────────────────────────────────────────────────

echo "→ Génération superset.env" | tee -a "$LOG_FILE"

SUPERSET_SECRET_KEY=$(openssl rand -base64 42)

cat > "$APPS_DIR/superset.env" <<EOF
# Superset Configuration - KeyBuzz Production

# Database (PostgreSQL DIRECT)
DATABASE_URL=postgresql://superset:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT_RW}/superset

# Redis
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Security
SUPERSET_SECRET_KEY=${SUPERSET_SECRET_KEY}

# Admin
SUPERSET_ADMIN_USERNAME=admin
SUPERSET_ADMIN_PASSWORD=${POSTGRES_PASSWORD}
SUPERSET_ADMIN_EMAIL=admin@keybuzz.io
EOF

chmod 600 "$APPS_DIR/superset.env"
echo -e "  $OK superset.env créé" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : Création des secrets Kubernetes
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 4/4 : Création des secrets Kubernetes ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Copier les .env sur le master
echo "→ Copie des .env sur master-01" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "mkdir -p /opt/keybuzz/apps"

for env_file in n8n chatwoot litellm qdrant superset; do
    scp -o StrictHostKeyChecking=no "$APPS_DIR/${env_file}.env" root@"$IP_MASTER01":/opt/keybuzz/apps/
done

echo "" | tee -a "$LOG_FILE"

# Créer les namespaces et secrets
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'REMOTE_K8S'
set -u

echo "Création des namespaces..."

for ns in n8n chatwoot litellm qdrant superset; do
    kubectl create namespace $ns 2>/dev/null || true
    echo "  ✓ Namespace $ns"
done

echo ""
echo "Création des secrets..."

# n8n
kubectl create secret generic n8n-config \
  --from-env-file=/opt/keybuzz/apps/n8n.env \
  -n n8n --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Secret n8n-config"

# Chatwoot
kubectl create secret generic chatwoot-config \
  --from-env-file=/opt/keybuzz/apps/chatwoot.env \
  -n chatwoot --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Secret chatwoot-config"

# LiteLLM
kubectl create secret generic litellm-config \
  --from-env-file=/opt/keybuzz/apps/litellm.env \
  -n litellm --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Secret litellm-config"

# Qdrant
kubectl create secret generic qdrant-config \
  --from-env-file=/opt/keybuzz/apps/qdrant.env \
  -n qdrant --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Secret qdrant-config"

# Superset
kubectl create secret generic superset-config \
  --from-env-file=/opt/keybuzz/apps/superset.env \
  -n superset --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ Secret superset-config"

REMOTE_K8S

if [ $? -eq 0 ]; then
    echo "" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo -e "$OK Environnements préparés" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Fichiers générés dans $APPS_DIR :" | tee -a "$LOG_FILE"
    ls -lh "$APPS_DIR"/*.env | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Prochaine étape :" | tee -a "$LOG_FILE"
    echo "  ./04_apps_helm_deploy.sh" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
else
    echo "" | tee -a "$LOG_FILE"
    echo -e "$KO Erreur lors de la création des secrets" | tee -a "$LOG_FILE"
    exit 1
fi

tail -n 50 "$LOG_FILE"
