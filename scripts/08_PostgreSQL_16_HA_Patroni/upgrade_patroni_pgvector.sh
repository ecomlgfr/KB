#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    UPGRADE_PATRONI_PGVECTOR - Ajout pgvector + Tuning Dynamique    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)
PG_VERSION="17"
PATRONI_VERSION="3.3.2"
PGVECTOR_VERSION="0.7.4"

# Charger credentials
source /opt/keybuzz-installer/credentials/postgres.env
source /opt/keybuzz-installer/credentials/etcd_endpoints.txt

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo ""
echo "1. Analyse des ressources pour tuning dynamique..."
echo ""

# Fonction pour analyser et calculer les paramètres
get_tuned_params() {
    local ip="$1"
    local node="$2"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'ANALYZE'
# Détection CPU et RAM
CPU_COUNT=$(nproc)
RAM_MB=$(free -m | grep "^Mem:" | awk '{print $2}')
RAM_GB=$((RAM_MB / 1024))

# Calculs PostgreSQL optimaux
# shared_buffers = 25% RAM (min 128MB, max 40% RAM pour gros serveurs)
SHARED_BUFFERS=$((RAM_MB / 4))
[ $SHARED_BUFFERS -lt 128 ] && SHARED_BUFFERS=128
[ $SHARED_BUFFERS -gt $((RAM_MB * 2 / 5)) ] && SHARED_BUFFERS=$((RAM_MB * 2 / 5))

# effective_cache_size = 75% RAM
EFFECTIVE_CACHE=$((RAM_MB * 3 / 4))

# work_mem = RAM / (max_connections * 3) avec min 4MB
MAX_CONNECTIONS=$((CPU_COUNT * 50))
[ $MAX_CONNECTIONS -lt 100 ] && MAX_CONNECTIONS=100
[ $MAX_CONNECTIONS -gt 500 ] && MAX_CONNECTIONS=500
WORK_MEM=$((RAM_MB / (MAX_CONNECTIONS * 3)))
[ $WORK_MEM -lt 4 ] && WORK_MEM=4
[ $WORK_MEM -gt 128 ] && WORK_MEM=128

# maintenance_work_mem = RAM/16 (min 64MB, max 2GB)
MAINTENANCE_MEM=$((RAM_MB / 16))
[ $MAINTENANCE_MEM -lt 64 ] && MAINTENANCE_MEM=64
[ $MAINTENANCE_MEM -gt 2048 ] && MAINTENANCE_MEM=2048

# wal_buffers = shared_buffers/32 (min 64kB, max 16MB)
WAL_BUFFERS=$((SHARED_BUFFERS / 32))
[ $WAL_BUFFERS -lt 1 ] && WAL_BUFFERS=1
[ $WAL_BUFFERS -gt 16 ] && WAL_BUFFERS=16

# Workers basés sur CPU
MAX_WORKER=$CPU_COUNT
MAX_PARALLEL_WORKERS=$CPU_COUNT
MAX_PARALLEL_WORKERS_GATHER=$((CPU_COUNT / 2))
[ $MAX_PARALLEL_WORKERS_GATHER -lt 2 ] && MAX_PARALLEL_WORKERS_GATHER=2
MAX_PARALLEL_MAINTENANCE=$((CPU_COUNT / 2))
[ $MAX_PARALLEL_MAINTENANCE -lt 1 ] && MAX_PARALLEL_MAINTENANCE=1

# effective_io_concurrency selon le type de disque (SSD = 200, HDD = 2)
# On assume SSD sur Hetzner Cloud
EFFECTIVE_IO=200

# random_page_cost pour SSD
RANDOM_PAGE_COST="1.1"

# Autovacuum workers
AUTOVACUUM_WORKERS=$((CPU_COUNT / 2))
[ $AUTOVACUUM_WORKERS -lt 3 ] && AUTOVACUUM_WORKERS=3
[ $AUTOVACUUM_WORKERS -gt 10 ] && AUTOVACUUM_WORKERS=10

echo "CPU:$CPU_COUNT"
echo "RAM_MB:$RAM_MB"
echo "SHARED_BUFFERS:$SHARED_BUFFERS"
echo "EFFECTIVE_CACHE:$EFFECTIVE_CACHE"
echo "WORK_MEM:$WORK_MEM"
echo "MAINTENANCE_MEM:$MAINTENANCE_MEM"
echo "MAX_CONNECTIONS:$MAX_CONNECTIONS"
echo "WAL_BUFFERS:$WAL_BUFFERS"
echo "MAX_WORKER:$MAX_WORKER"
echo "MAX_PARALLEL_WORKERS:$MAX_PARALLEL_WORKERS"
echo "MAX_PARALLEL_WORKERS_GATHER:$MAX_PARALLEL_WORKERS_GATHER"
echo "MAX_PARALLEL_MAINTENANCE:$MAX_PARALLEL_MAINTENANCE"
echo "EFFECTIVE_IO:$EFFECTIVE_IO"
echo "RANDOM_PAGE_COST:$RANDOM_PAGE_COST"
echo "AUTOVACUUM_WORKERS:$AUTOVACUUM_WORKERS"
ANALYZE
}

