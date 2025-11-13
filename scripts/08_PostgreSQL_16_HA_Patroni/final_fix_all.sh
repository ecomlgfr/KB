#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     FINAL_FIX_ALL - Correction définitive avec mots de passe sûrs  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

echo ""
echo "1. Génération de nouveaux mots de passe SIMPLES et SÛRS..."
echo ""

# Générer des mots de passe uniquement avec lettres et chiffres (pas de caractères spéciaux)
generate_safe_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

NEW_POSTGRES_PASSWORD=$(generate_safe_password)
NEW_REPLICATOR_PASSWORD=$(generate_safe_password)
NEW_PATRONI_API_PASSWORD=$(generate_safe_password)

echo "  Nouveaux mots de passe générés (alphanumériques uniquement):"
echo "    PostgreSQL: $NEW_POSTGRES_PASSWORD"
echo "    Replicator: $NEW_REPLICATOR_PASSWORD"
echo "    Patroni API: $NEW_PATRONI_API_PASSWORD"

# Sauvegarder dans le fichier .env
CREDS_FILE="/opt/keybuzz-installer/credentials/postgres.env"
cat > "$CREDS_FILE" <<EOF
#!/bin/bash
# PostgreSQL Credentials - Generated $(date)
# SAFE PASSWORDS - Only alphanumeric characters

export POSTGRES_PASSWORD="$NEW_POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$NEW_REPLICATOR_PASSWORD"
export PATRONI_API_PASSWORD="$NEW_PATRONI_API_PASSWORD"
export PGBOUNCER_PASSWORD="$NEW_POSTGRES_PASSWORD"

# Connection strings
export MASTER_DSN="postgresql://postgres:$NEW_POSTGRES_PASSWORD@10.0.0.120:5432/postgres"
export REPLICA_DSN="postgresql://postgres:$NEW_POSTGRES_PASSWORD@10.0.0.121:5432/postgres"
export VIP_DSN="postgresql://postgres:$NEW_POSTGRES_PASSWORD@10.0.0.10:5432/postgres"

# For applications
export DATABASE_URL="postgresql://postgres:$NEW_POSTGRES_PASSWORD@10.0.0.11:5432/postgres"
EOF

chmod 600 "$CREDS_FILE"
echo -e "  $OK Credentials sauvegardés dans $CREDS_FILE"

# Recharger les nouvelles variables
source "$CREDS_FILE"

echo ""
echo "2. Mise à jour des mots de passe dans PostgreSQL..."
echo ""

# Identifier le leader
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    if ssh root@"$ip" "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'" 2>/dev/null; then
        LEADER_IP="$ip"
        echo "  Leader identifié: $ip"
        break
    fi
done

if [ -n "$LEADER_IP" ]; then
    echo -n "  Mise à jour des mots de passe: "
    ssh root@"$LEADER_IP" bash -s "$NEW_POSTGRES_PASSWORD" "$NEW_REPLICATOR_PASSWORD" <<'UPDATE_PASSWORDS'
NEW_PG_PWD="$1"
NEW_REPL_PWD="$2"

docker exec patroni psql -U postgres <<SQL
-- Mettre à jour les mots de passe
ALTER USER postgres PASSWORD '$NEW_PG_PWD';
ALTER USER replicator PASSWORD '$NEW_REPL_PWD';

-- Créer/Mettre à jour pgbouncer avec le même mot de passe que postgres
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'pgbouncer') THEN
        CREATE USER pgbouncer WITH PASSWORD '$NEW_PG_PWD';
    ELSE
        ALTER USER pgbouncer PASSWORD '$NEW_PG_PWD';
    END IF;
END
\$\$;

GRANT CONNECT ON DATABASE postgres TO pgbouncer;
SELECT 'Passwords updated' as status;
SQL
UPDATE_PASSWORDS
    echo -e "$OK"
fi

