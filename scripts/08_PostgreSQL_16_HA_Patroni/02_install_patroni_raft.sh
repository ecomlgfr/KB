#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     02_INSTALL_PATRONI_RAFT - Installation Patroni HA avec Raft    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Configuration
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/02_patroni_raft_$TIMESTAMP.log"

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    source /opt/keybuzz-installer/credentials/postgres.env
else
    echo -e "$KO Credentials non trouvés. Lancez d'abord: ./01_prepare_infrastructure.sh"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Installation PostgreSQL 17 + Patroni avec Raft DCS"
echo "Architecture: 3 nœuds avec consensus Raft intégré"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Serveurs DB
DB_SERVERS=("10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")

echo "1. Construction de l'image Docker Patroni..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Build sur $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'BUILD' >> "$MAIN_LOG" 2>&1
cd /opt/keybuzz/patroni

cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

# Variables d'environnement pour éviter les prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Installation des dépendances et extensions
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3-pip \
        python3-dev \
        python3-psycopg2 \
        gcc \
        curl \
        ca-certificates \
        postgresql-17-pgvector \
        postgresql-17-pg-stat-kcache \
        postgresql-17-pgaudit \
        postgresql-17-wal2json \
        postgresql-17-pglogical && \
    pip3 install --no-cache-dir --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary \
        python-dateutil && \
    apt-get remove -y gcc python3-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Créer les répertoires nécessaires
RUN mkdir -p /opt/keybuzz/postgres/raft && \
    mkdir -p /var/lib/postgresql/data && \
    mkdir -p /var/run/postgresql && \
    chown -R postgres:postgres /opt/keybuzz/postgres && \
    chown -R postgres:postgres /var/lib/postgresql && \
    chown -R postgres:postgres /var/run/postgresql && \
    chmod 700 /var/lib/postgresql/data && \
    chmod 2775 /var/run/postgresql

# Script d'initialisation des extensions
COPY --chown=postgres:postgres init-extensions.sh /docker-entrypoint-initdb.d/
RUN chmod +x /docker-entrypoint-initdb.d/init-extensions.sh

# Utiliser l'utilisateur postgres
USER postgres

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

# Script d'initialisation des extensions
cat > init-extensions.sh <<'INIT'
#!/bin/bash
set -e

echo "Activation des extensions PostgreSQL..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    CREATE EXTENSION IF NOT EXISTS pgaudit;
    CREATE EXTENSION IF NOT EXISTS wal2json;
    CREATE EXTENSION IF NOT EXISTS pglogical;
EOSQL
INIT

chmod +x init-extensions.sh

# Build
docker build -t patroni:17-raft . >/dev/null 2>&1
BUILD
    
    if [ $? -eq 0 ]; then
        echo -e "$OK"
    else
        echo -e "$KO (voir logs)"
    fi
done

echo ""
echo "2. Génération des configurations Patroni..."
echo ""

