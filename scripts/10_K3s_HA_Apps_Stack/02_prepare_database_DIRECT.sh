#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   Préparation PostgreSQL pour Apps K3S                            ║"
echo "║   (PostgreSQL DIRECT pour CREATE DATABASE)                         ║"
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

# Points d'entrée
PG_DIRECT_HOST="10.0.0.10"
PG_DIRECT_PORT="5432"    # Port PostgreSQL DIRECT (HAProxy → Patroni leader)
PGBOUNCER_PORT="6432"     # Port PgBouncer (pour applications)

echo "  ✓ Point d'entrée ADMIN : $PG_DIRECT_HOST:$PG_DIRECT_PORT (PostgreSQL direct)"
echo "  ✓ Point d'entrée APPS  : $PG_DIRECT_HOST:$PGBOUNCER_PORT (PgBouncer)"
echo ""

# Vérifier la connexion PostgreSQL direct
export PGPASSWORD="$POSTGRES_PASSWORD"

echo "Test connexion PostgreSQL direct..."
if ! psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "$KO Impossible de se connecter via PostgreSQL direct"
    echo ""
    echo "Vérifications :"
    echo "  1. HAProxy actif ? curl http://10.0.0.11:8404/"
    echo "  2. LB Hetzner OK ? timeout 3 bash -c '</dev/tcp/10.0.0.10/5432'"
    echo "  3. Mot de passe correct ?"
    exit 1
fi

echo -e "  $OK Connexion PostgreSQL direct réussie"
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
echo "⚠️  IMPORTANT : CREATE DATABASE via port 5432 (direct)"
echo "   Les applications utiliseront le port 6432 (PgBouncer) après création"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Création bases + extensions + users via PostgreSQL DIRECT ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Script SQL utilisant connexion directe
echo "[$(date '+%F %T')] Connexion à PostgreSQL direct ($PG_DIRECT_HOST:$PG_DIRECT_PORT)..."
echo ""

# Créer les extensions globales d'abord
echo "→ Installation extensions globales..."
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres <<'EXTENSIONS'
-- Extensions dans postgres (disponibles pour toutes les DBs)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
EXTENSIONS

echo ""

# Créer la base n8n
echo "→ Création base de données n8n..."
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres <<'N8N'
-- Base n8n (user postgres)
SELECT 'CREATE DATABASE n8n WITH OWNER = postgres ENCODING = ''UTF8'' LC_COLLATE = ''en_US.UTF-8'' LC_CTYPE = ''en_US.UTF-8'' TEMPLATE = template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec
N8N

# Installer extensions dans n8n
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d n8n <<'N8NEXT'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
N8NEXT

echo "  ✓ n8n créée"
echo ""

# Créer user et base chatwoot
echo "→ Création user et base chatwoot..."
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres <<CHATWOOT
-- User chatwoot
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'chatwoot') THEN
        CREATE USER chatwoot WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN;
    ELSE
        ALTER USER chatwoot WITH PASSWORD '${POSTGRES_PASSWORD}';
    END IF;
END
\$\$;

-- Base chatwoot
SELECT 'CREATE DATABASE chatwoot WITH OWNER = chatwoot ENCODING = ''UTF8'' LC_COLLATE = ''en_US.UTF-8'' LC_CTYPE = ''en_US.UTF-8'' TEMPLATE = template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot')\gexec

-- Mettre à jour l'owner si la base existe déjà
ALTER DATABASE chatwoot OWNER TO chatwoot;
CHATWOOT

# Extensions chatwoot
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d chatwoot <<'CHATEXEXT'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

-- Permissions chatwoot
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
GRANT ALL ON SCHEMA public TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO chatwoot;
CHATEXEXT

echo "  ✓ chatwoot créée (avec pgvector)"
echo ""

# Créer user et base litellm
echo "→ Création user et base litellm..."
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres <<LITELLM
-- User litellm
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'litellm') THEN
        CREATE USER litellm WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN;
    ELSE
        ALTER USER litellm WITH PASSWORD '${POSTGRES_PASSWORD}';
    END IF;
END
\$\$;

-- Base litellm
SELECT 'CREATE DATABASE litellm WITH OWNER = litellm ENCODING = ''UTF8'' LC_COLLATE = ''en_US.UTF-8'' LC_CTYPE = ''en_US.UTF-8'' TEMPLATE = template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'litellm')\gexec