# Stocker les paramètres pour chaque nœud
declare -A NODE_PARAMS

for node in "${DB_NODES[@]}"; do
    echo "  Analyse $node..."
    params=$(get_tuned_params "${NODE_IPS[$node]}" "$node")
    NODE_PARAMS[$node]="$params"
    
    CPU=$(echo "$params" | grep "^CPU:" | cut -d: -f2)
    RAM_MB=$(echo "$params" | grep "^RAM_MB:" | cut -d: -f2)
    RAM_GB=$((RAM_MB / 1024))
    
    echo "    $node: ${CPU} CPU, ${RAM_GB}GB RAM"
done

echo ""
echo "2. Construction nouvelle image avec pgvector..."

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    params="${NODE_PARAMS[$node]}"
    
    # Extraire les valeurs
    SHARED_BUFFERS=$(echo "$params" | grep "^SHARED_BUFFERS:" | cut -d: -f2)
    EFFECTIVE_CACHE=$(echo "$params" | grep "^EFFECTIVE_CACHE:" | cut -d: -f2)
    WORK_MEM=$(echo "$params" | grep "^WORK_MEM:" | cut -d: -f2)
    MAINTENANCE_MEM=$(echo "$params" | grep "^MAINTENANCE_MEM:" | cut -d: -f2)
    MAX_CONNECTIONS=$(echo "$params" | grep "^MAX_CONNECTIONS:" | cut -d: -f2)
    WAL_BUFFERS=$(echo "$params" | grep "^WAL_BUFFERS:" | cut -d: -f2)
    MAX_WORKER=$(echo "$params" | grep "^MAX_WORKER:" | cut -d: -f2)
    MAX_PARALLEL_WORKERS=$(echo "$params" | grep "^MAX_PARALLEL_WORKERS:" | cut -d: -f2)
    MAX_PARALLEL_WORKERS_GATHER=$(echo "$params" | grep "^MAX_PARALLEL_WORKERS_GATHER:" | cut -d: -f2)
    MAX_PARALLEL_MAINTENANCE=$(echo "$params" | grep "^MAX_PARALLEL_MAINTENANCE:" | cut -d: -f2)
    EFFECTIVE_IO=$(echo "$params" | grep "^EFFECTIVE_IO:" | cut -d: -f2)
    RANDOM_PAGE_COST=$(echo "$params" | grep "^RANDOM_PAGE_COST:" | cut -d: -f2)
    AUTOVACUUM_WORKERS=$(echo "$params" | grep "^AUTOVACUUM_WORKERS:" | cut -d: -f2)
    
    echo ""
    echo "  Configuration $node avec tuning optimal..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$ip" "$POSTGRES_PASSWORD" "$ETCD_HOSTS" \
        "$PG_VERSION" "$PATRONI_VERSION" "$PGVECTOR_VERSION" \
        "$SHARED_BUFFERS" "$EFFECTIVE_CACHE" "$WORK_MEM" "$MAINTENANCE_MEM" \
        "$MAX_CONNECTIONS" "$WAL_BUFFERS" "$MAX_WORKER" "$MAX_PARALLEL_WORKERS" \
        "$MAX_PARALLEL_WORKERS_GATHER" "$MAX_PARALLEL_MAINTENANCE" \
        "$EFFECTIVE_IO" "$RANDOM_PAGE_COST" "$AUTOVACUUM_WORKERS" <<'UPGRADE'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
