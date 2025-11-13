#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   08_POSTGRES_TO_PATRONI_RAFT - Cluster HA avec DCS Raft         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)
PG_VERSION="17"
PATRONI_VERSION="3.3.2"

# Option pour forcer le formatage des volumes
FORCE_FORMAT="${1:-no}"
if [ "$FORCE_FORMAT" = "--force-format" ]; then
    echo -e "${WARN} Mode FORCE FORMAT activé - Les volumes seront formatés"
    read -p "Confirmer le formatage des volumes? (yes/NO): " confirm
    [ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }
fi

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    source /opt/keybuzz-installer/credentials/postgres.env
else
    echo -e "$KO Credentials postgres.env introuvables"
    exit 1
fi

echo ""
echo "═══ Migration PostgreSQL → Patroni Cluster HA (Raft DCS) ═══"
echo ""
echo "Architecture: Patroni avec Raft intégré (pas d'etcd externe)"
echo "Port Raft: 7000/tcp"
echo ""

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -z "$ip" ]; then
        echo -e "$KO IP introuvable pour $node"
        exit 1
    fi
    NODE_IPS[$node]=$ip
done

echo "Nœuds PostgreSQL:"
for node in "${DB_NODES[@]}"; do
    echo "  $node: ${NODE_IPS[$node]}"
done
echo ""

# Fonction pour obtenir les specs du serveur
get_server_specs() {
    local ip="$1"
    local node="$2"
    
    echo "  Analyse $node ($ip)..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'SPECS'
# CPU
CPU_COUNT=$(nproc)
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)

# RAM en GB
RAM_GB=$(free -g | grep "^Mem:" | awk '{print $2}')
RAM_MB=$(free -m | grep "^Mem:" | awk '{print $2}')

# Disque du volume
VOLUME_SIZE=0
VOLUME_PATH="/opt/keybuzz/postgres/data"

# Détecter le device monté ou disponible
if mountpoint -q "$VOLUME_PATH" 2>/dev/null; then
    DEVICE=$(findmnt -n -o SOURCE "$VOLUME_PATH")
    VOLUME_SIZE=$(lsblk -b -n -o SIZE "$DEVICE" 2>/dev/null | awk '{print int($1/1073741824)}')
else
    # Chercher un volume non monté
    for dev in /dev/sd[b-z] /dev/vd[b-z]; do
        if [ -b "$dev" ] && ! mount | grep -q "$dev"; then
            VOLUME_SIZE=$(lsblk -b -n -o SIZE "$dev" 2>/dev/null | awk '{print int($1/1073741824)}' | head -1)
            [ -n "$VOLUME_SIZE" ] && [ "$VOLUME_SIZE" -gt 0 ] && break
        fi
    done
fi

echo "CPU:$CPU_COUNT"
echo "RAM_MB:$RAM_MB"
echo "RAM_GB:$RAM_GB"
echo "VOLUME_GB:$VOLUME_SIZE"

# Type de workload basé sur les specs
if [ "$RAM_GB" -le 4 ]; then
    echo "WORKLOAD:small"
elif [ "$RAM_GB" -le 8 ]; then
    echo "WORKLOAD:medium"
elif [ "$RAM_GB" -le 16 ]; then
    echo "WORKLOAD:large"
else
    echo "WORKLOAD:xlarge"
fi
SPECS
}

# Fonction pour calculer les paramètres optimaux
calculate_optimal_params() {
    local cpu_count="$1"
    local ram_mb="$2"
    local volume_gb="$3"
    local workload="$4"
    
    # Shared buffers: 25% de la RAM
    local shared_buffers=$((ram_mb / 4))
    [ $shared_buffers -gt 8192 ] && shared_buffers=8192  # Cap à 8GB
    
    # Effective cache: 50-75% de la RAM
    local effective_cache=$((ram_mb * 3 / 4))
    
    # Work mem: RAM disponible / (max_connections * 3)
    local max_connections=200
    [ "$workload" = "small" ] && max_connections=100
    [ "$workload" = "xlarge" ] && max_connections=400
    
    local work_mem=$((ram_mb / (max_connections * 3)))
    [ $work_mem -lt 4 ] && work_mem=4
    [ $work_mem -gt 256 ] && work_mem=256
    
    # Maintenance work mem: 5-10% de la RAM
    local maintenance_work_mem=$((ram_mb / 10))
    [ $maintenance_work_mem -gt 2048 ] && maintenance_work_mem=2048
    
    # WAL et checkpoint
    local max_wal_size="2GB"
    [ "$workload" = "xlarge" ] && max_wal_size="4GB"
    
    local min_wal_size="512MB"
    [ "$workload" = "xlarge" ] && min_wal_size="1GB"
    
    # Workers basés sur CPU
    local max_worker_processes=$cpu_count
    [ $max_worker_processes -gt 16 ] && max_worker_processes=16
    
    local max_parallel_workers=$((cpu_count / 2))
    [ $max_parallel_workers -lt 2 ] && max_parallel_workers=2
    [ $max_parallel_workers -gt 8 ] && max_parallel_workers=8
    
    echo "shared_buffers:${shared_buffers}MB"
    echo "effective_cache_size:${effective_cache}MB"
    echo "work_mem:${work_mem}MB"
    echo "maintenance_work_mem:${maintenance_work_mem}MB"
    echo "max_connections:$max_connections"
    echo "max_wal_size:$max_wal_size"
    echo "min_wal_size:$min_wal_size"
    echo "max_worker_processes:$max_worker_processes"
    echo "max_parallel_workers:$max_parallel_workers"
    echo "max_parallel_workers_per_gather:$((max_parallel_workers / 2))"
    echo "max_parallel_maintenance_workers:$((max_parallel_workers / 2))"
}

