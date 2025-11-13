#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          PATRONI NODE DEPLOY (PostgreSQL 16 HA Manager)           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
CREDS_DIR="/opt/keybuzz-installer/credentials"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR" "$CREDS_DIR"
chmod 700 "$CREDS_DIR"

usage() {
    echo "Usage: $0 --host <hostname>"
    echo "Exemple: $0 --host db-master-01"
    exit 1
}

HOST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$HOST" ]] && usage
[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_PRIVEE=$(awk -F'\t' -v h="$HOST" '$2==h {print $3; exit}' "$SERVERS_TSV")
[[ -z "$IP_PRIVEE" ]] && { echo -e "$KO IP introuvable pour $HOST"; exit 1; }

echo "Collecte des IPs depuis servers.tsv..."

ETCD_HOSTS=""
for master in k3s-master-01 k3s-master-02 k3s-master-03; do
    etcd_ip=$(awk -F'\t' -v h="$master" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$etcd_ip" ]] && { echo -e "$KO IP etcd introuvable pour $master"; exit 1; }
    [[ -n "$ETCD_HOSTS" ]] && ETCD_HOSTS="${ETCD_HOSTS},"
    ETCD_HOSTS="${ETCD_HOSTS}${etcd_ip}:2379"
done

echo "  etcd hosts: $ETCD_HOSTS"

declare -A PG_NODES
for node in db-master-01 db-slave-01 db-slave-02; do
    pg_ip=$(awk -F'\t' -v h="$node" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$pg_ip" ]] && { echo -e "$KO IP PG introuvable pour $node"; exit 1; }
    PG_NODES[$node]="$pg_ip"
    echo "  $node: $pg_ip"
done
echo

SECRETS_FILE="$CREDS_DIR/secrets.json"
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Génération secrets PostgreSQL..."
    POSTGRES_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    REPLICATOR_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    
    cat > "$SECRETS_FILE" <<JSON
{
  "postgres_password": "$POSTGRES_PASS",
  "replicator_password": "$REPLICATOR_PASS",
  "generated_at": "$(date -Iseconds)"
}
JSON
    chmod 600 "$SECRETS_FILE"
    echo -e "$OK Secrets générés"
else
    echo "Lecture secrets existants..."
fi

POSTGRES_PASS=$(jq -r '.postgres_password' "$SECRETS_FILE")
REPLICATOR_PASS=$(jq -r '.replicator_password' "$SECRETS_FILE")

echo "Déploiement Patroni sur $HOST ($IP_PRIVEE)..."
echo

LOGFILE="$LOG_DIR/patroni_node_${HOST}_${TIMESTAMP}.log"

ssh -o StrictHostKeyChecking=no root@"$IP_PRIVEE" "bash -s" <<EOSSH 2>&1 | tee "$LOGFILE"
set -u
set -o pipefail

BASE="/opt/keybuzz/postgres"
DATA="\${BASE}/data"
CFG="\${BASE}/config"
LOGS="\${BASE}/logs"
ST="\${BASE}/status"

if [[ ! -f /opt/keybuzz-installer/inventory/servers.tsv ]]; then
    echo "Copie servers.tsv en local..."
    mkdir -p /opt/keybuzz-installer/inventory
    cat > /opt/keybuzz-installer/inventory/servers.tsv <<'TSV'
$(cat "$SERVERS_TSV")
TSV
fi

TOTAL_RAM=\$(free -g | awk '/^Mem:/ {print \$2}')
TOTAL_CPU=\$(nproc)

[[ \$TOTAL_RAM -lt 1 ]] && TOTAL_RAM=1

SHARED_BUFFERS=\$((TOTAL_RAM * 256))MB
EFFECTIVE_CACHE=\$((TOTAL_RAM * 768))MB
WORK_MEM=\$((TOTAL_RAM * 16 / TOTAL_CPU))MB
MAINT_WORK_MEM=\$((TOTAL_RAM * 64))MB

[[ \$TOTAL_CPU -ge 8 ]] && MAX_CONN=200 || MAX_CONN=100
MAX_WORKER=\$TOTAL_CPU
MAX_PARALLEL_WORKER=\$((TOTAL_CPU / 2))
[[ \$MAX_PARALLEL_WORKER -lt 2 ]] && MAX_PARALLEL_WORKER=2

echo "Tuning PostgreSQL pour \$TOTAL_RAM GB RAM, \$TOTAL_CPU CPU:"
echo "  shared_buffers: \$SHARED_BUFFERS"
echo "  effective_cache_size: \$EFFECTIVE_CACHE"
echo "  work_mem: \$WORK_MEM"
echo "  max_connections: \$MAX_CONN"
echo

cat > "\$CFG/patroni.yml" <<PATRONI
scope: keybuzz-db
name: $HOST
namespace: /db/

restapi:
  listen: $IP_PRIVEE:8008
  connect_address: $IP_PRIVEE:8008

etcd:
  hosts: $ETCD_HOSTS

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
        wal_level: replica
        hot_standby: on
        max_wal_senders: 20
        max_replication_slots: 20
        wal_keep_size: 1GB
        wal_log_hints: on
        archive_mode: on
        archive_command: /bin/true
        shared_buffers: \$SHARED_BUFFERS
        effective_cache_size: \$EFFECTIVE_CACHE
        work_mem: \$WORK_MEM
        maintenance_work_mem: \$MAINT_WORK_MEM
        max_connections: \$MAX_CONN
        max_worker_processes: \$MAX_WORKER
        max_parallel_workers_per_gather: \$MAX_PARALLEL_WORKER
        max_parallel_workers: \$MAX_WORKER
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        min_wal_size: 1GB
        max_wal_size: 4GB
        max_locks_per_transaction: 64
        
  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    - data-checksums
    
  pg_hba:
    - host replication replicator 10.0.0.0/16 md5
    - host all all 10.0.0.0/16 md5
    - host all all 127.0.0.1/32 md5
    
  users:
    admin:
      password: $POSTGRES_PASS
      options:
        - createrole
        - createdb
    replicator:
      password: $REPLICATOR_PASS
      options:
        - replication

postgresql:
  listen: $IP_PRIVEE:5432
  connect_address: $IP_PRIVEE:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    replication:
      username: replicator
      password: $REPLICATOR_PASS
    superuser:
      username: postgres
      password: $POSTGRES_PASS
  parameters:
    unix_socket_directories: /var/run/postgresql
    
tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
PATRONI

cat > "\$CFG/.env" <<ENV
POSTGRES_PASSWORD=$POSTGRES_PASS
REPLICATOR_PASSWORD=$REPLICATOR_PASS
ENV
chmod 600 "\$CFG/.env"

echo "Préparation Dockerfile Patroni..."

# Supprimer l'ancienne image si elle existe
docker rmi -f patroni-pg16:local 2>/dev/null || true

cat > "\$CFG/Dockerfile" <<'DOCKERFILE'
FROM postgres:16-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-etcd \
    python3-psycopg2 \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages \
    patroni==3.3.2 \
    psycopg2-binary

RUN mkdir -p /var/lib/postgresql/data /var/run/postgresql /logs && \
    chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql /logs

USER postgres
WORKDIR /var/lib/postgresql
CMD ["/usr/local/bin/patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

echo "Build image Patroni locale..."
cd "\$CFG"
if ! docker build --no-cache -t patroni-pg16:local -f Dockerfile . 2>&1 | tail -5; then
    echo "ERREUR: Build image failed"
    exit 1
fi
echo "Image patroni-pg16:local construite"

cat > "\$CFG/docker-compose.yml" <<COMPOSE
services:
  patroni:
    image: patroni-pg16:local
    container_name: patroni
    restart: unless-stopped
    network_mode: host
    environment:
      - PATRONI_SCOPE=keybuzz-db
      - PATRONI_NAME=$HOST
      - PATRONI_RESTAPI_LISTEN=$IP_PRIVEE:8008
      - PATRONI_RESTAPI_CONNECT_ADDRESS=$IP_PRIVEE:8008
      - PATRONI_POSTGRESQL_LISTEN=$IP_PRIVEE:5432
      - PATRONI_POSTGRESQL_CONNECT_ADDRESS=$IP_PRIVEE:5432
      - PATRONI_POSTGRESQL_DATA_DIR=/var/lib/postgresql/data
      - PATRONI_ETCD_HOSTS=$ETCD_HOSTS
      - PATRONI_POSTGRESQL_PGPASS=/tmp/pgpass
    volumes:
      - /opt/keybuzz/postgres/data:/var/lib/postgresql/data
      - /opt/keybuzz/postgres/config/patroni.yml:/etc/patroni/patroni.yml:ro
      - /opt/keybuzz/postgres/logs:/logs
    command: /usr/local/bin/patroni /etc/patroni/patroni.yml
    logging:
      driver: json-file
      options:
        max-size: 50m
        max-file: "3"
COMPOSE

cd "\$CFG"

if docker compose ps 2>/dev/null | grep -q patroni; then
    echo "Arrêt Patroni existant..."
    docker compose down
    sleep 3
fi

echo "Démarrage Patroni..."
docker compose up -d

sleep 10

echo "Vérification santé Patroni..."
for i in {1..30}; do
    if curl -sf http://$IP_PRIVEE:8008/health 2>/dev/null | grep -q "true"; then
        echo "Patroni healthy"
        
        ROLE=\$(curl -sf http://$IP_PRIVEE:8008 2>/dev/null | jq -r '.role' 2>/dev/null)
        echo "Rôle actuel: \$ROLE"
        
        echo "OK" > "\$ST/STATE"
        echo "Patroni déployé avec succès sur $HOST"
        exit 0
    fi
    
    [[ \$((i % 5)) -eq 0 ]] && echo "Attente health check... (\$i/30)"
    sleep 2
done

echo "ERREUR: Timeout health check Patroni"
docker compose logs --tail=50 patroni
echo "KO" > "\$ST/STATE"
exit 1
EOSSH

STATUS=$?

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "Logs (tail -50) pour $HOST:"
tail -n 50 "$LOGFILE"
echo "═══════════════════════════════════════════════════════════════════"
echo

if [[ $STATUS -eq 0 ]]; then
    echo -e "$OK Patroni déployé sur $HOST"
    
    sleep 3
    echo
    echo "Vérification REST API:"
    HEALTH=$(curl -sf "http://$IP_PRIVEE:8008/health" 2>/dev/null)
    if [[ "$HEALTH" == *"true"* ]]; then
        echo -e "$OK Health check OK"
        
        ROLE=$(curl -sf "http://$IP_PRIVEE:8008" 2>/dev/null | jq -r '.role' 2>/dev/null)
        echo "  Rôle: $ROLE"
    else
        echo -e "$KO Health check failed"
    fi
    
    exit 0
else
    echo -e "$KO Échec déploiement Patroni sur $HOST"
    exit 1
fi
