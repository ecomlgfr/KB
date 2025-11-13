#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     CLUSTER_RECOVERY - Récupération complète du cluster PostgreSQL ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Variables
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
CURRENT_PASSWORD="rA56cI5YfGy5TQeT"

echo ""
echo "Mot de passe actuel: $CURRENT_PASSWORD"
echo ""

# Sauvegarder le mot de passe dans postgres.env
cat > "$CREDS_DIR/postgres.env" <<EOF
#!/bin/bash
export POSTGRES_PASSWORD="$CURRENT_PASSWORD"
export REPLICATOR_PASSWORD="$CURRENT_PASSWORD"
export PATRONI_API_PASSWORD="$CURRENT_PASSWORD"
export PGBOUNCER_PASSWORD="$CURRENT_PASSWORD"
export DATABASE_URL="postgresql://postgres:$CURRENT_PASSWORD@10.0.0.11:5432/postgres"
EOF
chmod 600 "$CREDS_DIR/postgres.env"
source "$CREDS_DIR/postgres.env"

echo "1. Diagnostic rapide..."
echo ""

# Vérifier l'état des containers Patroni
PATRONI_RUNNING=0
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Patroni sur $ip: "
    if ssh root@"$ip" "docker ps | grep -q patroni && docker exec patroni psql -U postgres -c 'SELECT 1' &>/dev/null" 2>/dev/null; then
        echo -e "$OK Running"
        PATRONI_RUNNING=$((PATRONI_RUNNING + 1))
    else
        echo -e "$KO Down"
    fi
done

if [ $PATRONI_RUNNING -eq 0 ]; then
    echo ""
    echo "2. Redémarrage d'urgence du cluster Patroni..."
    echo ""
    
    # Redémarrer les containers Patroni
    for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
        echo -n "  Restart Patroni $ip: "
        ssh root@"$ip" bash <<'RESTART_PATRONI' 2>/dev/null
# Essayer de redémarrer le container existant
if docker ps -a | grep -q patroni; then
    docker start patroni
else
    # Si le container n'existe plus, le recréer
    docker run -d \
      --name patroni \
      --hostname $(hostname) \
      --network host \
      --restart unless-stopped \
      -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
      -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
      -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
      patroni:17-raft
fi
RESTART_PATRONI
        echo -e "$OK"
    done
    
    echo "  Attente du démarrage (30s)..."
    sleep 30
fi

echo ""
echo "3. Identification du leader PostgreSQL..."
echo ""

LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    if ssh root@"$ip" "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'" 2>/dev/null; then
        LEADER_IP="$ip"
        echo -e "  Leader trouvé: $ip $OK"
        break
    fi
done

if [ -z "$LEADER_IP" ]; then
    echo -e "  $KO Aucun leader PostgreSQL actif!"
    echo "  Tentative de démarrage forcé sur db-master-01..."
    
    ssh root@10.0.0.120 bash <<'FORCE_START'