ETCD_HOSTS="$4"
PG_VERSION="$5"
PATRONI_VERSION="$6"
PGVECTOR_VERSION="$7"
SHARED_BUFFERS="${8}MB"
EFFECTIVE_CACHE="${9}MB"
WORK_MEM="${10}MB"
MAINTENANCE_MEM="${11}MB"
MAX_CONNECTIONS="${12}"
WAL_BUFFERS="${13}MB"
MAX_WORKER="${14}"
MAX_PARALLEL_WORKERS="${15}"
MAX_PARALLEL_WORKERS_GATHER="${16}"
MAX_PARALLEL_MAINTENANCE="${17}"
EFFECTIVE_IO="${18}"
RANDOM_PAGE_COST="${19}"
AUTOVACUUM_WORKERS="${20}"

# Nouvelle configuration Patroni avec tuning complet
cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: $NODE_NAME

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008
  authentication:
    username: patroni
    password: '$PG_PASSWORD'

etcd3:
  hosts: $(echo $ETCD_HOSTS | sed 's/,/, /g')

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    master_start_timeout: 300
    synchronous_mode: true
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        # MÉMOIRE - Tuning dynamique
        shared_buffers: $SHARED_BUFFERS
        effective_cache_size: $EFFECTIVE_CACHE
        work_mem: $WORK_MEM
        maintenance_work_mem: $MAINTENANCE_MEM
        wal_buffers: $WAL_BUFFERS
        
        # CONNEXIONS
        max_connections: $MAX_CONNECTIONS
        superuser_reserved_connections: 5
        
        # PARALLÉLISATION - Adapté aux CPUs
        max_worker_processes: $MAX_WORKER
        max_parallel_workers: $MAX_PARALLEL_WORKERS
        max_parallel_workers_per_gather: $MAX_PARALLEL_WORKERS_GATHER
        max_parallel_maintenance_workers: $MAX_PARALLEL_MAINTENANCE
        
        # RÉPLICATION
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 2GB
        hot_standby: 'on'
        wal_log_hints: 'on'
        
        # ARCHIVES & CHECKPOINTS
        archive_mode: 'on'
        archive_command: '/usr/bin/pgbackrest --stanza=keybuzz archive-push %p'
        archive_timeout: 60
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        max_wal_size: 2GB
        min_wal_size: 512MB
        
        # PERFORMANCES I/O
        effective_io_concurrency: $EFFECTIVE_IO
        random_page_cost: $RANDOM_PAGE_COST
        seq_page_cost: 1.0
        
        # STATISTIQUES
        default_statistics_target: 100
        track_activities: 'on'
        track_counts: 'on'
        track_io_timing: 'on'
        
        # AUTOVACUUM - Adapté à la charge
        autovacuum: 'on'
        autovacuum_max_workers: $AUTOVACUUM_WORKERS
        autovacuum_naptime: 30s
        autovacuum_vacuum_scale_factor: 0.1
        autovacuum_analyze_scale_factor: 0.05
        
        # LOGS
        logging_collector: 'on'
        log_directory: '/var/lib/postgresql/data/log'
        log_filename: 'postgresql-%Y-%m-%d.log'
        log_rotation_age: 1d
        log_rotation_size: 100MB
        log_line_prefix: '%t [%p] %q%u@%d '
        log_checkpoints: 'on'
        log_connections: 'off'
        log_disconnections: 'off'
        log_lock_waits: 'on'
        log_temp_files: 0
        log_autovacuum_min_duration: 0
        log_min_duration_statement: 100
        log_statement: 'ddl'
        
        # PGVECTOR
        shared_preload_libraries: 'pg_stat_statements,pgvector'
        pg_stat_statements.track: all
        pg_stat_statements.max: 10000

  initdb:
    - encoding: UTF8
    - locale: en_US.UTF-8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all 10.0.0.0/16 scram-sha-256
    - host replication replicator 10.0.0.0/16 scram-sha-256

  users:
    postgres:
      password: '$PG_PASSWORD'
      options:
        - superuser
    replicator:
      password: '$PG_PASSWORD'
      options:
        - replication

postgresql:
  listen: '*:5432'
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/data
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
      password: '$PG_PASSWORD'
  create_replica_methods:
    - basebackup
    - pgbackrest
  basebackup:
    max-rate: 100M
    checkpoint: fast
  pgbackrest:
    command: /usr/bin/pgbackrest --stanza=keybuzz --type=full restore

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

