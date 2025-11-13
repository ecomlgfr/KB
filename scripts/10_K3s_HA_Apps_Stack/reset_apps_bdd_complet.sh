#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    RÉINITIALISATION BDD & SECRETS - Applications K3s               ║"
echo "║    (n8n, LiteLLM, Qdrant, Chatwoot, Superset)                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✅ OK\033[0m'
KO='\033[0;31m❌ KO\033[0m'
WARN='\033[0;33m⚠️ WARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
POSTGRES_ENV="/opt/keybuzz-installer/credentials/postgres.env"
REDIS_ENV="/opt/keybuzz-installer/credentials/redis.env"
RABBITMQ_ENV="/opt/keybuzz-installer/credentials/rabbitmq.env"
LOG_FILE="/opt/keybuzz-installer/logs/reset_apps_bdd_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

# Vérifications
if [ ! -f "$SERVERS_TSV" ]; then
    echo -e "$KO servers.tsv introuvable"
    exit 1
fi

if [ ! -f "$POSTGRES_ENV" ]; then
    echo -e "$KO postgres.env introuvable"
    exit 1
fi

source "$POSTGRES_ENV"

if [ -f "$REDIS_ENV" ]; then
    source "$REDIS_ENV"
fi

if [ -f "$RABBITMQ_ENV" ]; then
    source "$RABBITMQ_ENV"
fi

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
IP_DB_LB="10.0.0.10"

echo ""
echo "⚠️  AVERTISSEMENT ⚠️"
echo "Ce script va :"
echo "   1. Supprimer et recréer les bases de données applicatives"
echo "   2. Supprimer et recréer les secrets Kubernetes"
echo "   3. Redémarrer tous les pods des applications"
echo ""
echo "🚨 TOUTES LES DONNÉES SERONT PERDUES 🚨"
echo ""
read -p "Êtes-vous ABSOLUMENT sûr de vouloir continuer ? (tapez 'OUI' en majuscules) : " CONFIRM

if [ "$CONFIRM" != "OUI" ]; then
    echo "Annulé par l'utilisateur"
    exit 0
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. SUPPRESSION DES BASES DE DONNÉES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for db in n8n litellm qdrant_db superset chatwoot; do
    echo "🗑️  Suppression base '$db'..."
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres <<-EOSQL 2>&1 | grep -v "does not exist"
		-- Terminer toutes les connexions actives
		SELECT pg_terminate_backend(pid) 
		FROM pg_stat_activity 
		WHERE datname = '$db' AND pid <> pg_backend_pid();
		
		-- Supprimer la base
		DROP DATABASE IF EXISTS $db;
	EOSQL
    echo -e "$OK Base '$db' supprimée"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. RECRÉATION DES BASES DE DONNÉES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# N8N
echo "🔧 Création base n8n..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres <<-EOSQL
	CREATE DATABASE n8n 
	    WITH ENCODING='UTF8' 
	    LC_COLLATE='en_US.UTF-8' 
	    LC_CTYPE='en_US.UTF-8' 
	    TEMPLATE=template0;
	GRANT ALL PRIVILEGES ON DATABASE n8n TO ${POSTGRES_USER};
EOSQL
echo -e "$OK Base n8n créée"

# LiteLLM
echo "🔧 Création base litellm..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres <<-EOSQL
	CREATE DATABASE litellm 
	    WITH ENCODING='UTF8' 
	    LC_COLLATE='en_US.UTF-8' 
	    LC_CTYPE='en_US.UTF-8' 
	    TEMPLATE=template0;
	GRANT ALL PRIVILEGES ON DATABASE litellm TO ${POSTGRES_USER};
EOSQL
echo -e "$OK Base litellm créée"

# Qdrant
echo "🔧 Création base qdrant_db..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres <<-EOSQL
	CREATE DATABASE qdrant_db 
	    WITH ENCODING='UTF8' 
	    LC_COLLATE='en_US.UTF-8' 
	    LC_CTYPE='en_US.UTF-8' 
	    TEMPLATE=template0;
	GRANT ALL PRIVILEGES ON DATABASE qdrant_db TO ${POSTGRES_USER};
EOSQL
echo -e "$OK Base qdrant_db créée"

# Superset
echo "🔧 Création base superset..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres <<-EOSQL
	CREATE DATABASE superset 
	    WITH ENCODING='UTF8' 
	    LC_COLLATE='en_US.UTF-8' 
	    LC_CTYPE='en_US.UTF-8' 
	    TEMPLATE=template0;
	GRANT ALL PRIVILEGES ON DATABASE superset TO ${POSTGRES_USER};
EOSQL
echo -e "$OK Base superset créée"