# Fonction pour générer la config Patroni
generate_patroni_config() {
    local ip="$1"
    local hostname="$2"
    local is_bootstrap="$3"
    
    # Déterminer les partenaires Raft
    local partners=""
    for server in "${DB_SERVERS[@]}"; do
        IFS=':' read -r peer_ip peer_host <<< "$server"
        if [ "$peer_ip" != "$ip" ]; then
            [ -n "$partners" ] && partners="${partners}
    - ${peer_ip}:7000"
            [ -z "$partners" ] && partners="    - ${peer_ip}:7000"
        fi
    done
    
    cat <<EOF
scope: postgres-keybuzz
namespace: /service/
name: $hostname

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${ip}:8008
  authentication:
    username: patroni
    password: '${PATRONI_API_PASSWORD}'

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${ip}:7000
  partner_addrs:
$partners

EOF

    # Section bootstrap seulement pour le premier nœud
    if [ "$is_bootstrap" = "true" ]; then
        cat <<EOF
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 33554432
    master_start_timeout: 300
    synchronous_mode: false
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        shared_buffers: 512MB
        effective_cache_size: 2GB
        maintenance_work_mem: 256MB
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        work_mem: 8MB
        min_wal_size: 1GB
        max_wal_size: 4GB
        max_worker_processes: 8
        max_parallel_workers_per_gather: 4
        max_parallel_workers: 8
        max_parallel_maintenance_workers: 4
        max_replication_slots: 10
        max_wal_senders: 10
        wal_keep_size: 1GB
        wal_level: replica
        hot_standby: 'on'
        wal_log_hints: 'on'
        archive_mode: 'on'
        archive_command: 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'
        archive_timeout: 1800s
        shared_preload_libraries: 'pg_stat_statements,pgaudit,vector'

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all ::1/128 trust
    - host all all 10.0.0.0/16 md5
    - host all all 0.0.0.0/0 md5
    - host replication replicator 10.0.0.0/16 md5
    - host replication replicator 0.0.0.0/0 md5

  users:
    postgres:
      password: '${POSTGRES_PASSWORD}'
      options:
        - createrole
        - createdb
    replicator:
      password: '${REPLICATOR_PASSWORD}'
      options:
        - replication

EOF
    fi
    
    # Section postgresql commune
    cat <<EOF
postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${ip}:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: '${POSTGRES_PASSWORD}'
    replication:
      username: replicator
      password: '${REPLICATOR_PASSWORD}'
  parameters:
    unix_socket_directories: '/var/run/postgresql'
    port: 5432
    logging_collector: 'on'
    log_directory: '/opt/keybuzz/postgres/logs'
    log_filename: 'postgresql-%Y-%m-%d.log'
    log_rotation_age: 1d
    log_rotation_size: 100MB
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast
  callbacks:
    on_start: /bin/true
    on_stop: /bin/true
    on_restart: /bin/true
    on_reload: /bin/true
    on_role_change: /bin/true

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
}

# Générer les configs pour chaque serveur
for i in "${!DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "${DB_SERVERS[$i]}"
    echo -n "  Config $hostname: "
    
    # Le premier serveur aura la config bootstrap
    is_bootstrap="false"
    [ $i -eq 0 ] && is_bootstrap="true"
    
    config=$(generate_patroni_config "$ip" "$hostname" "$is_bootstrap")
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -c "
        cat > /opt/keybuzz/patroni/config/patroni.yml <<'EOF'
$config
EOF
        chown 999:999 /opt/keybuzz/patroni/config/patroni.yml
    "
    
    echo -e "$OK"
done

echo ""
echo "3. Montage des volumes (si disponibles)..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  $hostname:"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'MOUNT_VOLUME' 2>/dev/null
DATA_DIR="/opt/keybuzz/postgres/data"

# Si déjà monté, ne rien faire
if mountpoint -q "$DATA_DIR" 2>/dev/null; then
    echo "    Volume déjà monté"
    exit 0
fi

# Chercher un device disponible
DEVICE=""
for dev in /dev/sd[b-z] /dev/vd[b-z]; do
    if [ -b "$dev" ] && ! mount | grep -q "$dev"; then
        DEVICE="$dev"
        break
    fi
done

if [ -n "$DEVICE" ]; then
    # Formatter si nécessaire
    if ! blkid "$DEVICE" 2>/dev/null | grep -q "TYPE="; then
        echo "    Formatage $DEVICE..."
        mkfs.ext4 -F -m0 "$DEVICE" >/dev/null 2>&1
    fi
    
    # Monter
    mount "$DEVICE" "$DATA_DIR"
    
    # Ajouter à fstab
    UUID=$(blkid -s UUID -o value "$DEVICE")
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID $DATA_DIR ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    
    # Permissions
    chown 999:999 "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    
    echo "    Volume monté: $DEVICE"
else
    echo "    Pas de volume externe (utilisation disque local)"
fi
MOUNT_VOLUME
done