echo ""
echo "3. Arrêt et nettoyage de PgBouncer sur tous les nœuds..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Nettoyage $ip: "
    ssh root@"$ip" bash <<'CLEANUP'
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null
rm -rf /opt/keybuzz/pgbouncer/config/*
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}
CLEANUP
    echo -e "$OK"
done

echo ""
echo "4. Configuration SIMPLE de PgBouncer (sans base réservée)..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  Configuration $hostname:"
    
    ssh root@"$ip" bash -s "$NEW_POSTGRES_PASSWORD" "$ip" <<'CONFIGURE_PGBOUNCER'
PG_PASSWORD="$1"
LOCAL_IP="$2"

# Générer le hash MD5
MD5_POSTGRES=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)
MD5_PGBOUNCER=$(echo -n "${PG_PASSWORD}pgbouncer" | md5sum | cut -d' ' -f1)

# userlist.txt
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5${MD5_POSTGRES}"
"pgbouncer" "md5${MD5_PGBOUNCER}"
EOF

# pgbouncer.ini SIMPLE (pas de base pgbouncer qui est réservée)
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
# Base principale
postgres = host=${LOCAL_IP} port=5432 dbname=postgres

# Template pour toutes les autres bases
* = host=${LOCAL_IP} port=5432

[pgbouncer]
# Listen
listen_addr = 0.0.0.0
listen_port = 6432

# Auth
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

# Pool
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 10
reserve_pool_size = 5
reserve_pool_timeout = 5

# Server
server_reset_query = DISCARD ALL
server_check_query = select 1
server_check_delay = 30
max_db_connections = 100

# Timeouts
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60

# Logging
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid

# Admin
admin_users = postgres
stats_users = postgres, pgbouncer

# Ignore startup parameters
ignore_startup_parameters = extra_float_digits, application_name

# TCP
tcp_keepalive = 1
tcp_keepcnt = 3
tcp_keepidle = 300
tcp_keepintvl = 30
EOF

chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt
chmod 644 /opt/keybuzz/pgbouncer/config/pgbouncer.ini

echo "    Config créée"
CONFIGURE_PGBOUNCER
done

echo ""
echo "5. Démarrage de PgBouncer..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Start $hostname: "
    
    ssh root@"$ip" bash <<'START_PGBOUNCER'
docker run -d \
  --name pgbouncer \
  --hostname $(hostname)-pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer:latest >/dev/null 2>&1
START_PGBOUNCER
    
    echo -e "$OK"
done

echo ""
echo "6. Attente du démarrage (10s)..."
sleep 10

echo ""
echo "7. Test de PgBouncer..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo -n "  Test $hostname (port 6432): "
    
    if PGPASSWORD="$NEW_POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
        echo -e "$OK"
    else
        echo -e "$KO"
        # Debug
        echo "    État container:"
        ssh root@"$ip" "docker ps | grep pgbouncer" 2>/dev/null | awk '{print $7,$8}' | sed 's/^/      /'
        echo "    Dernière erreur:"
        ssh root@"$ip" "docker logs pgbouncer 2>&1 | tail -2" 2>/dev/null | sed 's/^/      /'
    fi
done

echo ""
echo "8. Test pgvector..."
echo ""

if [ -n "$LEADER_IP" ]; then
    echo -n "  Installation/Test pgvector: "
    
    ssh root@"$LEADER_IP" bash <<'TEST_PGVECTOR'
# S'assurer que pgvector est installé
docker exec patroni bash -c "
apt-get update -qq >/dev/null 2>&1
apt-get install -y postgresql-17-pgvector >/dev/null 2>&1 || true
"

# Créer l'extension et tester
docker exec patroni psql -U postgres <<SQL 2>/dev/null
-- Créer extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Table de test
DROP TABLE IF EXISTS vector_test CASCADE;
CREATE TABLE vector_test (
    id serial PRIMARY KEY,
    embedding vector(3)
);

-- Insérer des données
INSERT INTO vector_test (embedding) VALUES 
    ('[1,0,0]'),
    ('[0,1,0]'),
    ('[0,0,1]');

-- Test de recherche
SELECT COUNT(*) as vector_count FROM vector_test;
SQL
TEST_PGVECTOR
    
    if ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c 'SELECT COUNT(*) FROM vector_test' -t 2>/dev/null" | grep -q 3; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
fi

echo ""
echo "9. Test final via HAProxy..."
echo ""

echo -n "  HAProxy Write (port 5432): "
if PGPASSWORD="$NEW_POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "  HAProxy Read (port 5433): "
if PGPASSWORD="$NEW_POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5433 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "CONFIGURATION FINALE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "MOTS DE PASSE (alphanumériques uniquement):"
echo "  User: postgres"
echo "  Password: $NEW_POSTGRES_PASSWORD"
echo ""
echo "CONNEXIONS DISPONIBLES:"
echo "  • Direct: PGPASSWORD='$NEW_POSTGRES_PASSWORD' psql -h 10.0.0.120 -p 5432 -U postgres"
echo "  • PgBouncer: PGPASSWORD='$NEW_POSTGRES_PASSWORD' psql -h 10.0.0.120 -p 6432 -U postgres"
echo "  • HAProxy Write: PGPASSWORD='$NEW_POSTGRES_PASSWORD' psql -h 10.0.0.11 -p 5432 -U postgres"
echo "  • HAProxy Read: PGPASSWORD='$NEW_POSTGRES_PASSWORD' psql -h 10.0.0.11 -p 5433 -U postgres"
echo ""
echo "POUR LES APPLICATIONS (n8n, Chatwoot):"
echo "  DATABASE_URL=postgresql://postgres:$NEW_POSTGRES_PASSWORD@10.0.0.11:5432/postgres"
echo ""
echo "Fichier credentials: $CREDS_FILE"
echo "═══════════════════════════════════════════════════════════════════"
