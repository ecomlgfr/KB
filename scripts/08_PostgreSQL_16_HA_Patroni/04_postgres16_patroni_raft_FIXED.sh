#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    04_POSTGRES16_PATRONI_RAFT - PostgreSQL 16 + Patroni RAFT       ║"
echo "║              (FIXED: Démarrage parallèle pour quorum)              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_FILE="/opt/keybuzz-installer/logs/postgres_patroni_$(date +%Y%m%d_%H%M%S).log"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

mkdir -p "$CREDS_DIR" "$(dirname "$LOG_FILE")"

# Fonction pour générer un mot de passe sécurisé
generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 24 | head -n 1
}

echo "" | tee -a "$LOG_FILE"
echo "═══ 1. Gestion des credentials ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Charger ou générer les credentials
if [ -f "$CREDS_DIR/postgres.env" ]; then
    source "$CREDS_DIR/postgres.env"
    
    if [ -z "${POSTGRES_PASSWORD:-}" ] || [ -z "${REPLICATOR_PASSWORD:-}" ] || [ -z "${PATRONI_API_PASSWORD:-}" ]; then
        echo "  Credentials incomplets, régénération..." | tee -a "$LOG_FILE"
        NEED_GEN=true
    else
        echo "  Credentials existants conservés" | tee -a "$LOG_FILE"
        NEED_GEN=false
    fi
else
    echo "  Génération des nouveaux credentials..." | tee -a "$LOG_FILE"
    NEED_GEN=true
fi

if [ "$NEED_GEN" = true ]; then
    POSTGRES_PASSWORD=$(generate_password)
    REPLICATOR_PASSWORD=$(generate_password)
    PATRONI_API_PASSWORD=$(generate_password)
    
    cat > "$CREDS_DIR/postgres.env" <<EOF
#!/bin/bash
# Credentials PostgreSQL/Patroni - Générés le $(date '+%Y-%m-%d %H:%M:%S')

export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD"
export PATRONI_API_PASSWORD="$PATRONI_API_PASSWORD"
export PGPASSWORD="$POSTGRES_PASSWORD"

# URLs de connexion (via LB Hetzner 10.0.0.10)
export DATABASE_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:6432/postgres"
export KEYBUZZ_DATABASE_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:6432/keybuzz"
export N8N_DATABASE_URL="postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.10:6432/n8n"
export CHATWOOT_DATABASE_URL="postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.10:6432/chatwoot"

# HAProxy direct (debug/monitoring uniquement)
export HAPROXY_WRITE_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.11:5432/postgres"
export HAPROXY_READ_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.11:5433/postgres"
EOF
    
    chmod 600 "$CREDS_DIR/postgres.env"
    echo "  ✓ Nouveaux credentials générés" | tee -a "$LOG_FILE"
fi

source "$CREDS_DIR/postgres.env"

echo "" | tee -a "$LOG_FILE"
echo "═══ 2. Configuration des nœuds ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Mapping des nœuds
declare -A NODE_IPS=(
    [db-master-01]="10.0.0.120"
    [db-slave-01]="10.0.0.121"
    [db-slave-02]="10.0.0.122"
)

# Fonction pour créer la configuration Patroni
create_patroni_config() {
    local node_name="$1"
    local node_ip="$2"
    local partners="$3"
    
    cat <<EOF
scope: postgres-cluster
namespace: /service/
name: $node_name

restapi:
  listen: ${node_ip}:8008
  connect_address: ${node_ip}:8008
  authentication:
    username: patroni
    password: ${PATRONI_API_PASSWORD}

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${node_ip}:7000
  partner_addrs:
${partners}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        shared_buffers: 256MB
        effective_cache_size: 768MB
        maintenance_work_mem: 64MB
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        work_mem: 2621kB
        min_wal_size: 1GB
        max_wal_size: 4GB
        max_worker_processes: 4
        max_parallel_workers_per_gather: 2
        max_parallel_workers: 4
        max_parallel_maintenance_workers: 2
        
  initdb:
    - encoding: UTF8
    - locale: en_US.UTF-8
    - data-checksums
    
  pg_hba:
    - local all all trust
    - host all all 10.0.0.0/16 scram-sha-256
    - host replication replicator 10.0.0.0/16 scram-sha-256
    
  post_bootstrap: /usr/local/bin/setup_postgres.sh
  
  users:
    postgres:
      password: ${POSTGRES_PASSWORD}
      options:
        - createrole
        - createdb
    replicator:
      password: ${REPLICATOR_PASSWORD}
      options:
        - replication

postgresql:
  listen: ${node_ip}:5432
  connect_address: ${node_ip}:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    replication:
      username: replicator
      password: ${REPLICATOR_PASSWORD}
    superuser:
      username: postgres
      password: ${POSTGRES_PASSWORD}
    rewind:
      username: replicator
      password: ${REPLICATOR_PASSWORD}
  parameters:
    unix_socket_directories: '/var/run/postgresql'
    password_encryption: scram-sha-256
    
  create_replica_methods:
    - basebackup
  basebackup:
    - waldir: /var/lib/postgresql/data/pg_wal

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false

watchdog:
  mode: off
EOF
}

