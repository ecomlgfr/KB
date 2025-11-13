#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       06_POSTGRES_STANDALONE - PostgreSQL 17 Installation          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)
PG_VERSION="17"
PG_PASSWORD="KeyBuzz2024Secure!"

echo ""
echo "═══ Installation PostgreSQL $PG_VERSION (standalone) ═══"
echo ""

# Sauvegarder le mot de passe
mkdir -p /opt/keybuzz-installer/credentials
cat > /opt/keybuzz-installer/credentials/postgres.env <<EOF
POSTGRES_PASSWORD=$PG_PASSWORD
POSTGRES_REPLICATION_PASSWORD=$PG_PASSWORD
POSTGRES_VERSION=$PG_VERSION
EOF
chmod 600 /opt/keybuzz-installer/credentials/postgres.env

for node in "${DB_NODES[@]}"; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP" ] && { echo -e "$KO $node IP introuvable"; continue; }
    
    echo "→ $node ($IP)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash -s "$node" "$PG_PASSWORD" "$PG_VERSION" <<'REMOTE'
set -u
set -o pipefail

NODE_NAME="$1"
PG_PASSWORD="$2"
PG_VERSION="$3"

# Créer structure
mkdir -p /opt/keybuzz/postgres/{data,config,logs,status}

# Vérifier volume monté
if ! mountpoint -q /opt/keybuzz/postgres/data; then
    echo "  ⚠ Volume non monté - utilisation stockage local"
fi

# Nettoyer lost+found si présent
if [ -d /opt/keybuzz/postgres/data/lost+found ]; then
    rm -rf /opt/keybuzz/postgres/data/lost+found
    echo "  ✓ lost+found supprimé"
fi

# Arrêter si existe
docker stop postgres 2>/dev/null || true
docker rm postgres 2>/dev/null || true

# Configuration PostgreSQL optimisée
cat > /opt/keybuzz/postgres/config/postgresql.conf <<EOF
# Network
listen_addresses = '*'
port = 5432
max_connections = 200

# Memory (ajusté pour prod)
shared_buffers = 1GB
effective_cache_size = 3GB
work_mem = 8MB
maintenance_work_mem = 256MB

# WAL & Replication
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 1GB
archive_mode = on
archive_command = 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'

# Checkpoints
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9

# Query tuning
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100

# Logs
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/lib/postgresql/data/log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_line_prefix = '%t [%p] %q%u@%d '
log_statement = 'ddl'
log_duration = off
log_min_duration_statement = 100

# Autovacuum
autovacuum = on
autovacuum_max_workers = 4
autovacuum_naptime = 30s
EOF

# pg_hba.conf pour authentification
cat > /opt/keybuzz/postgres/config/pg_hba.conf <<EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             10.0.0.0/16             scram-sha-256
host    replication     replicator      10.0.0.0/16             scram-sha-256
EOF

# Créer répertoire d'archive
mkdir -p /opt/keybuzz/postgres/archive

# Démarrer PostgreSQL
docker run -d \
  --name postgres \
  --restart unless-stopped \
  --network host \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -e POSTGRES_DB=keybuzz \
  -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=en_US.UTF-8 --data-checksums" \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/config/postgresql.conf:/etc/postgresql/postgresql.conf:ro \
  -v /opt/keybuzz/postgres/config/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  postgres:${PG_VERSION} \
  postgres \
  -c config_file=/etc/postgresql/postgresql.conf \
  -c hba_file=/etc/postgresql/pg_hba.conf

echo "  Attente démarrage PostgreSQL..."
sleep 10

# Vérifier démarrage
if docker ps | grep -q postgres; then
    echo "  ✓ PostgreSQL démarré"
    
    # Créer utilisateur réplication
    docker exec postgres psql -U postgres -c "
    CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD '$PG_PASSWORD';
    CREATE USER patroni WITH SUPERUSER ENCRYPTED PASSWORD '$PG_PASSWORD';
    " 2>/dev/null || true
    
    # Test connexion
    if docker exec postgres pg_isready -U postgres >/dev/null 2>&1; then
        echo "  ✓ PostgreSQL prêt"
    else
        echo "  ✗ PostgreSQL non prêt"
        exit 1
    fi
else
    echo "  ✗ PostgreSQL échec démarrage"
    docker logs postgres 2>&1 | tail -20
    exit 1
fi

echo "✓ $NODE_NAME configuré"
REMOTE
    
    [ $? -eq 0 ] && echo -e "  $OK" || echo -e "  $KO"
done

echo ""
echo -e "$OK Installation PostgreSQL $PG_VERSION terminée"
echo ""
echo "Credentials sauvegardés: /opt/keybuzz-installer/credentials/postgres.env"
echo "Prochaine étape: ./07_test_postgres_standalone.sh"
