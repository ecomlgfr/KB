#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      PATRONI NODE DEPLOY - CONSUL DCS (PostgreSQL 16 HA)          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"

mkdir -p "$CREDS_DIR" "$LOG_DIR"
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

echo "Collecte IPs Consul..."
CONSUL_IP1=$(awk -F'\t' '$2=="db-master-01" {print $3; exit}' "$SERVERS_TSV")
CONSUL_IP2=$(awk -F'\t' '$2=="db-slave-01" {print $3; exit}' "$SERVERS_TSV")
CONSUL_IP3=$(awk -F'\t' '$2=="db-slave-02" {print $3; exit}' "$SERVERS_TSV")

echo "  consul: $CONSUL_IP1:8500"

SECRETS_FILE="$CREDS_DIR/secrets.json"
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Génération secrets..."
    POSTGRES_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    REPLICATOR_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    
    cat > "$SECRETS_FILE" <<JSON
{
  "postgres_password": "$POSTGRES_PASS",
  "replicator_password": "$REPLICATOR_PASS"
}
JSON
    chmod 600 "$SECRETS_FILE"
else
    echo "Lecture secrets existants..."
fi

POSTGRES_PASS=$(jq -r '.postgres_password' "$SECRETS_FILE")
REPLICATOR_PASS=$(jq -r '.replicator_password' "$SECRETS_FILE")

echo "Déploiement Patroni sur $HOST ($IP_PRIVEE)..."

# Tuning basique
RAM_MB=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIVEE" "free -m | awk '/^Mem:/ {print \$2}'")
CPU_COUNT=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIVEE" "nproc")

SHARED_BUFFERS=$((RAM_MB / 4))
EFFECTIVE_CACHE=$((RAM_MB * 3 / 4))
WORK_MEM=$((RAM_MB / CPU_COUNT / 4))

echo "Tuning PostgreSQL pour $((RAM_MB/1024)) GB RAM, $CPU_COUNT CPU:"
echo "  shared_buffers: ${SHARED_BUFFERS}MB"
echo "  effective_cache_size: ${EFFECTIVE_CACHE}MB"
echo "  work_mem: ${WORK_MEM}MB"

ssh -o StrictHostKeyChecking=no root@"$IP_PRIVEE" "bash -s $HOST $IP_PRIVEE $CONSUL_IP1 $SHARED_BUFFERS $EFFECTIVE_CACHE $WORK_MEM $POSTGRES_PASS $REPLICATOR_PASS" <<'REMOTE_SCRIPT'
set -e

# Variables passées en arguments
HOST="$1"
IP_PRIVEE="$2"
CONSUL_IP1="$3"
SHARED_BUFFERS="$4"
EFFECTIVE_CACHE="$5"
WORK_MEM="$6"
POSTGRES_PASS="$7"
REPLICATOR_PASS="$8"

BASE="/opt/keybuzz/postgres"
CFG="${BASE}/config"
DATA="${BASE}/data"
LOGS="${BASE}/logs"
ST="${BASE}/status"

mkdir -p "${CFG}" "${DATA}" "${LOGS}" "${ST}"

# Dockerfile Patroni
cat > "${CFG}/Dockerfile" <<'DOCKERFILE'
FROM postgres:16-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-psycopg2 \
    curl jq \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages \
    patroni[consul]==3.3.2 \
    psycopg2-binary

RUN mkdir -p /var/lib/postgresql/data /var/run/postgresql /logs && \
    chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql /logs

USER postgres
WORKDIR /var/lib/postgresql
CMD ["/usr/local/bin/patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

# patroni.yml
cat > "${CFG}/patroni.yml" <<PATRONICFG
scope: pg-cluster
name: ${HOST}
namespace: /db/

restapi:
  listen: ${IP_PRIVEE}:8008
  connect_address: ${IP_PRIVEE}:8008

consul:
  host: ${CONSUL_IP1}:8500

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
        shared_buffers: ${SHARED_BUFFERS}MB
        effective_cache_size: ${EFFECTIVE_CACHE}MB
        work_mem: ${WORK_MEM}MB
        maintenance_work_mem: 256MB
        max_connections: 100
        
  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    - data-checksums
    
  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 10.0.0.0/16 md5
    
  users:
    postgres:
      password: '${POSTGRES_PASS}'
      options:
        - createrole
        - createdb
    replicator:
      password: '${REPLICATOR_PASS}'
      options:
        - replication

postgresql:
  listen: ${IP_PRIVEE}:5432
  connect_address: ${IP_PRIVEE}:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    replication:
      username: replicator
      password: '${REPLICATOR_PASS}'
    superuser:
      username: postgres
      password: '${POSTGRES_PASS}'
PATRONICFG

# docker-compose.yml
cat > "${CFG}/docker-compose.yml" <<COMPOSECFG
services:
  patroni:
    image: patroni-pg16:local
    container_name: patroni
    hostname: ${HOST}
    restart: unless-stopped
    network_mode: host
    volumes:
      - \${PWD}/patroni.yml:/etc/patroni/patroni.yml:ro
      - ${DATA}:/var/lib/postgresql/data
      - ${LOGS}:/logs
    environment:
      - PATRONI_NAME=${HOST}
      - PATRONI_SCOPE=pg-cluster
    healthcheck:
      test: ["CMD", "curl", "-f", "http://${IP_PRIVEE}:8008/health"]
      interval: 10s
      timeout: 5s
      retries: 5
COMPOSECFG

# Build
echo "Build image..."
docker rmi -f patroni-pg16:local 2>/dev/null || true
cd "${CFG}"
if ! docker build --no-cache -t patroni-pg16:local -f Dockerfile . 2>&1 | tail -5; then
    echo "ERREUR BUILD"
    exit 1
fi

# Start
echo "Démarrage Patroni..."
cd "${CFG}"
docker compose down 2>/dev/null || true
docker compose up -d

echo "OK"
REMOTE_SCRIPT

if [[ $? -ne 0 ]]; then
    echo -e "$KO Échec déploiement"
    exit 1
fi

echo "Attente santé Patroni (max 60s)..."
for i in {1..12}; do
    sleep 5
    if curl -sf "http://$IP_PRIVEE:8008/health" >/dev/null 2>&1; then
        echo -e "$OK $HOST Patroni healthy"
        exit 0
    fi
    echo -n "."
done

echo
echo -e "$KO Timeout health check"
ssh -o StrictHostKeyChecking=no root@"$IP_PRIVEE" "docker logs patroni 2>&1 | tail -20"
exit 1