# Chatwoot (avec pgvector)
echo "🔧 Création base chatwoot avec pgvector..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres <<-EOSQL
	CREATE DATABASE chatwoot 
	    WITH ENCODING='UTF8' 
	    LC_COLLATE='en_US.UTF-8' 
	    LC_CTYPE='en_US.UTF-8' 
	    TEMPLATE=template0;
	GRANT ALL PRIVILEGES ON DATABASE chatwoot TO ${POSTGRES_USER};
EOSQL

PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d chatwoot <<-EOSQL
	CREATE EXTENSION IF NOT EXISTS vector;
	CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
	CREATE EXTENSION IF NOT EXISTS pg_trgm;
	CREATE EXTENSION IF NOT EXISTS pgcrypto;
EOSQL
echo -e "$OK Base chatwoot créée avec extensions"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. GÉNÉRATION DES SECRETS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

N8N_ENCRYPTION_KEY=$(generate_secret)
LITELLM_MASTER_KEY=$(generate_secret)
QDRANT_API_KEY=$(generate_secret)
SUPERSET_SECRET_KEY=$(generate_secret)
CHATWOOT_SECRET_KEY=$(generate_secret)

echo "🔑 Secrets générés :"
echo "   • N8N_ENCRYPTION_KEY    : ${N8N_ENCRYPTION_KEY:0:8}***"
echo "   • LITELLM_MASTER_KEY    : ${LITELLM_MASTER_KEY:0:8}***"
echo "   • QDRANT_API_KEY        : ${QDRANT_API_KEY:0:8}***"
echo "   • SUPERSET_SECRET_KEY   : ${SUPERSET_SECRET_KEY:0:8}***"
echo "   • CHATWOOT_SECRET_KEY   : ${CHATWOOT_SECRET_KEY:0:8}***"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. SUPPRESSION DES SECRETS K8S EXISTANTS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ns in n8n litellm qdrant superset chatwoot; do
    echo "🗑️  Suppression secrets dans namespace '$ns'..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl delete secret --all -n $ns 2>/dev/null" || true
    echo -e "$OK Secrets supprimés dans '$ns'"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. RECRÉATION DES SECRETS K8S ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Secret N8N
echo "🔧 Création secret n8n..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" <<EOSSH
kubectl create secret generic n8n-secrets -n n8n \
    --from-literal=DB_TYPE=postgresdb \
    --from-literal=DB_POSTGRESDB_HOST=10.0.0.10 \
    --from-literal=DB_POSTGRESDB_PORT=5432 \
    --from-literal=DB_POSTGRESDB_DATABASE=n8n \
    --from-literal=DB_POSTGRESDB_USER=${POSTGRES_USER} \
    --from-literal=DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD} \
    --from-literal=N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
EOSSH
echo -e "$OK Secret n8n créé"

# Secret LiteLLM
echo "🔧 Création secret litellm..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" <<EOSSH
kubectl create secret generic litellm-secrets -n litellm \
    --from-literal=DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@10.0.0.10:5432/litellm" \
    --from-literal=LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY} \
    --from-literal=REDIS_HOST=10.0.0.10 \
    --from-literal=REDIS_PORT=6379 \
    --from-literal=REDIS_PASSWORD=${REDIS_PASSWORD:-}
EOSSH
echo -e "$OK Secret litellm créé"

# Secret Qdrant
echo "🔧 Création secret qdrant..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" <<EOSSH
kubectl create secret generic qdrant-secrets -n qdrant \
    --from-literal=QDRANT__SERVICE__API_KEY=${QDRANT_API_KEY}
EOSSH
echo -e "$OK Secret qdrant créé"

# Secret Superset
echo "🔧 Création secret superset..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" <<EOSSH
kubectl create secret generic superset-secrets -n superset \
    --from-literal=DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@10.0.0.10:5432/superset" \
    --from-literal=SECRET_KEY=${SUPERSET_SECRET_KEY} \
    --from-literal=REDIS_HOST=10.0.0.10 \
    --from-literal=REDIS_PORT=6379 \
    --from-literal=REDIS_PASSWORD=${REDIS_PASSWORD:-}
EOSSH
echo -e "$OK Secret superset créé"

