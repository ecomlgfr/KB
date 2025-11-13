#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   Préparation PostgreSQL pour Apps K3S                            ║"
echo "║   (Bases + Users + Extensions via PgBouncer)                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

# Fonction pour parser les .env
get_env_value() {
    local file="$1"
    local key="$2"
    
    if [ -f "$file" ]; then
        local value=$(grep -E "^${key}=" "$file" | cut -d'=' -f2- | sed 's/^["\x27]//;s/["\x27]$//' | head -n1)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    echo ""
    return 1
}

echo ""
echo "═══ Chargement des credentials ═══"
echo ""

if [ ! -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "$KO $CREDENTIALS_DIR/postgres.env introuvable"
    exit 1
fi

POSTGRES_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_PASSWORD")

if [ -z "$POSTGRES_PASSWORD" ]; then
    echo -e "$WARN Impossible de parser POSTGRES_PASSWORD depuis postgres.env"
    source "$CREDENTIALS_DIR/postgres.env" 2>/dev/null || true
    
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        echo -e "$KO Mot de passe PostgreSQL introuvable"
        read -sp "PostgreSQL password: " POSTGRES_PASSWORD
        echo ""
        
        if [ -z "$POSTGRES_PASSWORD" ]; then
            echo -e "$KO Mot de passe vide, abandon"
            exit 1
        fi
    fi
fi

echo "  ✓ Mot de passe PostgreSQL : ${POSTGRES_PASSWORD:0:10}***"

# Point d'entrée : PgBouncer via LB Hetzner (validé 19/19 tests)
PGBOUNCER_HOST="10.0.0.10"
PGBOUNCER_PORT="6432"

echo "  ✓ Point d'entrée : $PGBOUNCER_HOST:$PGBOUNCER_PORT (PgBouncer)"
echo ""

# Vérifier la connexion PgBouncer
export PGPASSWORD="$POSTGRES_PASSWORD"

echo "Test connexion PgBouncer..."
if ! psql -U postgres -h $PGBOUNCER_HOST -p $PGBOUNCER_PORT -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "$KO Impossible de se connecter via PgBouncer"
    echo ""
    echo "Vérifications :"
    echo "  1. PgBouncer actif ? curl http://10.0.0.11:8404/"
    echo "  2. LB Hetzner OK ? timeout 3 bash -c '</dev/tcp/10.0.0.10/6432'"
    echo "  3. Mot de passe correct ?"
    exit 1
fi

echo -e "  $OK Connexion PgBouncer réussie"
echo ""

echo "📋 Bases de données à créer avec spécificités :"
echo ""
echo "  1. n8n         → User 'postgres' (n8n utilise le superuser par défaut)"
echo "  2. chatwoot    → User dédié + pgvector pour AI"
echo "  3. litellm     → User dédié + privilèges standard"
echo "  4. superset    → User dédié + privilèges CREATEDB (pour metadata)"
echo "  5. qdrant      → Pas de DB PostgreSQL (utilise son propre moteur)"
echo ""
echo "🔧 Extensions PostgreSQL (installées globalement) :"
echo "  - pgvector (vector)       → Recherche sémantique AI"
echo "  - pg_stat_statements      → Monitoring performances"
echo "  - pgcrypto                → Chiffrement"
echo "  - pg_trgm                 → Recherche texte full-text"
echo "  - pgaudit                 → Audit (si disponible)"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Création bases + extensions + users via PgBouncer ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Script SQL optimisé
SQL_SCRIPT='
-- ═══════════════════════════════════════════════════════════════════════════
-- 1. EXTENSIONS GLOBALES (à installer en tant que superuser)
-- ═══════════════════════════════════════════════════════════════════════════

-- Extensions dans postgres (disponibles pour toutes les DBs)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- pgvector (peut échouer si pas installé)
DO $vector$
BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
    RAISE NOTICE '\''Extension vector (pgvector) installée'\'';
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '\''Extension vector non disponible (normal si pgvector pas installé)'\'';
END;
$vector$;

-- pgaudit (optionnel)
DO $audit$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pgaudit;
    RAISE NOTICE '\''Extension pgaudit installée'\'';
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '\''Extension pgaudit non disponible (optionnel)'\'';
END;
$audit$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. N8N - Utilise le user '\''postgres'\'' (best practice n8n)
-- ═══════════════════════════════════════════════════════════════════════════

DO $n8n$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '\''n8n'\'') THEN
        CREATE DATABASE n8n WITH 
            OWNER = postgres
            ENCODING = '\''UTF8'\''
            LC_COLLATE = '\''en_US.UTF-8'\''
            LC_CTYPE = '\''en_US.UTF-8'\''
            TEMPLATE = template0;
        RAISE NOTICE '\''Database n8n created (owner: postgres)'\'';
    END IF;