# Créer le script de post-bootstrap
create_post_bootstrap_script() {
    cat <<'EOF'
#!/bin/bash
set -e

# Attendre que PostgreSQL soit prêt
until pg_isready -U postgres; do
    echo "Attente PostgreSQL..."
    sleep 2
done

# Créer pgvector
psql -U postgres -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" || true

echo "Post-bootstrap terminé"
EOF
}

# Configurer tous les nœuds AVANT le démarrage
for node_name in db-master-01 db-slave-01 db-slave-02; do
    node_ip="${NODE_IPS[$node_name]}"
    echo "→ Configuration $node_name ($node_ip)" | tee -a "$LOG_FILE"
    
    # Construire la liste des partners pour RAFT (toutes les IPs sauf soi-même)
    partner1=""
    partner2=""
    if [ "$node_name" = "db-master-01" ]; then
        partner1="10.0.0.121"
        partner2="10.0.0.122"
    elif [ "$node_name" = "db-slave-01" ]; then
        partner1="10.0.0.120"
        partner2="10.0.0.122"
    else
        partner1="10.0.0.120"
        partner2="10.0.0.121"
    fi
    
    ssh -o StrictHostKeyChecking=no root@"$node_ip" bash -s "$node_name" "$node_ip" "$partner1" "$partner2" "$POSTGRES_PASSWORD" "$REPLICATOR_PASSWORD" "$PATRONI_API_PASSWORD" <<'CONFIG'
set -u
set -o pipefail

NODE_NAME="$1"
NODE_IP="$2"
PARTNER1="$3"
PARTNER2="$4"
PG_PASSWORD="$5"
REPL_PASSWORD="$6"
API_PASSWORD="$7"

# Arrêter si existe
docker stop patroni 2>/dev/null || true
docker rm -f patroni 2>/dev/null || true

# Structure
mkdir -p /opt/keybuzz/postgres/{data,raft,archive,config,logs,status}
mkdir -p /opt/keybuzz/patroni/{config,logs}

# Vérifier le volume
if ! mountpoint -q /opt/keybuzz/postgres/data; then
    echo "  ✗ Volume non monté sur /opt/keybuzz/postgres/data"
    exit 1
fi

# Permissions
chown -R 999:999 /opt/keybuzz/postgres 2>/dev/null || true
chmod 700 /opt/keybuzz/postgres/data 2>/dev/null || true
chmod 755 /opt/keybuzz/postgres/raft 2>/dev/null || true

