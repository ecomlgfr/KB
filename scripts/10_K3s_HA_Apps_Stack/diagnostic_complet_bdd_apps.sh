#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC COMPLET - BDD & APPS (n8n, LiteLLM, Qdrant, etc.)  ║"
echo "║    Détection problème création de compte (boucle infinie)         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✅ OK\033[0m'
KO='\033[0;31m❌ KO\033[0m'
WARN='\033[0;33m⚠️ WARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
POSTGRES_ENV="$CREDENTIALS_DIR/postgres.env"
REDIS_ENV="$CREDENTIALS_DIR/redis.env"
LOG_FILE="/opt/keybuzz-installer/logs/diagnostic_bdd_apps_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1

# Vérifier servers.tsv
if [ ! -f "$SERVERS_TSV" ]; then
    echo -e "$KO servers.tsv introuvable : $SERVERS_TSV"
    exit 1
fi

# Vérifier postgres.env
if [ ! -f "$POSTGRES_ENV" ]; then
    echo -e "$KO Fichier postgres.env introuvable : $POSTGRES_ENV"
    echo ""
    echo "💡 Solution : Exécutez d'abord ./fix_credentials_files.sh"
    exit 1
fi

source "$POSTGRES_ENV"

# Vérifier que les variables sont définies
if [ -z "${POSTGRES_USER:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "$KO Variables PostgreSQL manquantes dans postgres.env"
    echo "   POSTGRES_USER: ${POSTGRES_USER:-NON_DÉFINI}"
    echo "   POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:+DÉFINI}"
    echo ""
    echo "💡 Solution : Exécutez ./fix_credentials_files.sh"
    exit 1
fi

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
IP_DB_LB="10.0.0.10"
IP_HAPROXY01=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")

if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP k3s-master-01 introuvable dans servers.tsv"
    exit 1
fi

echo ""
echo "🎯 Cibles de diagnostic :"
echo "   • K3s Master : $IP_MASTER01"
echo "   • DB LB      : $IP_DB_LB"
echo "   • HAProxy    : $IP_HAPROXY01"
echo "   • PG User    : $POSTGRES_USER"
echo ""

# Charger Redis credentials si disponibles
if [ -f "$REDIS_ENV" ]; then
    source "$REDIS_ENV"
    echo "   • Redis password chargé"
else
    echo -e "$WARN redis.env non trouvé (non bloquant)"
fi

# Fonction pour tester une connexion PostgreSQL
test_pg_connection() {
    local host=$1
    local port=$2
    local database=$3
    local user=$4
    local password=$5
    local label=$6
    
    echo "Testing $label ($host:$port/$database)..."
    
    if PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$user" -d "$database" -c "SELECT 1;" &>/dev/null; then
        echo -e "$OK Connexion $label réussie"
        return 0
    else
        echo -e "$KO Connexion $label ÉCHOUÉE"
        return 1
    fi
}

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. VÉRIFICATION DES CREDENTIALS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo -e "$OK Credentials PostgreSQL chargés"
echo "   • POSTGRES_USER: ${POSTGRES_USER}"
echo "   • POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:0:4}***"
echo "   • POSTGRES_HOST: ${POSTGRES_HOST:-10.0.0.10}"
echo "   • POSTGRES_PORT: ${POSTGRES_PORT:-5432}"

if [ -n "${REDIS_PASSWORD:-}" ]; then
    echo -e "$OK Credentials Redis chargés"
    echo "   • REDIS_PASSWORD: ${REDIS_PASSWORD:0:4}***"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. TEST CONNEXION POSTGRESQL DEPUIS INSTALL-01 ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tester la connexion PostgreSQL depuis install-01
if ! command -v psql &>/dev/null; then
    echo -e "$WARN psql non installé sur install-01, installation..."
    apt-get update -qq && apt-get install -y -qq postgresql-client
fi

echo "🔍 Test connexion PostgreSQL via LB (10.0.0.10:5432)..."
test_pg_connection "$IP_DB_LB" "5432" "postgres" "${POSTGRES_USER}" "${POSTGRES_PASSWORD}" "LB:5432"

if [ $? -ne 0 ]; then
    echo ""
    echo -e "$KO PostgreSQL inaccessible - Vérifications nécessaires :"
    echo "   1. PostgreSQL est-il démarré sur db-master-01 ?"
    echo "   2. HAProxy fonctionne-t-il (10.0.0.11/12) ?"
    echo "   3. Le Load Balancer Hetzner route-t-il le port 5432 ?"
    echo "   4. Les credentials sont-ils corrects dans Patroni ?"
    echo ""
    echo "   Commandes de vérification :"
    echo "   ssh root@10.0.0.11 'systemctl status haproxy'"
    echo "   ssh root@10.0.0.120 'systemctl status patroni'"
    echo "   ssh root@10.0.0.120 'patronictl -c /etc/patroni/patroni.yml list'"
    echo ""
    
    read -p "Continuer le diagnostic malgré l'échec de connexion ? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. VÉRIFICATION DES BASES DE DONNÉES EXISTANTES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Listage des bases de données..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -c "\l" 2>/dev/null || {
    echo -e "$KO Impossible de lister les bases de données"
}

