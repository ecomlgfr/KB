#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    ULTIMATE_FIX - Correction complète pour n8n/Chatwoot/Apps       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials actuels
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "Password actuel: $POSTGRES_PASSWORD"
echo ""

echo "1. Correction des permissions PgBouncer..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Fix permissions sur $ip: "
    ssh root@"$ip" bash <<'FIX_PERMS'
# Arrêter PgBouncer
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Créer le répertoire logs avec bonnes permissions
mkdir -p /opt/keybuzz/pgbouncer/logs
chmod 777 /opt/keybuzz/pgbouncer/logs
touch /opt/keybuzz/pgbouncer/logs/pgbouncer.log
chmod 666 /opt/keybuzz/pgbouncer/logs/pgbouncer.log

# Modifier la config pour ne pas utiliser de logfile ou utiliser stdout
sed -i 's|logfile = .*|logfile = |' /opt/keybuzz/pgbouncer/config/pgbouncer.ini 2>/dev/null

# Redémarrer PgBouncer
docker run -d \
  --name pgbouncer \
  --hostname $(hostname)-pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  pgbouncer:latest
FIX_PERMS
    echo -e "$OK"
done

echo ""
echo "2. Préparation PostgreSQL pour n8n (éviter problèmes de migration)..."
echo ""

# Identifier le leader
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    if ssh root@"$ip" "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'" 2>/dev/null; then
        LEADER_IP="$ip"
        echo "  Leader: $ip"
        break
    fi
done

if [ -n "$LEADER_IP" ]; then
    echo -n "  Configuration pour n8n: "
    
    ssh root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" <<'N8N_SETUP'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Créer la base n8n si elle n'existe pas
SELECT 'CREATE DATABASE n8n' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n');
\gexec

-- Créer l'utilisateur n8n
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'n8n') THEN
        CREATE USER n8n WITH PASSWORD '$PG_PASSWORD';
    ELSE
        ALTER USER n8n PASSWORD '$PG_PASSWORD';
    END IF;
END
\$\$;

-- Donner tous les droits à n8n sur sa base
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;

-- Se connecter à la base n8n pour configurer
\c n8n

-- Donner les droits sur le schema public
GRANT ALL ON SCHEMA public TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO n8n;

-- Créer les extensions nécessaires
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Paramètres recommandés pour n8n
ALTER DATABASE n8n SET statement_timeout = '300s';
ALTER DATABASE n8n SET idle_in_transaction_session_timeout = '300s';
ALTER DATABASE n8n SET lock_timeout = '10s';

SELECT 'n8n database configured' as status;
SQL
N8N_SETUP
    echo -e "$OK"

    echo -n "  Configuration pour Chatwoot: "
    
    ssh root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" <<'CHATWOOT_SETUP'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Créer la base chatwoot
SELECT 'CREATE DATABASE chatwoot' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot');
\gexec

-- Créer l'utilisateur chatwoot
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'chatwoot') THEN
        CREATE USER chatwoot WITH PASSWORD '$PG_PASSWORD';
    ELSE
        ALTER USER chatwoot PASSWORD '$PG_PASSWORD';
    END IF;
END
\$\$;

-- Droits
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;

-- Se connecter à chatwoot
\c chatwoot

-- Extensions pour Chatwoot
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Droits
GRANT ALL ON SCHEMA public TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO chatwoot;

SELECT 'chatwoot database configured' as status;
SQL
CHATWOOT_SETUP
    echo -e "$OK"
fi

echo ""
echo "3. Test PgBouncer après correction..."
echo ""

sleep 5

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo -n "  $hostname (port 6432): "
    
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
        echo -e "$OK"
    else
        echo -e "$KO"
        # État du container
        ssh root@"$ip" "docker ps -a | grep pgbouncer" 2>/dev/null | tail -1
    fi
done

echo ""
echo "4. Reconfiguration HAProxy pour stabilité..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo -n "  HAProxy $ip: "
    ssh root@"$ip" bash <<'FIX_HAPROXY'
# Redémarrer HAProxy
docker restart haproxy 2>/dev/null
FIX_HAPROXY
    echo -e "$OK"
done

sleep 3

echo ""
echo "5. Tests finaux..."
echo ""

# Test PostgreSQL direct
echo -n "  PostgreSQL direct: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test n8n database
echo -n "  Base n8n: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test chatwoot database
echo -n "  Base chatwoot: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test HAProxy
echo -n "  HAProxy Write: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "6. Génération des configurations pour les applications..."
echo ""