# Nettoyer les anciens fichiers RAFT
rm -rf /opt/keybuzz/postgres/raft/* 2>/dev/null || true

# Créer patroni.yml avec indentation correcte
cat > /opt/keybuzz/patroni/config/patroni.yml <<PATRONIEOF
scope: postgres-cluster
namespace: /service/
name: ${NODE_NAME}

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008
  authentication:
    username: patroni
    password: ${API_PASSWORD}

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${NODE_IP}:7000
  partner_addrs:
    - ${PARTNER1}:7000
    - ${PARTNER2}:7000

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        shared_buffers: 256MB
        effective_cache_size: 768MB
        maintenance_work_mem: 64MB
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        work_mem: 2621kB
        min_wal_size: 1GB
        max_wal_size: 4GB
        max_worker_processes: 4
        max_parallel_workers_per_gather: 2
        max_parallel_workers: 4
        max_parallel_maintenance_workers: 2
        
  initdb:
    - encoding: UTF8
    - locale: en_US.UTF-8
    - data-checksums
    
  pg_hba:
    - local all all trust
    - host all all 10.0.0.0/16 scram-sha-256
    - host replication replicator 10.0.0.0/16 scram-sha-256
    
  users:
    postgres:
      password: ${PG_PASSWORD}
      options:
        - createrole
        - createdb
    replicator:
      password: ${REPL_PASSWORD}
      options:
        - replication

postgresql:
  listen: ${NODE_IP}:5432
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    replication:
      username: replicator
      password: ${REPL_PASSWORD}
    superuser:
      username: postgres
      password: ${PG_PASSWORD}
    rewind:
      username: replicator
      password: ${REPL_PASSWORD}
  parameters:
    unix_socket_directories: '/var/run/postgresql'
    password_encryption: scram-sha-256
    
  create_replica_methods:
    - basebackup
  basebackup:
    waldir: /var/lib/postgresql/data/pg_wal

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false

watchdog:
  mode: off
PATRONIEOF

# Dockerfile
cat > /opt/keybuzz/patroni/Dockerfile <<'DOCKERFILE'
FROM postgres:16

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3-pip \
        python3-dev \
        python3-psycopg2 \
        python3-setuptools \
        python3-wheel \
        gcc \
        postgresql-server-dev-16 \
        git \
        ca-certificates && \
    pip3 install --break-system-packages --no-cache-dir \
        patroni[raft]==3.3.0 \
        python-etcd && \
    apt-get remove -y gcc git && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# pgvector
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-16-pgvector && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/postgresql && \
    chown -R postgres:postgres /var/run/postgresql

USER postgres

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

# Build
cd /opt/keybuzz/patroni
docker build -t patroni-pg16-raft:latest . >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "  ✓ Image construite"
else
    echo "  ✗ Échec build"
    exit 1
fi

echo "OK" > /opt/keybuzz/postgres/status/STATE
CONFIG
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Configuration terminée" | tee -a "$LOG_FILE"
    else
        echo -e "  $KO Échec configuration" | tee -a "$LOG_FILE"
        exit 1
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "═══ 3. Démarrage parallèle du cluster RAFT ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo -e "$WARN Avec RAFT, tous les nœuds doivent démarrer ensemble pour le quorum" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Démarrer TOUS les nœuds en parallèle
for node_name in db-master-01 db-slave-01 db-slave-02; do
    node_ip="${NODE_IPS[$node_name]}"
    echo "→ Lancement $node_name ($node_ip)..." | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$node_ip" bash -s "$node_name" <<'START' &
NODE_NAME="$1"

docker run -d \
  --name patroni \
  --hostname $NODE_NAME \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg16-raft:latest >/dev/null 2>&1

sleep 3
if docker ps | grep -q patroni; then
    echo "  ✓ Conteneur démarré"
else
    echo "  ✗ Échec"
    exit 1
fi
START
done

# Attendre la fin des démarrages parallèles
wait

echo "" | tee -a "$LOG_FILE"
echo "  Attente établissement du quorum RAFT (60s)..." | tee -a "$LOG_FILE"
sleep 60

echo "" | tee -a "$LOG_FILE"
echo "═══ 4. Vérification du quorum et élection du leader ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

LEADER_IP=""
LEADER_NAME=""

# Essayer de trouver le leader (jusqu'à 10 tentatives)
for attempt in {1..10}; do
    echo "  Tentative $attempt/10..." | tee -a "$LOG_FILE"
    
    for node_name in db-master-01 db-slave-01 db-slave-02; do
        node_ip="${NODE_IPS[$node_name]}"
        
        # Vérifier si le nœud est leader
        if ssh -o StrictHostKeyChecking=no root@"$node_ip" \
            "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'"; then
            LEADER_IP="$node_ip"
            LEADER_NAME="$node_name"
            echo -e "  $OK Leader trouvé: $LEADER_NAME ($LEADER_IP)" | tee -a "$LOG_FILE"
            break 2
        fi
    done
    
    if [ $attempt -lt 10 ]; then
        echo "  Pas de leader encore, attente 10s..." | tee -a "$LOG_FILE"
        sleep 10
    fi
done

if [ -z "$LEADER_IP" ]; then
    echo -e "$KO Aucun leader élu après 100 secondes" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Logs des nœuds:" | tee -a "$LOG_FILE"
    for node_name in db-master-01 db-slave-01 db-slave-02; do
        node_ip="${NODE_IPS[$node_name]}"
        echo "" | tee -a "$LOG_FILE"
        echo "=== $node_name ===" | tee -a "$LOG_FILE"
        ssh -o StrictHostKeyChecking=no root@"$node_ip" "docker logs patroni 2>&1 | tail -30" | tee -a "$LOG_FILE"
    done
    exit 1
fi

echo "" | tee -a "$LOG_FILE"
echo "═══ 5. Création des bases et utilisateurs ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Créer les bases et users sur le leader
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" <<'SETUP_DBS'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Créer les utilisateurs applicatifs
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'n8n') THEN
        CREATE USER n8n WITH PASSWORD '${PG_PASSWORD}';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'chatwoot') THEN
        CREATE USER chatwoot WITH PASSWORD '${PG_PASSWORD}';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'pgbouncer') THEN
        CREATE USER pgbouncer WITH PASSWORD '${PG_PASSWORD}';
    END IF;
END
\$\$;

-- Créer les bases
SELECT 'CREATE DATABASE keybuzz' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keybuzz')\gexec
SELECT 'CREATE DATABASE n8n OWNER n8n' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec
SELECT 'CREATE DATABASE chatwoot OWNER chatwoot' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot')\gexec

-- Extensions sur keybuzz
\c keybuzz
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Extensions sur n8n
\c n8n
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Extensions sur chatwoot
\c chatwoot
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Permissions
\c postgres
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
SQL

if [ $? -eq 0 ]; then
    echo "  ✓ Bases et utilisateurs créés"
else
    echo "  ✗ Échec création bases"
    exit 1
fi
SETUP_DBS

[ $? -eq 0 ] && echo -e "  $OK" | tee -a "$LOG_FILE" || { echo -e "  $KO" | tee -a "$LOG_FILE"; exit 1; }

echo "" | tee -a "$LOG_FILE"
echo "═══ 6. Vérification finale du cluster ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

SUCCESS=0
for node_name in db-master-01 db-slave-01 db-slave-02; do
    node_ip="${NODE_IPS[$node_name]}"
    echo -n "  $node_name ($node_ip): " | tee -a "$LOG_FILE"
    
    # Test conteneur
    if ! ssh -o StrictHostKeyChecking=no root@"$node_ip" "docker ps | grep -q patroni"; then
        echo -e "$KO conteneur arrêté" | tee -a "$LOG_FILE"
        continue
    fi
    
    # Test connexion
    if ssh -o StrictHostKeyChecking=no root@"$node_ip" \
        "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
        
        # Vérifier le rôle
        IS_LEADER=$(ssh -o StrictHostKeyChecking=no root@"$node_ip" \
            "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
        
        if [ "$IS_LEADER" = "f" ]; then
            echo -e "$OK Leader" | tee -a "$LOG_FILE"
        else
            echo -e "$OK Replica" | tee -a "$LOG_FILE"
        fi
        ((SUCCESS++))
    else
        echo -e "$KO Non prêt" | tee -a "$LOG_FILE"
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"

if [ $SUCCESS -eq 3 ]; then
    echo -e "$OK CLUSTER PATRONI RAFT OPÉRATIONNEL ($SUCCESS/3 nœuds)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Leader: $LEADER_NAME ($LEADER_IP)" | tee -a "$LOG_FILE"
    echo "Credentials: $CREDS_DIR/postgres.env" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Test connexion:" | tee -a "$LOG_FILE"
    echo "  export PGPASSWORD='$POSTGRES_PASSWORD'" | tee -a "$LOG_FILE"
    echo "  psql -h ${LEADER_IP} -U postgres -d keybuzz -c 'SELECT version()'" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "API Patroni (vérifier le cluster):" | tee -a "$LOG_FILE"
    echo "  curl -s http://${LEADER_IP}:8008/cluster | jq" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Prochaine étape: ./05_haproxy_db_CORRECTED.sh" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    echo "OK" > /opt/keybuzz/postgres/status/STATE
    
    tail -n 50 "$LOG_FILE"
    exit 0
else
    echo -e "$KO CLUSTER NON OPÉRATIONNEL ($SUCCESS/3 nœuds)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    echo "KO" > /opt/keybuzz/postgres/status/STATE
    
    tail -n 50 "$LOG_FILE"
    exit 1
fi
