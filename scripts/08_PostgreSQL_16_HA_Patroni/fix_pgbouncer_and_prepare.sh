#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          FIX_PGBOUNCER_AND_PREPARE - Correction PgBouncer          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Correction de PgBouncer sur db-master-01..."
echo ""

# Le problème est que PgBouncer essaie de se connecter à "localhost" dans le container
# Il faut utiliser l'IP du host ou le mode network host

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'FIX_PGBOUNCER'
PG_PASSWORD="$1"

# Arrêter l'ancien
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Version avec network host pour accéder à PostgreSQL local
docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  -e DATABASES_HOST=127.0.0.1 \
  -e DATABASES_PORT=5432 \
  -e DATABASES_USER=postgres \
  -e DATABASES_PASSWORD="$PG_PASSWORD" \
  -e DATABASES_DBNAME=postgres \
  -e POOL_MODE=transaction \
  -e MAX_CLIENT_CONN=200 \
  -e DEFAULT_POOL_SIZE=25 \
  -e AUTH_TYPE=plain \
  -e LISTEN_PORT=6432 \
  edoburu/pgbouncer:latest

echo "PgBouncer redémarré avec network host"
FIX_PGBOUNCER

sleep 5

echo -n "  Test PgBouncer corrigé: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer OK'" -t 2>/dev/null | grep -q "PgBouncer OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
    # Debug si ça ne marche toujours pas
    echo "  Debug:"
    ssh root@10.0.0.120 "docker logs pgbouncer 2>&1 | tail -5"
fi

echo ""
echo "2. Test complet du standalone..."
echo ""

# Tests complets
echo -n "  PostgreSQL direct: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL 17" && echo -e "$OK" || echo -e "$KO"

echo -n "  Base n8n: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT current_database()" -t 2>/dev/null | grep -q "n8n" && echo -e "$OK" || echo -e "$KO"

echo -n "  Base chatwoot: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT current_database()" -t 2>/dev/null | grep -q "chatwoot" && echo -e "$OK" || echo -e "$KO"

echo -n "  Extension pgvector: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q "vector" && echo -e "$OK" || echo -e "$KO"

echo -n "  Extension uuid-ossp: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q "uuid-ossp" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "3. Test de création de tables avec pgvector..."
echo ""

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -d n8n <<SQL 2>/dev/null
-- Test pgvector dans n8n
CREATE TABLE IF NOT EXISTS embeddings_test (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding vector(1536)  -- Dimension pour OpenAI
);

INSERT INTO embeddings_test (content, embedding) 
VALUES ('test', (SELECT array_agg(random())::vector(1536) FROM generate_series(1, 1536)));

SELECT 'pgvector test OK' as result;
SQL

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VALIDATION PHASE 1"
echo "═══════════════════════════════════════════════════════════════════"

# Compter les services OK
SERVICES_OK=0
SERVICES_TOTAL=6

echo ""
echo "Checklist:"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT 1" &>/dev/null && { echo -e "  [✓] PostgreSQL 17 actif"; ((SERVICES_OK++)); } || echo -e "  [✗] PostgreSQL 17"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 1" &>/dev/null && { echo -e "  [✓] PgBouncer actif"; ((SERVICES_OK++)); } || echo -e "  [✗] PgBouncer"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && { echo -e "  [✓] Base n8n accessible"; ((SERVICES_OK++)); } || echo -e "  [✗] Base n8n"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && { echo -e "  [✓] Base chatwoot accessible"; ((SERVICES_OK++)); } || echo -e "  [✗] Base chatwoot"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q "vector" && { echo -e "  [✓] pgvector installé"; ((SERVICES_OK++)); } || echo -e "  [✗] pgvector"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q "uuid-ossp" && { echo -e "  [✓] uuid-ossp installé"; ((SERVICES_OK++)); } || echo -e "  [✗] uuid-ossp"

echo ""
echo "Score: $SERVICES_OK/$SERVICES_TOTAL"
echo ""

if [ $SERVICES_OK -eq $SERVICES_TOTAL ]; then
    echo -e "$OK PHASE 1 VALIDÉE - Prêt pour la phase 2"
    echo ""
    echo "Informations de connexion:"
    echo "  Host: 10.0.0.120"
    echo "  Port PostgreSQL: 5432"
    echo "  Port PgBouncer: 6432"
    echo "  Mot de passe: $POSTGRES_PASSWORD"
    echo ""
    echo "Prochaine étape:"
    echo "  ./phase_2_add_replicas.sh"
else
    echo -e "$KO Certains services doivent être corrigés avant de continuer"
fi

echo "═══════════════════════════════════════════════════════════════════"