ALTER DATABASE litellm OWNER TO litellm;
LITELLM

# Permissions litellm
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d litellm <<'LITELLMEXT'
GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;
GRANT ALL ON SCHEMA public TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO litellm;
LITELLMEXT

echo "  ✓ litellm créée"
echo ""

# Créer user et base superset
echo "→ Création user et base superset..."
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres <<SUPERSET
-- User superset (avec CREATEDB)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'superset') THEN
        CREATE USER superset WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN CREATEDB;
    ELSE
        ALTER USER superset WITH PASSWORD '${POSTGRES_PASSWORD}' CREATEDB;
    END IF;
END
\$\$;

-- Base superset
SELECT 'CREATE DATABASE superset WITH OWNER = superset ENCODING = ''UTF8'' LC_COLLATE = ''en_US.UTF-8'' LC_CTYPE = ''en_US.UTF-8'' TEMPLATE = template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'superset')\gexec

ALTER DATABASE superset OWNER TO superset;
SUPERSET

# Permissions superset
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d superset <<'SUPERSETEXT'
GRANT ALL PRIVILEGES ON DATABASE superset TO superset;
GRANT ALL ON SCHEMA public TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO superset;
SUPERSETEXT

echo "  ✓ superset créée (avec CREATEDB)"
echo ""

# Vérification finale
echo "→ Vérification finale..."
echo ""

psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres <<'VERIFY'
-- Lister les bases
SELECT 
    datname AS "Base de données", 
    pg_size_pretty(pg_database_size(datname)) AS "Taille",
    datcollate AS "Collation"
FROM pg_database 
WHERE datname IN ('n8n', 'chatwoot', 'litellm', 'superset')
ORDER BY datname;
VERIFY

echo ""

psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d postgres <<'VERIFYUSERS'
-- Lister les users
SELECT 
    usename AS "User",
    CASE WHEN usesuper THEN 'oui' ELSE 'non' END AS "Superuser",
    CASE WHEN usecreatedb THEN 'oui' ELSE 'non' END AS "CreateDB"
FROM pg_user 
WHERE usename IN ('postgres', 'chatwoot', 'litellm', 'superset')
ORDER BY usename;
VERIFYUSERS

echo ""

# Vérifier pgvector dans chatwoot
echo "→ Extensions dans chatwoot :"
psql -U postgres -h $PG_DIRECT_HOST -p $PG_DIRECT_PORT -d chatwoot -c "\dx" | grep -E '(Name|vector|pg_stat|pgcrypto|pg_trgm)' || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Bases de données créées avec succès"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 RÉSUMÉ DES CONFIGURATIONS :"
echo ""
echo "  n8n :"
echo "    Database  : n8n"
echo "    User      : postgres (superuser - requis par n8n)"
echo "    String    : postgresql://postgres:${POSTGRES_PASSWORD}@10.0.0.10:6432/n8n"
echo ""
echo "  Chatwoot :"
echo "    Database  : chatwoot"
echo "    User      : chatwoot"
echo "    Extensions: pgvector (AI), pg_trgm (search)"
echo "    String    : postgresql://chatwoot:${POSTGRES_PASSWORD}@10.0.0.10:6432/chatwoot"
echo ""
echo "  LiteLLM :"
echo "    Database  : litellm"
echo "    User      : litellm"
echo "    String    : postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:6432/litellm"
echo ""
echo "  Superset :"
echo "    Database  : superset"
echo "    User      : superset (avec CREATEDB)"
echo "    String    : postgresql://superset:${POSTGRES_PASSWORD}@10.0.0.10:6432/superset"
echo ""
echo "  Qdrant :"
echo "    ℹ️ N'utilise pas PostgreSQL (moteur vectoriel natif)"
echo ""
echo "⚠️ IMPORTANT : Les applications utilisent le port 6432 (PgBouncer)"
echo ""
echo "Prochaine étape :"
echo "  kubectl rollout restart daemonset/n8n -n n8n"
echo "  kubectl rollout restart daemonset/litellm -n litellm"
echo "  kubectl rollout restart daemonset/chatwoot-web -n chatwoot"
echo "  kubectl rollout restart daemonset/chatwoot-worker -n chatwoot"
echo "  kubectl rollout restart daemonset/superset -n superset"
echo ""

exit 0