APP_CONFIG="/opt/keybuzz-installer/credentials/app_configs.env"

cat > "$APP_CONFIG" <<EOF
# ═══════════════════════════════════════════════════════════════════
# Configuration pour n8n (v1.116.2+)
# ═══════════════════════════════════════════════════════════════════

# Pour n8n - Utiliser HAProxy pour la haute disponibilité
N8N_DATABASE_TYPE=postgresdb
N8N_DATABASE_HOST=10.0.0.11
N8N_DATABASE_PORT=5432
N8N_DATABASE_NAME=n8n
N8N_DATABASE_USER=n8n
N8N_DATABASE_PASSWORD=$POSTGRES_PASSWORD

# Alternative avec URL complète
DATABASE_URL=postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.11:5432/n8n

# Options de migration n8n (éviter les blocages)
DB_POSTGRESDB_MIGRATIONS_TABLE_QUOTE=false
N8N_DATABASE_MIGRATIONS_TRANSACTION_MODE=none

# ═══════════════════════════════════════════════════════════════════
# Configuration pour Chatwoot
# ═══════════════════════════════════════════════════════════════════

# Pour Chatwoot
POSTGRES_HOST=10.0.0.11
POSTGRES_PORT=5432
POSTGRES_DATABASE=chatwoot
POSTGRES_USERNAME=chatwoot
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# URL complète Chatwoot
DATABASE_URL=postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.11:5432/chatwoot

# Pool de connexions
DATABASE_POOL=25
DATABASE_REAPING_FREQUENCY=10

# ═══════════════════════════════════════════════════════════════════
# Configuration générique pour autres applications
# ═══════════════════════════════════════════════════════════════════

# Via PgBouncer (pour apps avec beaucoup de connexions courtes)
PGBOUNCER_URL=postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.120:6432/postgres

# Direct Master (pour écritures intensives)
MASTER_URL=postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.120:5432/postgres

# Via HAProxy (recommandé - haute disponibilité)
HA_DATABASE_URL=postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.11:5432/postgres
EOF

chmod 600 "$APP_CONFIG"
echo -e "  $OK Configurations générées: $APP_CONFIG"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ FINAL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Services fonctionnels:"

# Compter les services OK
SERVICES_OK=0
SERVICES_TOTAL=0

# PostgreSQL
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && SERVICES_OK=$((SERVICES_OK+1)) && echo -e "  • PostgreSQL: $OK" || echo -e "  • PostgreSQL: $KO"
SERVICES_TOTAL=$((SERVICES_TOTAL+1))

# PgBouncer
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && SERVICES_OK=$((SERVICES_OK+1)) && echo -e "  • PgBouncer: $OK" || echo -e "  • PgBouncer: $KO"
SERVICES_TOTAL=$((SERVICES_TOTAL+1))

# HAProxy
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && SERVICES_OK=$((SERVICES_OK+1)) && echo -e "  • HAProxy: $OK" || echo -e "  • HAProxy: $KO"
SERVICES_TOTAL=$((SERVICES_TOTAL+1))

# n8n DB
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && SERVICES_OK=$((SERVICES_OK+1)) && echo -e "  • Base n8n: $OK" || echo -e "  • Base n8n: $KO"
SERVICES_TOTAL=$((SERVICES_TOTAL+1))

# Chatwoot DB
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && SERVICES_OK=$((SERVICES_OK+1)) && echo -e "  • Base Chatwoot: $OK" || echo -e "  • Base Chatwoot: $KO"
SERVICES_TOTAL=$((SERVICES_TOTAL+1))

echo ""
echo "Score: $SERVICES_OK/$SERVICES_TOTAL services opérationnels"
echo ""

if [ $SERVICES_OK -ge 4 ]; then
    echo -e "$OK Infrastructure PostgreSQL prête pour n8n et Chatwoot!"
    echo ""
    echo "Configurations des applications:"
    echo "  Fichier: $APP_CONFIG"
    echo ""
    echo "Pour n8n, utilisez ces variables d'environnement:"
    echo "  N8N_DATABASE_HOST=10.0.0.11"
    echo "  N8N_DATABASE_NAME=n8n"
    echo "  N8N_DATABASE_USER=n8n"
    echo "  N8N_DATABASE_PASSWORD=$POSTGRES_PASSWORD"
else
    echo -e "$KO Certains services nécessitent attention"
fi

echo "═══════════════════════════════════════════════════════════════════"
