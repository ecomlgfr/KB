#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   08_POSTGRES_TO_PATRONI_ADAPTIVE - Cluster HA Auto-Adaptatif     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)
ETCD_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)
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

# Charger les endpoints etcd
if [ -f /opt/keybuzz-installer/credentials/etcd_endpoints.txt ]; then
    source /opt/keybuzz-installer/credentials/etcd_endpoints.txt
else
    echo -e "$KO etcd_endpoints.txt introuvable - lancez d'abord 05_etcd_to_cluster.sh"
    exit 1
fi

echo ""
echo "═══ Migration PostgreSQL → Patroni Cluster HA (Adaptive) ═══"
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

# IPs etcd
declare -A ETCD_IPS
for node in "${ETCD_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    ETCD_IPS[$node]=$ip
done

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
echo "RAM_GB:$RAM_GB"
echo "RAM_MB:$RAM_MB"
echo "VOLUME_GB:$VOLUME_SIZE"
SPECS
}

# Analyser les serveurs
echo "1. Analyse des ressources serveurs..."
echo ""

declare -A SERVER_SPECS

for node in "${DB_NODES[@]}"; do
    specs=$(get_server_specs "${NODE_IPS[$node]}" "$node")
    
    CPU=$(echo "$specs" | grep "^CPU:" | cut -d: -f2)
    RAM_GB=$(echo "$specs" | grep "^RAM_GB:" | cut -d: -f2)
    RAM_MB=$(echo "$specs" | grep "^RAM_MB:" | cut -d: -f2)
    VOLUME_GB=$(echo "$specs" | grep "^VOLUME_GB:" | cut -d: -f2)
    
    SERVER_SPECS["${node}_cpu"]=$CPU
    SERVER_SPECS["${node}_ram_gb"]=$RAM_GB
    SERVER_SPECS["${node}_ram_mb"]=$RAM_MB
    SERVER_SPECS["${node}_volume_gb"]=$VOLUME_GB
    
    echo "    $node: ${CPU} CPU, ${RAM_GB}GB RAM, ${VOLUME_GB}GB Volume"
done

echo ""
echo "2. Vérification prérequis..."
echo ""

# Vérifier etcd
echo -n "  etcd cluster: "
ETCD_OK=0
for node in "${ETCD_NODES[@]}"; do
    if curl -s "http://${ETCD_IPS[$node]}:2379/version" 2>/dev/null | grep -q "etcdserver"; then
        ((ETCD_OK++))
    fi
done

if [ $ETCD_OK -ge 2 ]; then
    echo -e "$OK ($ETCD_OK/3 nœuds)"
else
    echo -e "$KO"
    echo "Lancez d'abord: ./05_etcd_to_cluster.sh"
    exit 1
fi

# Vérifier PostgreSQL standalone
echo -n "  PostgreSQL standalone: "
PG_OK=0
for node in "${DB_NODES[@]}"; do
    if ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" "docker ps | grep -q postgres" 2>/dev/null; then
        ((PG_OK++))
    fi
done
echo -e "$OK ($PG_OK/3 nœuds)"

echo ""
echo "3. Préparation des volumes..."
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$FORCE_FORMAT" <<'VOLUME_PREP'
FORCE_FORMAT="$1"
VOLUME_PATH="/opt/keybuzz/postgres/data"
MOUNT_POINT="/opt/keybuzz/postgres/data"

# Créer le point de montage
mkdir -p "$MOUNT_POINT"

# Si déjà monté et pas de force format
if mountpoint -q "$MOUNT_POINT" && [ "$FORCE_FORMAT" != "--force-format" ]; then
    echo "Volume déjà monté ($(df -h $MOUNT_POINT | tail -1 | awk '{print $2}'))"
    exit 0
fi

# Si force format, démonter
if [ "$FORCE_FORMAT" = "--force-format" ] && mountpoint -q "$MOUNT_POINT"; then
    # Arrêter les services
    docker stop postgres patroni 2>/dev/null || true
    docker rm postgres patroni 2>/dev/null || true
    
    # Démonter
    umount "$MOUNT_POINT" 2>/dev/null || true
fi

# Trouver le device
DEVICE=""
for dev in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
    [ -b "$dev" ] || continue
    real_dev=$(readlink -f "$dev" 2>/dev/null || echo "$dev")
    if ! mount | grep -q "$real_dev"; then
        DEVICE="$real_dev"
        break
    fi
done

if [ -z "$DEVICE" ]; then
    echo "Pas de volume disponible"
    exit 0
fi