# Analyser les specs de chaque nœud
echo "1. Analyse des ressources serveurs..."
echo ""

declare -A SERVER_SPECS
declare -A SERVER_PARAMS

for node in "${DB_NODES[@]}"; do
    specs=$(get_server_specs "${NODE_IPS[$node]}" "$node")
    
    # Parser les specs
    cpu=$(echo "$specs" | grep "^CPU:" | cut -d: -f2)
    ram_mb=$(echo "$specs" | grep "^RAM_MB:" | cut -d: -f2)
    ram_gb=$(echo "$specs" | grep "^RAM_GB:" | cut -d: -f2)
    volume=$(echo "$specs" | grep "^VOLUME_GB:" | cut -d: -f2)
    workload=$(echo "$specs" | grep "^WORKLOAD:" | cut -d: -f2)
    
    echo "    CPU: ${cpu} cores, RAM: ${ram_gb}GB, Volume: ${volume}GB, Profile: $workload"
    
    # Calculer les paramètres optimaux
    params=$(calculate_optimal_params "$cpu" "$ram_mb" "$volume" "$workload")
    SERVER_PARAMS[$node]="$params"
done

echo ""
echo "2. Configuration des ports et firewall..."
echo ""

# Ouvrir le port Raft sur tous les nœuds
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: Port Raft 7000... "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'FIREWALL' 2>/dev/null
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni Raft' 2>/dev/null
ufw allow 8008/tcp comment 'Patroni API' 2>/dev/null
ufw allow 5432/tcp comment 'PostgreSQL' 2>/dev/null
ufw --force reload >/dev/null 2>&1
FIREWALL
    echo -e "$OK"
done

echo ""
echo "3. Arrêt des services existants..."
echo ""

# Arrêter PostgreSQL et Patroni existants
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  Arrêt $node... "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STOP' 2>/dev/null
docker stop postgres patroni 2>/dev/null
docker rm postgres patroni 2>/dev/null
systemctl stop postgresql 2>/dev/null
systemctl disable postgresql 2>/dev/null
STOP
    echo -e "$OK"
done

echo ""
echo "4. Préparation du stockage..."
echo ""

# Préparer les volumes et structure sur chaque nœud
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "  Configuration $node..."
    
    # Récupérer les paramètres pour ce nœud
    params="${SERVER_PARAMS[$node]}"
    
    MAIN_LOG="$LOG_DIR/patroni_raft_${node}_$TIMESTAMP.log"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$FORCE_FORMAT" "$params" > "$MAIN_LOG" 2>&1 <<'PREPARE'
NODE_NAME="$1"
FORCE_FORMAT="$2"
PARAMS="$3"

set -u
set -o pipefail

echo "=== Préparation $NODE_NAME ==="

# Créer la structure
mkdir -p /opt/keybuzz/postgres/{data,archive,wal,config,raft,status}
mkdir -p /opt/keybuzz/patroni/{config,logs}

# Préparer le volume
VOLUME_PATH="/opt/keybuzz/postgres/data"