# Nettoyer et redémarrer
docker stop patroni 2>/dev/null
docker rm patroni 2>/dev/null
rm -rf /opt/keybuzz/postgres/raft/*

docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni:17-raft
FORCE_START
    
    sleep 20
    LEADER_IP="10.0.0.120"
fi

echo ""
echo "4. Mise à jour des mots de passe dans PostgreSQL..."
echo ""

if [ -n "$LEADER_IP" ]; then
    ssh root@"$LEADER_IP" bash -s "$CURRENT_PASSWORD" <<'UPDATE_PWD'
NEW_PWD="$1"

docker exec patroni psql -U postgres <<SQL
-- Mettre à jour les mots de passe
ALTER USER postgres PASSWORD '$NEW_PWD';
ALTER USER replicator PASSWORD '$NEW_PWD';

-- Utilisateurs pour applications
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'n8n') THEN
        CREATE USER n8n WITH PASSWORD '$NEW_PWD';
    ELSE
        ALTER USER n8n PASSWORD '$NEW_PWD';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'chatwoot') THEN
        CREATE USER chatwoot WITH PASSWORD '$NEW_PWD';
    ELSE
        ALTER USER chatwoot PASSWORD '$NEW_PWD';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'pgbouncer') THEN
        CREATE USER pgbouncer WITH PASSWORD '$NEW_PWD';
    ELSE
        ALTER USER pgbouncer PASSWORD '$NEW_PWD';
    END IF;
END
\$\$;

-- Créer les bases
CREATE DATABASE n8n OWNER n8n;
CREATE DATABASE chatwoot OWNER chatwoot;

-- Extensions
\c n8n
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

\c chatwoot
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

SELECT 'Passwords and databases updated' as status;
SQL
UPDATE_PWD
    echo -e "  $OK Mots de passe et bases mis à jour"
fi

echo ""
echo "5. Installation PgBouncer avec image edoburu (qui fonctionne)..."
echo ""

# Installer PgBouncer sur les nœuds DB (pas sur HAProxy)
for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  PgBouncer sur $hostname:"
    
    ssh root@"$ip" bash -s "$CURRENT_PASSWORD" "$ip" <<'INSTALL_PGBOUNCER'
PG_PASSWORD="$1"
LOCAL_IP="$2"

# Arrêter l'ancien
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Créer la config
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Configuration simple sans userlist (tout dans les variables d'environnement)
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  --network host \
  -e DATABASES_HOST="$LOCAL_IP" \
  -e DATABASES_PORT=5432 \
  -e DATABASES_USER=postgres \
  -e DATABASES_PASSWORD="$PG_PASSWORD" \
  -e DATABASES_DBNAME=postgres \
  -e POOL_MODE=transaction \
  -e MAX_CLIENT_CONN=1000 \
  -e DEFAULT_POOL_SIZE=25 \
  -e AUTH_TYPE=plain \
  -e LISTEN_PORT=6432 \
  edoburu/pgbouncer:latest

echo "    Container démarré"
INSTALL_PGBOUNCER
done

echo ""
echo "6. Redémarrage HAProxy..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo -n "  HAProxy $ip: "
    ssh root@"$ip" "docker restart haproxy 2>/dev/null || echo 'Pas de container HAProxy'" 2>/dev/null
    echo -e "$OK"
done

sleep 5

echo ""
echo "7. Tests de connectivité..."
echo ""

# Test PostgreSQL direct
echo -n "  PostgreSQL direct (leader): "
if PGPASSWORD="$CURRENT_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test PgBouncer
echo -n "  PgBouncer sur leader: "
if PGPASSWORD="$CURRENT_PASSWORD" psql -h "$LEADER_IP" -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test HAProxy
echo -n "  HAProxy Write (10.0.0.11:5432): "
if PGPASSWORD="$CURRENT_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test bases n8n et chatwoot
echo -n "  Base n8n: "
if PGPASSWORD="$CURRENT_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U n8n -d n8n -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "  Base chatwoot: "
if PGPASSWORD="$CURRENT_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "8. Configuration finale pour n8n et Chatwoot..."
echo ""

APP_CONFIG="$CREDS_DIR/app_configs.env"
cat > "$APP_CONFIG" <<EOF
# Configuration n8n (v1.116.2+)
# IMPORTANT: Utiliser ces variables pour éviter les problèmes de migration

N8N_DATABASE_TYPE=postgresdb
N8N_DATABASE_HOST=10.0.0.11
N8N_DATABASE_PORT=5432
N8N_DATABASE_NAME=n8n
N8N_DATABASE_USER=n8n
N8N_DATABASE_PASSWORD=$CURRENT_PASSWORD

# Options critiques pour n8n
DB_POSTGRESDB_MIGRATIONS_TABLE_QUOTE=false
N8N_DATABASE_MIGRATIONS_TRANSACTION_MODE=none
DB_POSTGRESDB_POOL_SIZE=25

# Configuration Chatwoot
POSTGRES_HOST=10.0.0.11
POSTGRES_PORT=5432
POSTGRES_DATABASE=chatwoot
POSTGRES_USERNAME=chatwoot
POSTGRES_PASSWORD=$CURRENT_PASSWORD

# Redis pour Chatwoot (si installé)
REDIS_URL=redis://10.0.0.123:6379

# URLs complètes
N8N_DATABASE_URL=postgresql://n8n:$CURRENT_PASSWORD@10.0.0.11:5432/n8n
CHATWOOT_DATABASE_URL=postgresql://chatwoot:$CURRENT_PASSWORD@10.0.0.11:5432/chatwoot
EOF

chmod 600 "$APP_CONFIG"
echo -e "  $OK Configurations sauvegardées dans $APP_CONFIG"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAT FINAL DU CLUSTER"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Résumé
SERVICES_OK=0
echo "Services:"

PGPASSWORD="$CURRENT_PASSWORD" psql -h "${LEADER_IP:-10.0.0.120}" -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && { echo -e "  PostgreSQL: $OK"; SERVICES_OK=$((SERVICES_OK+1)); } || echo -e "  PostgreSQL: $KO"

PGPASSWORD="$CURRENT_PASSWORD" psql -h "${LEADER_IP:-10.0.0.120}" -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && { echo -e "  PgBouncer: $OK"; SERVICES_OK=$((SERVICES_OK+1)); } || echo -e "  PgBouncer: $KO"

PGPASSWORD="$CURRENT_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && { echo -e "  HAProxy: $OK"; SERVICES_OK=$((SERVICES_OK+1)); } || echo -e "  HAProxy: $KO"

PGPASSWORD="$CURRENT_PASSWORD" psql -h "${LEADER_IP:-10.0.0.120}" -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && { echo -e "  Base n8n: $OK"; SERVICES_OK=$((SERVICES_OK+1)); } || echo -e "  Base n8n: $KO"

PGPASSWORD="$CURRENT_PASSWORD" psql -h "${LEADER_IP:-10.0.0.120}" -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && { echo -e "  Base Chatwoot: $OK"; SERVICES_OK=$((SERVICES_OK+1)); } || echo -e "  Base Chatwoot: $KO"

echo ""
if [ $SERVICES_OK -ge 4 ]; then
    echo -e "$OK Cluster PostgreSQL récupéré avec succès!"
    echo ""
    echo "Connexions:"
    echo "  • Direct: PGPASSWORD='$CURRENT_PASSWORD' psql -h ${LEADER_IP:-10.0.0.120} -p 5432 -U postgres"
    echo "  • HAProxy: PGPASSWORD='$CURRENT_PASSWORD' psql -h 10.0.0.11 -p 5432 -U postgres"
    echo "  • n8n: postgresql://n8n:$CURRENT_PASSWORD@10.0.0.11:5432/n8n"
    echo "  • Chatwoot: postgresql://chatwoot:$CURRENT_PASSWORD@10.0.0.11:5432/chatwoot"
else
    echo -e "$KO Certains services nécessitent encore attention"
fi

echo "═══════════════════════════════════════════════════════════════════"