# Formater si nécessaire ou forcé
if [ "$FORCE_FORMAT" = "--force-format" ] || ! blkid "$DEVICE" 2>/dev/null | grep -q ext4; then
    wipefs -af "$DEVICE" 2>/dev/null
    mkfs.ext4 -F -m0 -O dir_index,has_journal,extent "$DEVICE" >/dev/null 2>&1
    echo "Volume formaté"
fi

# Monter
mount "$DEVICE" "$MOUNT_POINT" 2>/dev/null

# Ajouter à fstab
UUID=$(blkid -s UUID -o value "$DEVICE")
if ! grep -q "$MOUNT_POINT" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# Nettoyer lost+found
[ -d "$MOUNT_POINT/lost+found" ] && rm -rf "$MOUNT_POINT/lost+found"

# Permissions PostgreSQL
chown -R 999:999 "$MOUNT_POINT" 2>/dev/null || true

SIZE=$(df -h "$MOUNT_POINT" | tail -1 | awk '{print $2}')
echo "Volume prêt ($SIZE)"
VOLUME_PREP
done

echo ""
echo "4. Sauvegarde des données..."
echo ""

MASTER_IP="${NODE_IPS[db-master-01]}"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" bash <<'BACKUP'
set -u
mkdir -p /opt/keybuzz/postgres/backup

if docker ps | grep -q postgres; then
    docker exec postgres pg_dumpall -U postgres > /opt/keybuzz/postgres/backup/full_dump_$(date +%Y%m%d-%H%M%S).sql 2>/dev/null && \
    echo "    ✓ Backup créé" || echo "    ⚠ Pas de données critiques"
fi
BACKUP

echo ""
echo "5. Arrêt des instances..."
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STOP'
docker stop postgres patroni 2>/dev/null || true
docker rm postgres patroni 2>/dev/null || true
echo "✓ arrêté"
STOP
done

echo ""
echo "6. Configuration Patroni adaptative..."
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    
    # Récupérer les specs
    CPU="${SERVER_SPECS[${node}_cpu]}"
    RAM_MB="${SERVER_SPECS[${node}_ram_mb]}"
    RAM_GB="${SERVER_SPECS[${node}_ram_gb]}"
    VOLUME_GB="${SERVER_SPECS[${node}_volume_gb]}"
    
    # Calculer les paramètres PostgreSQL adaptés
    SHARED_BUFFERS=$((RAM_MB / 4))  # 25% de la RAM
    EFFECTIVE_CACHE=$((RAM_MB * 3 / 4))  # 75% de la RAM
    WORK_MEM=$((RAM_MB / CPU / 100))  # RAM/CPU/100
    MAINTENANCE_MEM=$((RAM_MB / 16))  # RAM/16
    MAX_CONNECTIONS=$((CPU * 25))  # 25 connexions par CPU
    MAX_WORKERS=$((CPU))  # 1 worker par CPU
    WAL_BUFFERS=$((SHARED_BUFFERS / 32))
    [ $WAL_BUFFERS -gt 16 ] || WAL_BUFFERS=16
    
    echo "  Configuration $node (${CPU}CPU/${RAM_GB}GB)..."
    echo "    shared_buffers: ${SHARED_BUFFERS}MB"
    echo "    effective_cache_size: ${EFFECTIVE_CACHE}MB"
    echo "    max_connections: $MAX_CONNECTIONS"
    
    # Déterminer le rôle initial
    [ "$node" = "db-master-01" ] && ROLE="master" || ROLE="replica"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$ip" "$POSTGRES_PASSWORD" "$ETCD_HOSTS" \
        "$ROLE" "$PG_VERSION" "$PATRONI_VERSION" "$SHARED_BUFFERS" "$EFFECTIVE_CACHE" \
        "$WORK_MEM" "$MAINTENANCE_MEM" "$MAX_CONNECTIONS" "$MAX_WORKERS" "$WAL_BUFFERS" <<'PATRONI'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
ETCD_HOSTS="$4"
INITIAL_ROLE="$5"
PG_VERSION="$6"
PATRONI_VERSION="$7"
SHARED_BUFFERS="${8}MB"
EFFECTIVE_CACHE="${9}MB"
WORK_MEM="${10}MB"
MAINTENANCE_MEM="${11}MB"
MAX_CONNECTIONS="$12"
MAX_WORKERS="$13"
WAL_BUFFERS="${14}MB"

mkdir -p /opt/keybuzz/patroni/{config,logs}
mkdir -p /opt/keybuzz/postgres/{logs,archive,backup}