if ! mountpoint -q "$VOLUME_PATH"; then
    echo "  Montage du volume..."
    
    # Trouver un device disponible
    DEVICE=""
    for dev in /dev/sd[b-z] /dev/vd[b-z]; do
        if [ -b "$dev" ] && ! mount | grep -q "$dev"; then
            DEVICE="$dev"
            break
        fi
    done
    
    if [ -n "$DEVICE" ]; then
        # Formater si demandé ou si pas de système de fichiers
        if [ "$FORCE_FORMAT" = "--force-format" ] || ! blkid "$DEVICE" 2>/dev/null | grep -q "TYPE="; then
            echo "  Formatage $DEVICE..."
            mkfs.ext4 -F -m0 "$DEVICE" >/dev/null 2>&1
        fi
        
        # Monter
        mount "$DEVICE" "$VOLUME_PATH"
        
        # Ajouter à fstab
        UUID=$(blkid -s UUID -o value "$DEVICE")
        grep -q "$VOLUME_PATH" /etc/fstab || echo "UUID=$UUID $VOLUME_PATH ext4 defaults,nofail 0 2" >> /etc/fstab
        
        echo "  Volume monté: $DEVICE -> $VOLUME_PATH"
    fi
fi

# Créer le répertoire Raft
mkdir -p /opt/keybuzz/postgres/raft

# Permissions
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft

echo "OK" > /opt/keybuzz/postgres/status/STATE
echo "  Structure créée"
PREPARE
    
    echo "    $(tail -n 1 "$MAIN_LOG")"
done

echo ""
echo "5. Génération configuration Patroni avec Raft..."
echo ""

# Générer la configuration Patroni pour chaque nœud
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "  Génération config $node..."
    
    # Récupérer les paramètres
    params="${SERVER_PARAMS[$node]}"
    
    # Construire la liste des partenaires Raft (tous sauf lui-même)
    partners=""
    for other_node in "${DB_NODES[@]}"; do
        if [ "$other_node" != "$node" ]; then
            [ -n "$partners" ] && partners="$partners,"
            partners="${partners}${NODE_IPS[$other_node]}:7000"
        fi
    done
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$ip" "$POSTGRES_PASSWORD" "$params" "$partners" <<'PATRONI_CONFIG'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
PARAMS="$4"
RAFT_PARTNERS="$5"

# Parser les paramètres
shared_buffers=$(echo "$PARAMS" | grep "shared_buffers:" | cut -d: -f2)
effective_cache=$(echo "$PARAMS" | grep "effective_cache_size:" | cut -d: -f2)
work_mem=$(echo "$PARAMS" | grep "work_mem:" | cut -d: -f2)
maintenance_work_mem=$(echo "$PARAMS" | grep "maintenance_work_mem:" | cut -d: -f2)
max_connections=$(echo "$PARAMS" | grep "max_connections:" | cut -d: -f2)
max_wal_size=$(echo "$PARAMS" | grep "max_wal_size:" | cut -d: -f2)
min_wal_size=$(echo "$PARAMS" | grep "min_wal_size:" | cut -d: -f2)
max_worker_processes=$(echo "$PARAMS" | grep "max_worker_processes:" | cut -d: -f2)
max_parallel_workers=$(echo "$PARAMS" | grep "max_parallel_workers:" | cut -d: -f2)

# Générer patroni.yml avec section raft
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

# DCS Raft intégré (pas d'etcd externe)
raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${NODE_IP}:7000
  partner_addrs:
EOF

# Ajouter les partenaires Raft
IFS=',' read -ra PARTNERS <<< "$RAFT_PARTNERS"
for partner in "${PARTNERS[@]}"; do
    echo "    - $partner" >> /opt/keybuzz/patroni/config/patroni.yml
done

cat >> /opt/keybuzz/patroni/config/patroni.yml <<EOF

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 33554432
    master_start_timeout: 300
    synchronous_mode: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: $max_connections
        shared_buffers: $shared_buffers
        effective_cache_size: $effective_cache
        maintenance_work_mem: $maintenance_work_mem
        work_mem: $work_mem
        max_wal_size: $max_wal_size
        min_wal_size: $min_wal_size
        max_worker_processes: $max_worker_processes
        max_parallel_workers: $max_parallel_workers
        max_parallel_workers_per_gather: 4
        max_parallel_maintenance_workers: 4
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        min_wal_size: 512MB
        max_replication_slots: 10
        max_wal_senders: 10
        wal_keep_size: 1GB
        hot_standby: 'on'
        wal_level: replica
        wal_log_hints: 'on'
        archive_mode: 'on'
        archive_command: 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'
        archive_timeout: 1800s
        shared_preload_libraries: 'pg_stat_statements,pgaudit'

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5
    - host all postgres 10.0.0.0/16 md5

  users:
    postgres:
      password: '$PG_PASSWORD'
      options:
        - createrole
        - createdb
    replicator:
      password: '$PG_PASSWORD'
      options:
        - replication

postgresql:
  listen: '*:5432'
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
      password: '$PG_PASSWORD'
  parameters:
    unix_socket_directories: '/var/run/postgresql'
    port: 5432
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

