#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   PHASE_1_STANDALONE - PostgreSQL Standalone stable avant cluster  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Configuration
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Générer un mot de passe SIMPLE (alphanumérique uniquement)
generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

echo ""
echo "STRATÉGIE: Démarrer PostgreSQL en STANDALONE d'abord"
echo "           Tester et valider AVANT de passer en cluster"
echo ""

# ========================================
# ÉTAPE 1: ARRÊT COMPLET DE TOUT
# ========================================
echo "1. ARRÊT COMPLET de tous les services (nettoyage total)..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo -n "  Nettoyage $hostname: "
    ssh root@"$ip" bash <<'CLEANUP' 2>/dev/null
# Arrêter TOUS les containers
docker stop patroni pgbouncer postgres etcd 2>/dev/null
docker rm -f patroni pgbouncer postgres etcd 2>/dev/null

# Tuer tous les processus
pkill -9 postgres 2>/dev/null
pkill -9 patroni 2>/dev/null
pkill -9 pgbouncer 2>/dev/null
pkill -9 etcd 2>/dev/null

# Nettoyer les données
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /opt/keybuzz/patroni/raft/*
rm -rf /var/lib/postgresql/*
rm -rf /var/lib/etcd/*

# Nettoyer les ports
fuser -k 5432/tcp 2>/dev/null
fuser -k 6432/tcp 2>/dev/null
fuser -k 2379/tcp 2>/dev/null
fuser -k 2380/tcp 2>/dev/null
fuser -k 8008/tcp 2>/dev/null

echo "Clean"
CLEANUP
    echo -e "$OK"
done

# ========================================
# ÉTAPE 2: GÉNÉRATION DES CREDENTIALS
# ========================================
echo ""
echo "2. Génération de mots de passe SIMPLES (sans caractères spéciaux)..."
echo ""

POSTGRES_PASSWORD=$(generate_password)
echo "  Nouveau mot de passe: $POSTGRES_PASSWORD"

# Sauvegarder
cat > "$CREDS_DIR/postgres.env" <<EOF
#!/bin/bash
# PostgreSQL Credentials - Phase 1 Standalone
# Generated: $(date)

export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$POSTGRES_PASSWORD"
export PATRONI_API_PASSWORD="$POSTGRES_PASSWORD"
export PGBOUNCER_PASSWORD="$POSTGRES_PASSWORD"

# Pour les applications
export DATABASE_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.120:5432/postgres"
export N8N_DATABASE_URL="postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.120:5432/n8n"
export CHATWOOT_DATABASE_URL="postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.120:5432/chatwoot"
EOF

chmod 600 "$CREDS_DIR/postgres.env"
source "$CREDS_DIR/postgres.env"

# ========================================
# ÉTAPE 3: POSTGRESQL STANDALONE sur MASTER
# ========================================
echo ""
echo "3. Installation PostgreSQL 17 STANDALONE sur db-master-01..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'POSTGRES_STANDALONE'
PG_PASSWORD="$1"

# Créer les répertoires
mkdir -p /opt/keybuzz/postgres/{data,logs,archive,backups}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data

# Créer un Dockerfile pour PostgreSQL avec extensions
cd /opt/keybuzz/postgres

cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

# Installer les extensions nécessaires
RUN apt-get update && \
    apt-get install -y \
        postgresql-17-pgvector \
        postgresql-17-pg-stat-kcache \
        postgresql-17-pgaudit \
        postgresql-contrib-17 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Script d'initialisation
COPY init.sql /docker-entrypoint-initdb.d/
DOCKERFILE

# Script d'initialisation SQL
cat > init.sql <<SQL
-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Utilisateurs pour applications
CREATE USER n8n WITH PASSWORD '$PG_PASSWORD';
CREATE USER chatwoot WITH PASSWORD '$PG_PASSWORD';
CREATE USER pgbouncer WITH PASSWORD '$PG_PASSWORD';

-- Bases de données
CREATE DATABASE n8n OWNER n8n;
CREATE DATABASE chatwoot OWNER chatwoot;

-- Permissions
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
GRANT CONNECT ON DATABASE postgres TO pgbouncer;

-- Configuration pour n8n (éviter les problèmes de migration)
ALTER DATABASE n8n SET statement_timeout = '300s';
ALTER DATABASE n8n SET idle_in_transaction_session_timeout = '300s';
ALTER DATABASE n8n SET lock_timeout = '10s';
SQL

# Build l'image
docker build -t postgres:17-custom .

# Démarrer PostgreSQL en STANDALONE
docker run -d \
  --name postgres \
  --hostname db-master-01 \
  --restart unless-stopped \
  -p 5432:5432 \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=en_US.UTF-8" \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/logs:/var/log/postgresql \
  postgres:17-custom

echo "PostgreSQL Standalone démarré"
POSTGRES_STANDALONE

echo "  Attente du démarrage (20s)..."
sleep 20

# ========================================
# ÉTAPE 4: TEST DU STANDALONE
# ========================================
echo ""
echo "4. Tests du PostgreSQL Standalone..."
echo ""

# Test de connexion
echo -n "  Test connexion: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT version()" 2>/dev/null | grep -q "PostgreSQL 17"; then
    echo -e "$OK PostgreSQL 17"
else
    echo -e "$KO"
fi

# Test base n8n
echo -n "  Test base n8n: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test base chatwoot
echo -n "  Test base chatwoot: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test pgvector
echo -n "  Test pgvector: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q vector; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# ========================================
# ÉTAPE 5: PGBOUNCER SIMPLE
# ========================================
echo ""
echo "5. Installation PgBouncer SIMPLE (pas de complexité)..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'PGBOUNCER_SIMPLE'
PG_PASSWORD="$1"

# Utiliser l'image edoburu qui fonctionne
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  -p 6432:6432 \
  -e DATABASES_HOST=localhost \
  -e DATABASES_PORT=5432 \
  -e DATABASES_USER=postgres \
  -e DATABASES_PASSWORD="$PG_PASSWORD" \
  -e DATABASES_DBNAME=postgres \
  -e POOL_MODE=transaction \
  -e MAX_CLIENT_CONN=200 \
  -e DEFAULT_POOL_SIZE=25 \
  -e AUTH_TYPE=plain \
  edoburu/pgbouncer:latest

echo "PgBouncer démarré"
PGBOUNCER_SIMPLE

sleep 5

# Test PgBouncer
echo -n "  Test PgBouncer: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# ========================================
# RÉSUMÉ ET PROCHAINES ÉTAPES
# ========================================
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "PHASE 1 COMPLÉTÉE - PostgreSQL Standalone"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Services actifs sur db-master-01:"
echo "  • PostgreSQL 17: 10.0.0.120:5432"
echo "  • PgBouncer: 10.0.0.120:6432"
echo ""
echo "Bases créées:"
echo "  • n8n (user: n8n)"
echo "  • chatwoot (user: chatwoot)"
echo ""
echo "Mot de passe: $POSTGRES_PASSWORD"
echo ""
echo "Connexions:"
echo "  psql -h 10.0.0.120 -p 5432 -U postgres"
echo "  psql -h 10.0.0.120 -p 6432 -U postgres  (via PgBouncer)"
echo ""
echo "PROCHAINE ÉTAPE: Une fois validé, lancer:"
echo "  ./phase_2_add_replicas.sh"
echo "  (ajoutera db-slave-01 et db-slave-02 en réplication streaming)"
echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Sauvegarder l'état
echo "PHASE_1_COMPLETE" > "$CREDS_DIR/cluster_state.txt"
echo "MASTER_IP=10.0.0.120" >> "$CREDS_DIR/cluster_state.txt"
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >> "$CREDS_DIR/cluster_state.txt"