echo ""
echo "4. DÉMARRAGE SIMULTANÉ des 3 nœuds (formation du quorum Raft)..."
echo ""

# Démarrer les 3 containers SIMULTANÉMENT
echo "  Lancement des containers:"

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START' 2>/dev/null &
# Vérifier les permissions une dernière fois
chown -R 999:999 /opt/keybuzz/postgres
chown 999:999 /opt/keybuzz/patroni/config/patroni.yml

# Démarrer le container
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/postgres/logs:/opt/keybuzz/postgres/logs \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni:17-raft
START
done

# Attendre que tous les jobs se terminent
wait

echo -e "    $OK Tous les containers lancés"
echo ""
echo "  Attente de la formation du quorum Raft (45s)..."

# Barre de progression
for i in {1..45}; do
    echo -n "."
    sleep 1
done
echo ""

echo ""
echo "5. Vérification du cluster..."
echo ""

# Vérifier l'état de chaque nœud
NODES_OK=0
LEADER_IP=""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  $hostname: "
    
    # Tester l'API Patroni
    STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f\"{d.get('state', '?')}/{d.get('role', '?')}\")
except:
    print('ERROR')
" 2>/dev/null || echo "UNREACHABLE")
    
    if [[ "$STATE" == *"running"* ]] || [[ "$STATE" == *"streaming"* ]]; then
        echo -e "$OK $STATE"
        NODES_OK=$((NODES_OK + 1))
        
        # Identifier le leader
        if [[ "$STATE" == *"master"* ]] || [[ "$STATE" == *"leader"* ]]; then
            LEADER_IP="$ip"
        fi
    else
        echo -e "$KO $STATE"
    fi
done

echo ""
echo "6. État du cluster Patroni..."
echo ""

if [ -n "$LEADER_IP" ]; then
    curl -s "http://$LEADER_IP:8008/cluster" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  Cluster non accessible"
else
    echo "  Leader non trouvé"
fi

echo ""
echo "7. Tests de fonctionnement..."
echo ""

if [ -n "$LEADER_IP" ]; then
    echo "  Leader identifié: $LEADER_IP"
    echo ""
    
    # Test de connexion PostgreSQL
    echo -n "  Test connexion PostgreSQL: "
    if ssh root@"$LEADER_IP" "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Test des extensions
    echo -n "  Test pgvector: "
    TEST_RESULT=$(ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c \"CREATE EXTENSION IF NOT EXISTS vector; SELECT extname FROM pg_extension WHERE extname='vector';\" 2>/dev/null" | grep -c vector)
    if [ "$TEST_RESULT" -ge 1 ]; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Résumé final
if [ "$NODES_OK" -eq 3 ] && [ -n "$LEADER_IP" ]; then
    echo -e "$OK CLUSTER PATRONI OPÉRATIONNEL !"
    echo ""
    echo "Configuration:"
    echo "  • DCS: Raft (consensus intégré)"
    echo "  • PostgreSQL: 17 avec pgvector"
    echo "  • Architecture: 1 leader + 2 replicas"
    echo "  • Leader actuel: $LEADER_IP"
    echo ""
    echo "Connexion:"
    echo "  psql -h $LEADER_IP -U postgres -d postgres"
    echo "  Password: $POSTGRES_PASSWORD"
    echo ""
    echo "API Patroni:"
    echo "  curl http://$LEADER_IP:8008/cluster"
    echo ""
    echo "Logs: $MAIN_LOG"
    echo ""
    echo "Prochaine étape: ./03_install_pgbouncer.sh"
else
    echo -e "$KO Installation incomplète ($NODES_OK/3 nœuds actifs)"
    echo ""
    echo "Debug:"
    echo "  Voir les logs: $MAIN_LOG"
    echo "  docker logs patroni sur chaque nœud"
    echo ""
    echo "Relancer: ./02_install_patroni_raft.sh"
fi

echo "═══════════════════════════════════════════════════════════════════"