END
$n8n$;

-- Extensions n8n
\c n8n
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. CHATWOOT - User dédié + pgvector pour AI
-- ═══════════════════════════════════════════════════════════════════════════

\c postgres

DO $chatwoot_user$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '\''chatwoot'\'') THEN
        CREATE USER chatwoot WITH PASSWORD '\'''"$POSTGRES_PASSWORD"'\'' LOGIN;
        RAISE NOTICE '\''User chatwoot created'\'';
    ELSE
        ALTER USER chatwoot WITH PASSWORD '\'''"$POSTGRES_PASSWORD"'\'';
        RAISE NOTICE '\''User chatwoot password updated'\'';
    END IF;
END
$chatwoot_user$;

DO $chatwoot_db$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '\''chatwoot'\'') THEN
        CREATE DATABASE chatwoot WITH 
            OWNER = chatwoot
            ENCODING = '\''UTF8'\''
            LC_COLLATE = '\''en_US.UTF-8'\''
            LC_CTYPE = '\''en_US.UTF-8'\''
            TEMPLATE = template0;
        RAISE NOTICE '\''Database chatwoot created'\'';
    ELSE
        ALTER DATABASE chatwoot OWNER TO chatwoot;
    END IF;
END
$chatwoot_db$;

-- Extensions chatwoot (en tant que superuser)
\c chatwoot
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- pgvector pour AI (peut échouer si pas installé)
DO $chatwoot_vector$
BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
    RAISE NOTICE '\''pgvector installé pour Chatwoot AI'\'';
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '\''pgvector non disponible - fonctionnalités AI limitées'\'';
END;
$chatwoot_vector$;

-- Permissions chatwoot
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
GRANT ALL ON SCHEMA public TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO chatwoot;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. LITELLM - User dédié
-- ═══════════════════════════════════════════════════════════════════════════

\c postgres

DO $litellm_user$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '\''litellm'\'') THEN
        CREATE USER litellm WITH PASSWORD '\'''"$POSTGRES_PASSWORD"'\'' LOGIN;
        RAISE NOTICE '\''User litellm created'\'';
    ELSE
        ALTER USER litellm WITH PASSWORD '\'''"$POSTGRES_PASSWORD"'\'';
    END IF;
END
$litellm_user$;

DO $litellm_db$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '\''litellm'\'') THEN
        CREATE DATABASE litellm WITH 
            OWNER = litellm
            ENCODING = '\''UTF8'\''
            LC_COLLATE = '\''en_US.UTF-8'\''
            LC_CTYPE = '\''en_US.UTF-8'\''
            TEMPLATE = template0;
        RAISE NOTICE '\''Database litellm created'\'';
    ELSE
        ALTER DATABASE litellm OWNER TO litellm;
    END IF;
END
$litellm_db$;

\c litellm
GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;
GRANT ALL ON SCHEMA public TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO litellm;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. SUPERSET - User dédié + CREATEDB (pour metadata)
-- ═══════════════════════════════════════════════════════════════════════════

\c postgres

DO $superset_user$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '\''superset'\'') THEN
        CREATE USER superset WITH PASSWORD '\'''"$POSTGRES_PASSWORD"'\'' LOGIN CREATEDB;
        RAISE NOTICE '\''User superset created with CREATEDB'\'';
    ELSE
        ALTER USER superset WITH PASSWORD '\'''"$POSTGRES_PASSWORD"'\'' CREATEDB;
    END IF;
END
$superset_user$;