# Dockerfile avec pgvector et pgBackRest
cat > /opt/keybuzz/patroni/Dockerfile <<DOCKERFILE
FROM postgres:${PG_VERSION}

# Variables de build
ENV PGVECTOR_VERSION=${PGVECTOR_VERSION}

# Installation des dépendances et outils
RUN apt-get update && apt-get install -y \\
    build-essential \\
    postgresql-server-dev-\${PG_MAJOR} \\
    git \\
    curl \\
    python3-pip \\
    python3-psycopg2 \\
    pgbackrest \\
    && rm -rf /var/lib/apt/lists/*

# Installation de pgvector
RUN cd /tmp \\
    && git clone --branch v\${PGVECTOR_VERSION} https://github.com/pgvector/pgvector.git \\
    && cd pgvector \\
    && make \\
    && make install \\
    && cd / \\
    && rm -rf /tmp/pgvector

# Installation de Patroni
RUN pip3 install --break-system-packages \\
    patroni[etcd3]==${PATRONI_VERSION} \\
    python-etcd \\
    psycopg2-binary

# Configuration pgBackRest
RUN mkdir -p /etc/pgbackrest \\
    && mkdir -p /var/lib/pgbackrest \\
    && mkdir -p /var/log/pgbackrest \\
    && chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest

# Copie des configurations
COPY config/patroni.yml /etc/patroni/patroni.yml

EXPOSE 5432 8008

USER postgres

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

# Build l'image
cd /opt/keybuzz/patroni
docker build -t patroni-pg${PG_VERSION}-vector:latest . >/dev/null 2>&1

echo "    ✓ Image construite avec pgvector"
UPGRADE
done

echo ""
echo "3. Redémarrage progressif du cluster..."

# Identifier le leader actuel
LEADER=$(curl -s -u patroni:$POSTGRES_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" | \
    jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null)

[ -z "$LEADER" ] && LEADER="db-master-01"

echo "  Leader actuel: $LEADER"

# Redémarrer d'abord les replicas
for node in "${DB_NODES[@]}"; do
    [ "$node" = "$LEADER" ] && continue
    
    echo "  Redémarrage $node..."
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" bash <<'RESTART'
docker stop patroni
docker rm patroni

docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  -v /var/lib/pgbackrest:/var/lib/pgbackrest \
  -v /var/log/pgbackrest:/var/log/pgbackrest \
  patroni-pg17-vector:latest

sleep 20
RESTART
done

# Switchover puis restart du leader
echo "  Switchover du leader..."
NEW_LEADER="db-slave-01"
curl -u patroni:$POSTGRES_PASSWORD -X POST "http://${NODE_IPS[$LEADER]}:8008/switchover" \
  -H 'Content-Type: application/json' \
  -d "{\"leader\":\"$LEADER\",\"candidate\":\"$NEW_LEADER\"}" 2>/dev/null

sleep 20

echo "  Redémarrage ancien leader $LEADER..."
ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$LEADER]}" bash <<'RESTART_LEADER'
docker stop patroni
docker rm patroni

docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  -v /var/lib/pgbackrest:/var/lib/pgbackrest \
  -v /var/log/pgbackrest:/var/log/pgbackrest \
  patroni-pg17-vector:latest
RESTART_LEADER

sleep 30

echo ""
echo "4. Installation de l'extension pgvector..."

# Installer pgvector sur le nouveau leader
ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$NEW_LEADER]}" \
  "docker exec patroni psql -U postgres -d postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;'"

echo ""
echo "5. Vérification finale..."

# État du cluster
curl -s -u patroni:$POSTGRES_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" | jq

# Test pgvector
echo ""
echo "Test pgvector:"
ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$NEW_LEADER]}" \
  "docker exec patroni psql -U postgres -d postgres -c \"
    CREATE TABLE IF NOT EXISTS test_vector (id serial, embedding vector(3));
    INSERT INTO test_vector (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');
    SELECT * FROM test_vector ORDER BY embedding <-> '[3,1,2]' LIMIT 1;
  \""

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK UPGRADE COMPLET: pgvector + Tuning Dynamique"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Nouvelles fonctionnalités:"
echo "  • pgvector $PGVECTOR_VERSION installé"
echo "  • Tuning dynamique adapté à chaque serveur"
echo "  • pgBackRest prêt (config à finaliser)"
echo ""
echo "Prochaine étape: ./configure_pgbackrest.sh"