echo ""
echo "🔍 Vérification des bases de données applicatives..."
for db in n8n litellm qdrant_db superset chatwoot; do
    if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null | grep -q 1; then
        echo -e "$OK Base '$db' existe"
        
        # Compter les tables
        table_count=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d "$db" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null)
        if [ "$table_count" -gt 0 ]; then
            echo "   └─ Tables : $table_count"
        else
            echo -e "   └─ $WARN 0 tables (migrations en attente)"
        fi
    else
        echo -e "$KO Base '$db' n'existe PAS"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. ÉTAT DES PODS K3S ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ns in n8n litellm qdrant superset chatwoot; do
    echo "🔍 Namespace '$ns':"
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n $ns -o wide 2>/dev/null" || echo -e "$WARN Namespace '$ns' vide ou inexistant"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. VÉRIFICATION DES SECRETS KUBERNETES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ns in n8n litellm qdrant superset chatwoot; do
    echo "🔍 Secrets dans namespace '$ns'..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get secrets -n $ns 2>/dev/null" || echo -e "$WARN Namespace '$ns' non trouvé"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. TEST CONNEXION BDD DEPUIS UN POD N8N ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Sélection d'un pod n8n pour test..."
N8N_POD=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n n8n --no-headers -o custom-columns=:metadata.name | head -1" 2>/dev/null)

if [ -n "$N8N_POD" ]; then
    echo "   Pod sélectionné : $N8N_POD"
    echo ""
    echo "🔍 Variables d'environnement DB dans le pod..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- env | grep -E 'DB_|DATABASE_|POSTGRES' | sort" 2>/dev/null || {
        echo -e "$KO Impossible de récupérer les variables d'environnement"
    }
    
    echo ""
    echo "🔍 Test connexion réseau vers PostgreSQL depuis le pod..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- timeout 5 sh -c 'cat < /dev/null > /dev/tcp/10.0.0.10/5432' 2>&1" && {
        echo -e "$OK Connexion réseau TCP vers 10.0.0.10:5432 OK"
    } || {
        echo -e "$KO Connexion réseau TCP vers 10.0.0.10:5432 ÉCHOUÉE"
        echo "   → Vérifier UFW sur les workers K3s"
    }
else
    echo -e "$KO Aucun pod n8n trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. LOGS DES PODS (20 dernières lignes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -n "$N8N_POD" ]; then
    echo "🔍 Logs du pod $N8N_POD..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n n8n $N8N_POD --tail=20" 2>/dev/null || {
        echo -e "$KO Impossible de récupérer les logs"
    }
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. VÉRIFICATION STRUCTURE TABLES N8N ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Tables dans la base n8n..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -c "\dt" 2>/dev/null || {
    echo -e "$WARN Base n8n non accessible (peut-être n'existe pas encore)"
}

echo ""
echo "🔍 Table 'user' dans n8n..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT COUNT(*) FROM \"user\";" 2>/dev/null && {
    echo -e "$OK Table 'user' accessible"
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT id, email, \"firstName\", \"lastName\", \"createdAt\" FROM \"user\" LIMIT 5;" 2>/dev/null
} || {
    echo -e "$KO Table 'user' non accessible ou n'existe pas"
}

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. VÉRIFICATION REDIS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if ! command -v redis-cli &>/dev/null; then
    echo -e "$WARN redis-cli non installé, installation..."
    apt-get install -y -qq redis-tools
fi

if [ -n "${REDIS_PASSWORD:-}" ]; then
    echo "🔍 Test connexion Redis via LB (10.0.0.10:6379)..."
    if redis-cli -h "$IP_DB_LB" -p 6379 -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
        echo -e "$OK Redis répond PONG"
    else
        echo -e "$KO Redis ne répond pas"
    fi
else
    echo -e "$WARN Mot de passe Redis non défini, test sans authentification..."
    if redis-cli -h "$IP_DB_LB" -p 6379 ping 2>/dev/null | grep -q PONG; then
        echo -e "$OK Redis répond PONG (sans auth)"
    else
        echo -e "$KO Redis ne répond pas"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10. DIAGNOSTICS SUPPLÉMENTAIRES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Vérification des connexions actives sur PostgreSQL..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -c "
SELECT 
    datname, 
    usename, 
    application_name, 
    client_addr, 
    state, 
    COUNT(*) 
FROM pg_stat_activity 
WHERE datname IN ('n8n', 'litellm', 'qdrant_db', 'superset', 'chatwoot')
GROUP BY datname, usename, application_name, client_addr, state 
ORDER BY datname, COUNT(*) DESC;
" 2>/dev/null || {
    echo -e "$KO Impossible de récupérer les connexions actives"
}

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "═══ RÉSUMÉ & RECOMMANDATIONS ═══"
echo "════════════════════════════════════════════════════════════════════"
echo ""

echo "📊 Log complet sauvegardé : $LOG_FILE"
echo ""
echo "🔍 Points vérifiés :"
echo "   ✓ Credentials chargés"
echo "   ✓ Connexion PostgreSQL depuis install-01"
echo "   ✓ Bases de données existantes"
echo "   ✓ État des pods K3s"
echo "   ✓ Secrets Kubernetes"
echo "   ✓ Connexion depuis les pods"
echo "   ✓ Logs et tables"
echo ""
echo "💡 Actions possibles :"
echo "   • Si credentials incorrects → ./reset_apps_bdd_complet.sh"
echo "   • Si tables manquantes → kubectl rollout restart daemonset/n8n -n n8n"
echo "   • Si connexion bloquée → Vérifier UFW et HAProxy"
echo "   • Si besoin de compte → ./create_n8n_user_manual.sh"
echo ""

echo "════════════════════════════════════════════════════════════════════"
echo "Diagnostic terminé : $(date)"
echo "════════════════════════════════════════════════════════════════════"