# Secret Chatwoot
echo "🔧 Création secret chatwoot..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" <<EOSSH
kubectl create secret generic chatwoot-secrets -n chatwoot \
    --from-literal=POSTGRES_HOST=10.0.0.10 \
    --from-literal=POSTGRES_PORT=5432 \
    --from-literal=POSTGRES_DATABASE=chatwoot \
    --from-literal=POSTGRES_USERNAME=${POSTGRES_USER} \
    --from-literal=POSTGRES_PASSWORD=${POSTGRES_PASSWORD} \
    --from-literal=SECRET_KEY_BASE=${CHATWOOT_SECRET_KEY} \
    --from-literal=REDIS_URL="redis://10.0.0.10:6379" \
    --from-literal=REDIS_PASSWORD=${REDIS_PASSWORD:-} \
    --from-literal=RABBITMQ_HOST=10.0.0.10 \
    --from-literal=RABBITMQ_USERNAME=${RABBITMQ_USER:-admin} \
    --from-literal=RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-}
EOSSH
echo -e "$OK Secret chatwoot créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. SAUVEGARDE DES CREDENTIALS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

CREDS_FILE="/opt/keybuzz-installer/credentials/apps-secrets-$(date +%Y%m%d_%H%M%S).env"

cat > "$CREDS_FILE" <<EOF
# Secrets applicatifs générés le $(date)
# À conserver en lieu sûr

# N8N
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_DB_HOST=10.0.0.10
N8N_DB_PORT=5432
N8N_DB_NAME=n8n
N8N_DB_USER=${POSTGRES_USER}
N8N_DB_PASSWORD=${POSTGRES_PASSWORD}

# LiteLLM
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
LITELLM_DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@10.0.0.10:5432/litellm
LITELLM_REDIS_HOST=10.0.0.10
LITELLM_REDIS_PORT=6379
LITELLM_REDIS_PASSWORD=${REDIS_PASSWORD:-}

# Qdrant
QDRANT_API_KEY=${QDRANT_API_KEY}

# Superset
SUPERSET_SECRET_KEY=${SUPERSET_SECRET_KEY}
SUPERSET_DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@10.0.0.10:5432/superset
SUPERSET_REDIS_HOST=10.0.0.10
SUPERSET_REDIS_PORT=6379
SUPERSET_REDIS_PASSWORD=${REDIS_PASSWORD:-}

# Chatwoot
CHATWOOT_SECRET_KEY_BASE=${CHATWOOT_SECRET_KEY}
CHATWOOT_POSTGRES_HOST=10.0.0.10
CHATWOOT_POSTGRES_PORT=5432
CHATWOOT_POSTGRES_DATABASE=chatwoot
CHATWOOT_POSTGRES_USERNAME=${POSTGRES_USER}
CHATWOOT_POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
CHATWOOT_REDIS_URL=redis://10.0.0.10:6379
CHATWOOT_REDIS_PASSWORD=${REDIS_PASSWORD:-}
CHATWOOT_RABBITMQ_HOST=10.0.0.10
CHATWOOT_RABBITMQ_USERNAME=${RABBITMQ_USER:-admin}
CHATWOOT_RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-}
EOF

chmod 600 "$CREDS_FILE"
echo -e "$OK Credentials sauvegardés : $CREDS_FILE"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. REDÉMARRAGE DES PODS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ns in n8n litellm qdrant superset chatwoot; do
    echo "🔄 Redémarrage pods '$ns'..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl rollout restart daemonset -n $ns 2>/dev/null" || {
        echo -e "$WARN Pas de DaemonSet dans '$ns', tentative Deployment..."
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl rollout restart deployment -n $ns 2>/dev/null" || echo -e "$WARN Aucun workload à redémarrer"
    }
    echo -e "$OK Pods redémarrés dans '$ns'"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. ATTENTE STABILISATION (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "⏱️  Attente 60 secondes pour la stabilisation des pods..."
sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. VÉRIFICATION ÉTAT FINAL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ns in n8n litellm qdrant superset chatwoot; do
    echo "📊 État namespace '$ns' :"
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n $ns -o wide 2>/dev/null" || echo -e "$WARN Namespace '$ns' vide ou inexistant"
    echo ""
done

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ RÉINITIALISATION TERMINÉE"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "📁 Fichiers générés :"
echo "   • Log complet       : $LOG_FILE"
echo "   • Credentials       : $CREDS_FILE"
echo ""
echo "🔐 Accès applications :"
echo "   • n8n       : https://n8n.keybuzz.io"
echo "   • LiteLLM   : https://llm.keybuzz.io"
echo "   • Qdrant    : https://qdrant.keybuzz.io"
echo "   • Superset  : https://superset.keybuzz.io"
echo "   • Chatwoot  : https://chatwoot.keybuzz.io"
echo ""
echo "⚡ Prochaines étapes :"
echo "   1. Attendre que tous les pods soient 'Running' (kubectl get pods -A)"
echo "   2. Tester la création de compte sur n8n"
echo "   3. Vérifier les logs si problème persiste (kubectl logs -n n8n <pod>)"
echo ""
echo "════════════════════════════════════════════════════════════════════"