# Configuration Patroni avec paramètres adaptés
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
        # Paramètres adaptés aux ressources
        max_connections: $MAX_CONNECTIONS
        shared_buffers: $SHARED_BUFFERS
        effective_cache_size: $EFFECTIVE_CACHE
        work_mem: $WORK_MEM
        maintenance_work_mem: $MAINTENANCE_MEM
        wal_buffers: $WAL_BUFFERS
        
        # Parallélisation
        max_worker_processes: $MAX_WORKERS
        max_parallel_workers: $MAX_WORKERS
        max_parallel_workers_per_gather: 2
        max_parallel_maintenance_workers: 2
        
        # Réplication
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 2GB
        hot_standby: 'on'
        wal_log_hints: 'on'
        
        # Archives
        archive_mode: 'on'
        archive_command: 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'
        
        # Checkpoints
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        
        # Optimisations
        random_page_cost: 1.1
        effective_io_concurrency: 200
        default_statistics_target: 100
        
        # Logs
        logging_collector: 'on'
        log_directory: '/var/lib/postgresql/data/log'
        log_filename: 'postgresql-%Y-%m-%d.log'
        log_rotation_age: 1d
        log_rotation_size: 100MB
        log_line_prefix: '%t [%p] %q%u@%d '
        log_statement: 'ddl'
        log_min_duration_statement: 100
        
        # Autovacuum
        autovacuum: 'on'
        autovacuum_max_workers: $MAX_WORKERS
        autovacuum_naptime: 30s

  initdb:
    - encoding: UTF8
    - locale: en_US.UTF-8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all ::1/128 trust
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
    replication:
      username: replicator
      password: '$PG_PASSWORD'
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
  parameters:
    unix_socket_directories: '/var/run/postgresql'
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

# Dockerfile Patroni
cat > /opt/keybuzz/patroni/Dockerfile <<DOCKERFILE
FROM postgres:${PG_VERSION}

RUN apt-get update && apt-get install -y \\
    python3-pip python3-psycopg2 python3-dev gcc curl \\
    && pip3 install --break-system-packages \\
       patroni[etcd3]==${PATRONI_VERSION} \\
       python-etcd psycopg2-binary \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY config/patroni.yml /etc/patroni/patroni.yml
EXPOSE 5432 8008
CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

cd /opt/keybuzz/patroni
docker build -t patroni-pg${PG_VERSION}:latest . >/dev/null 2>&1

echo "    ✓ $NODE_NAME configuré"
PATRONI
done

echo ""
echo "7. Démarrage du cluster Patroni..."
echo ""

# Démarrer db-master-01 en premier
echo "  Démarrage db-master-01 (leader initial)..."

ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[db-master-01]}" bash -s "$PG_VERSION" <<'START_MASTER'
PG_VERSION="$1"

docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  -v /opt/keybuzz/patroni/logs:/var/log/postgresql \
  patroni-pg${PG_VERSION}:latest

echo "    Attente initialisation (30s)..."
sleep 30

docker ps | grep -q patroni && echo "    ✓ db-master-01 démarré" || echo "    ✗ Échec"
START_MASTER

# Démarrer les replicas
for node in db-slave-01 db-slave-02; do
    echo "  Démarrage $node..."
    
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" bash -s "$PG_VERSION" <<'START_REPLICA'
PG_VERSION="$1"

docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  -v /opt/keybuzz/patroni/logs:/var/log/postgresql \
  patroni-pg${PG_VERSION}:latest

sleep 10
docker ps | grep -q patroni && echo "    ✓ $(hostname) démarré" || echo "    ✗ Échec"
START_REPLICA
done

echo ""
echo "8. Attente stabilisation (30s)..."
sleep 30

echo ""
echo "9. Vérification finale..."
curl -s -u patroni:$POSTGRES_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null | \
    python3 -m json.tool | head -30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CLUSTER PATRONI ADAPTATIF OPÉRATIONNEL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Configuration adaptée pour chaque serveur:"
for node in "${DB_NODES[@]}"; do
    echo "  $node: ${SERVER_SPECS[${node}_cpu]} CPU, ${SERVER_SPECS[${node}_ram_gb]}GB RAM"
done
echo ""
echo "Options du script:"
echo "  ./08_postgres_to_patroni_adaptive.sh              # Installation normale"
echo "  ./08_postgres_to_patroni_adaptive.sh --force-format # Forcer formatage volumes"
echo ""
echo "Prochaine étape: ./09_test_patroni_cluster.sh"