echo "  Configuration Patroni générée avec Raft DCS"
PATRONI_CONFIG
done

echo ""
echo "6. Construction image Docker Patroni avec Raft..."
echo ""

# Construire l'image sur chaque nœud
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  Build image sur $node... "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$PG_VERSION" "$PATRONI_VERSION" <<'BUILD_IMAGE' >/dev/null 2>&1
PG_VERSION="$1"
PATRONI_VERSION="$2"

cd /opt/keybuzz/patroni

cat > Dockerfile <<DOCKERFILE
FROM postgres:${PG_VERSION}

RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-dev \
    gcc \
    python3-psycopg2 \
    curl \
    && pip3 install --break-system-packages \
        patroni[raft]==${PATRONI_VERSION} \
        psycopg2-binary \
        python-dateutil \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Extensions PostgreSQL
RUN apt-get update && apt-get install -y \
    postgresql-${PG_VERSION}-pgaudit \
    postgresql-${PG_VERSION}-pg-stat-kcache \
    postgresql-${PG_VERSION}-pgvector \
    && apt-get clean

COPY config/patroni.yml /etc/patroni/patroni.yml

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-pg${PG_VERSION}-raft:latest .
BUILD_IMAGE
    
    if [ $? -eq 0 ]; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "7. Démarrage cluster Patroni avec Raft..."
echo ""

# Démarrer le premier nœud (bootstrap)
FIRST_NODE="db-master-01"
echo "  Démarrage $FIRST_NODE (bootstrap initial)..."

ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$FIRST_NODE]}" bash -s "$PG_VERSION" <<'START_FIRST'
PG_VERSION="$1"

# Nettoyer le répertoire Raft
rm -rf /opt/keybuzz/postgres/raft/*

# Démarrer Patroni
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-pg${PG_VERSION}-raft:latest

echo "  Attente initialisation (30s)..."
sleep 30

# Vérifier le status
if docker ps | grep -q patroni; then
    echo "  Container démarré"
    curl -s http://localhost:8008/patroni | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  État: {d.get('state','?')}, Role: {d.get('role','?')}\")" 2>/dev/null || echo "  API pas encore prête"
else
    echo "  ERREUR: Container non démarré"
    docker logs patroni --tail 20
fi
START_FIRST

# Attendre que le leader soit prêt
sleep 10

# Démarrer les autres nœuds
for node in db-slave-01 db-slave-02; do
    echo "  Démarrage $node..."
    
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" bash -s "$PG_VERSION" <<'START_OTHERS'
PG_VERSION="$1"

# Nettoyer
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*

# Démarrer
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-pg${PG_VERSION}-raft:latest

sleep 5
START_OTHERS
done

echo ""
echo "8. Attente stabilisation cluster (20s)..."
sleep 20

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VÉRIFICATION CLUSTER PATRONI RAFT"
echo "═══════════════════════════════════════════════════════════════════"

# Vérifier l'état du cluster
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo ""
    echo "$node ($ip):"
    
    # API Patroni
    echo -n "  API Patroni: "
    if curl -s "http://$ip:8008/patroni" >/dev/null 2>&1; then
        STATE=$(curl -s "http://$ip:8008/patroni" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"state={d.get('state','?')}, role={d.get('role','?')}\")" 2>/dev/null || echo "Parse error")
        echo -e "$OK $STATE"
    else
        echo -e "$KO"
    fi
    
    # Port Raft
    echo -n "  Port Raft 7000: "
    if nc -zv "$ip" 7000 2>&1 | grep -q succeeded; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "État du cluster:"
curl -s "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Cluster non accessible"

# Afficher les logs
echo ""
echo "Logs récents (tail -n 50):"
echo "═══════════════════════════════════════════════════════════════════"
for node in "${DB_NODES[@]}"; do
    LOG_FILE="$LOG_DIR/patroni_raft_${node}_$TIMESTAMP.log"
    if [ -f "$LOG_FILE" ]; then
        echo ">>> $node:"
        tail -n 50 "$LOG_FILE" | grep -E "OK|KO|ERROR|WARNING" | tail -n 10
        echo ""
    fi
done

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Migration Patroni avec Raft DCS terminée"
echo ""
echo "Accès:"
echo "  API: curl http://${NODE_IPS[db-master-01]}:8008/cluster"
echo "  Leader: psql -h ${NODE_IPS[db-master-01]} -U postgres"
echo "  Port Raft: 7000/tcp (communication inter-nœuds)"
echo ""
echo "Note: Plus aucune dépendance à etcd externe"
echo "═══════════════════════════════════════════════════════════════════"