DO $superset_db$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '\''superset'\'') THEN
        CREATE DATABASE superset WITH 
            OWNER = superset
            ENCODING = '\''UTF8'\''
            LC_COLLATE = '\''en_US.UTF-8'\''
            LC_CTYPE = '\''en_US.UTF-8'\''
            TEMPLATE = template0;
        RAISE NOTICE '\''Database superset created'\'';
    ELSE
        ALTER DATABASE superset OWNER TO superset;
    END IF;
END
$superset_db$;

\c superset
GRANT ALL PRIVILEGES ON DATABASE superset TO superset;
GRANT ALL ON SCHEMA public TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO superset;

-- ═══════════════════════════════════════════════════════════════════════════
-- VÉRIFICATION FINALE
-- ═══════════════════════════════════════════════════════════════════════════

\c postgres

SELECT 
    '\''✅ Bases de données créées avec succès'\'' AS status,
    (SELECT count(*) FROM pg_database WHERE datname IN ('\''n8n'\'', '\''chatwoot'\'', '\''litellm'\'', '\''superset'\'')) AS databases_created,
    (SELECT count(*) FROM pg_user WHERE usename IN ('\''chatwoot'\'', '\''litellm'\'', '\''superset'\'')) AS users_created;

-- Lister les bases
\echo '\'''\''
\echo '\''Bases de données disponibles :'\''
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size, datcollate
FROM pg_database 
WHERE datname IN ('\''n8n'\'', '\''chatwoot'\'', '\''litellm'\'', '\''superset'\'')
ORDER BY datname;

-- Lister les extensions dans chatwoot
\echo '\'''\''
\echo '\''Extensions dans chatwoot :'\''
\c chatwoot
\dx
'

# Exécuter le SQL via PgBouncer
echo "[$(date '+%F %T')] Exécution du script SQL via PgBouncer..."
echo ""

psql -U postgres -h $PGBOUNCER_HOST -p $PGBOUNCER_PORT -d postgres -v ON_ERROR_STOP=0 <<< "$SQL_SCRIPT"

RESULT=$?

echo ""
if [ $RESULT -eq 0 ]; then
    echo "[$(date '+%F %T')] ✅ Bases de données préparées avec succès"
else
    echo "[$(date '+%F %T')] ⚠️ Script terminé avec des warnings (normal si certaines extensions manquent)"
fi

if [ $RESULT -eq 0 ] || [ $RESULT -eq 2 ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$OK Bases de données préparées"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "📊 RÉSUMÉ DES CONFIGURATIONS :"
    echo ""
    echo "  n8n :"
    echo "    Database  : n8n"
    echo "    User      : postgres (superuser - requis par n8n)"
    echo "    String    : postgresql://postgres:PASSWORD@10.0.0.10:6432/n8n"
    echo ""
    echo "  Chatwoot :"
    echo "    Database  : chatwoot"
    echo "    User      : chatwoot"
    echo "    Extensions: pgvector (AI), pg_trgm (search)"
    echo "    String    : postgresql://chatwoot:PASSWORD@10.0.0.10:6432/chatwoot"
    echo ""
    echo "  LiteLLM :"
    echo "    Database  : litellm"
    echo "    User      : litellm"
    echo "    String    : postgresql://litellm:PASSWORD@10.0.0.10:6432/litellm"
    echo ""
    echo "  Superset :"
    echo "    Database  : superset"
    echo "    User      : superset (avec CREATEDB)"
    echo "    String    : postgresql://superset:PASSWORD@10.0.0.10:6432/superset"
    echo ""
    echo "  Qdrant :"
    echo "    ℹ️ N'utilise pas PostgreSQL (moteur vectoriel natif)"
    echo ""
    echo "⚠️ IMPORTANT : Remplacez PASSWORD par le mot de passe réel"
    echo ""
    echo "Prochaine étape :"
    echo "  ./09_deploy_ingress_daemonset.sh"
    echo ""
    exit 0
else
    echo ""
    echo -e "$KO Erreur lors de la préparation"
    echo ""
    echo "Vérification manuelle :"
    echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -U postgres -h $PGBOUNCER_HOST -p $PGBOUNCER_PORT -d postgres"
    echo "  \l"
    echo ""
    exit 1
fi
