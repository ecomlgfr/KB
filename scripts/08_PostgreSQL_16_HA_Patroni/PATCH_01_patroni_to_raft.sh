#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  PATCH_01_PATRONI_TO_RAFT - Conversion Patroni etcd → RAFT        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)
RAFT_PORT=7000

echo ""
echo "Ce patch va:"
echo "  1. Arrêter tous les containers Patroni"
echo "  2. Supprimer etcd (libérer ports 2379/2380)"
echo "  3. Reconfigurer Patroni avec RAFT natif"
echo "  4. Ouvrir le port 7000/tcp pour RAFT"
echo "  5. Redémarrer le cluster en mode RAFT"
echo ""

source /opt/keybuzz-installer/credentials/postgres.env

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo "Cluster DB:"
for node in "${DB_NODES[@]}"; do
    echo "  $node: ${NODE_IPS[$node]}"
done
echo ""

read -p "Continuer avec la migration RAFT? (y/N) " -r
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 1: Arrêt des containers Patroni"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "→ Arrêt $node..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STOP'
docker stop patroni 2>/dev/null
docker rm patroni 2>/dev/null
echo "  ✓ Patroni arrêté"
STOP
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 2: Suppression etcd (optionnel)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ETCD_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)

echo "Voulez-vous supprimer les containers etcd sur k3s-masters?"
echo "(Libère les ports 2379/2380, découple DB de K3s)"
read -p "Supprimer etcd? (y/N) " -r

if [[ $REPLY =~ ^[Yy]$ ]]; then
    for node in "${ETCD_NODES[@]}"; do
        ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
        [ -z "$ip" ] && continue
        
        echo "→ Suppression etcd sur $node..."
        ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'REMOVE_ETCD'
docker stop etcd 2>/dev/null
docker rm etcd 2>/dev/null
echo "  ✓ etcd supprimé"
REMOVE_ETCD
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 3: Configuration UFW pour RAFT (port 7000)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "→ Configuration UFW sur $node..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$RAFT_PORT" <<'UFW'
RAFT_PORT="$1"

# Autoriser RAFT entre les DB nodes
ufw allow from 10.0.0.0/16 to any port "$RAFT_PORT" proto tcp comment "Patroni RAFT"

echo "  ✓ Port $RAFT_PORT autorisé"
UFW
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 4: Reconfiguration Patroni avec RAFT"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Fonction pour analyser les ressources (tuning dynamique)
get_tuned_params() {
    local ip="$1"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'ANALYZE'
CPU_COUNT=$(nproc)
RAM_MB=$(free -m | grep "^Mem:" | awk '{print $2}')

SHARED_BUFFERS=$((RAM_MB / 4))
[ $SHARED_BUFFERS -lt 128 ] && SHARED_BUFFERS=128

EFFECTIVE_CACHE=$((RAM_MB * 3 / 4))
MAX_CONNECTIONS=$((CPU_COUNT * 50))
[ $MAX_CONNECTIONS -lt 100 ] && MAX_CONNECTIONS=100
WORK_MEM=$((RAM_MB / (MAX_CONNECTIONS * 3)))
[ $WORK_MEM -lt 4 ] && WORK_MEM=4

MAINTENANCE_MEM=$((RAM_MB / 16))
[ $MAINTENANCE_MEM -lt 64 ] && MAINTENANCE_MEM=64

echo "CPU:$CPU_COUNT"
echo "SHARED_BUFFERS:$SHARED_BUFFERS"
echo "EFFECTIVE_CACHE:$EFFECTIVE_CACHE"
echo "WORK_MEM:$WORK_MEM"
echo "MAINTENANCE_MEM:$MAINTENANCE_MEM"
echo "MAX_CONNECTIONS:$MAX_CONNECTIONS"
ANALYZE
}

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "→ Configuration RAFT pour $node..."
    
    # Récupérer les autres nodes pour partner_addrs
    PARTNERS=""
    for partner in "${DB_NODES[@]}"; do
        [ "$partner" = "$node" ] && continue
        PARTNERS+="    - ${NODE_IPS[$partner]}:$RAFT_PORT"$'\n'
    done
    
    # Analyser les ressources
    params=$(get_tuned_params "$ip")
    
    SHARED_BUFFERS=$(echo "$params" | grep "^SHARED_BUFFERS:" | cut -d: -f2)
    EFFECTIVE_CACHE=$(echo "$params" | grep "^EFFECTIVE_CACHE:" | cut -d: -f2)
    WORK_MEM=$(echo "$params" | grep "^WORK_MEM:" | cut -d: -f2)
    MAINTENANCE_MEM=$(echo "$params" | grep "^MAINTENANCE_MEM:" | cut -d: -f2)
    MAX_CONNECTIONS=$(echo "$params" | grep "^MAX_CONNECTIONS:" | cut -d: -f2)
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$ip" "$POSTGRES_PASSWORD" \
        "$RAFT_PORT" "$PARTNERS" "$SHARED_BUFFERS" "$EFFECTIVE_CACHE" "$WORK_MEM" \
        "$MAINTENANCE_MEM" "$MAX_CONNECTIONS" <<'RAFT_CONFIG'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
RAFT_PORT="$4"
PARTNERS="$5"
SHARED_BUFFERS="${6}MB"
EFFECTIVE_CACHE="${7}MB"
WORK_MEM="${8}MB"
MAINTENANCE_MEM="${9}MB"
MAX_CONNECTIONS="${10}"

# Créer le répertoire RAFT
mkdir -p /opt/keybuzz/postgres/raft
chown -R 999:999 /opt/keybuzz/postgres/raft
chmod 700 /opt/keybuzz/postgres/raft

# Nouvelle configuration Patroni avec RAFT
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

# RAFT remplace etcd
raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${NODE_IP}:${RAFT_PORT}
  partner_addrs:
$PARTNERS

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
        # Mémoire
        max_connections: $MAX_CONNECTIONS
        shared_buffers: $SHARED_BUFFERS
        effective_cache_size: $EFFECTIVE_CACHE
        work_mem: $WORK_MEM
        maintenance_work_mem: $MAINTENANCE_MEM
        
        # Réplication
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 2GB
        hot_standby: 'on'
        wal_log_hints: 'on'
        
        # Checkpoints
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        
        # Performances
        random_page_cost: 1.1
        effective_io_concurrency: 200
        
        # pgvector
        shared_preload_libraries: 'pg_stat_statements'

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
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
      password: '$PG_PASSWORD'
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

# Dockerfile avec RAFT (pas etcd3)
cat > /opt/keybuzz/patroni/Dockerfile <<'DOCKERFILE'
FROM postgres:17

RUN apt-get update && apt-get install -y \
    build-essential postgresql-server-dev-${PG_MAJOR} \
    git curl python3-pip python3-psycopg2 \
    && rm -rf /var/lib/apt/lists/*

# Installation Patroni avec RAFT (pas etcd3)
RUN pip3 install --break-system-packages \
    patroni[raft]==3.3.2 \
    psycopg2-binary

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

# Build l'image
cd /opt/keybuzz/patroni
docker build -t patroni-pg17-raft:latest . 2>&1 | grep -E "(Step|Successfully)" || true

echo "  ✓ Configuration RAFT créée"
RAFT_CONFIG
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 5: Démarrage cluster RAFT"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Démarrer le leader d'abord
echo "→ Démarrage db-master-01 (leader initial)..."

ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[db-master-01]}" bash <<'START_LEADER'
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-pg17-raft:latest

sleep 30
docker ps | grep -q patroni && echo "  ✓ Leader démarré" || echo "  ✗ Échec"
START_LEADER

# Démarrer les replicas
for node in db-slave-01 db-slave-02; do
    echo "→ Démarrage $node..."
    
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" bash <<'START_REPLICA'
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-pg17-raft:latest

sleep 15
docker ps | grep -q patroni && echo "  ✓ Replica démarré" || echo "  ✗ Échec"
START_REPLICA
done

echo ""
echo "Attente stabilisation cluster (30s)..."
sleep 30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VÉRIFICATION FINALE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# État du cluster
echo "État du cluster:"
curl -s -u patroni:$POSTGRES_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null | \
    jq '.members[] | {name, role, state, lag}' 2>/dev/null || \
    echo "API Patroni non accessible"

# Test connectivité
echo ""
echo "Test connectivité:"
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$ip" -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

# Vérifier RAFT
echo ""
echo "Ports RAFT actifs:"
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node ($RAFT_PORT): "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" "ss -tlnp | grep -q :$RAFT_PORT" && \
        echo -e "$OK" || echo -e "$KO"
done

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              MIGRATION RAFT TERMINÉE                               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

echo "Résumé:"
echo "  ✓ etcd supprimé (ports 2379/2380 libérés)"
echo "  ✓ Patroni configuré avec RAFT natif"
echo "  ✓ Port 7000/tcp ouvert pour RAFT"
echo "  ✓ Cluster redémarré en mode RAFT"
echo ""

echo "Avantages:"
echo "  • DB découplée de K3s"
echo "  • Plus de conflit de ports avec etcd"
echo "  • DCS intégré (pas de dépendance externe)"
echo "  • Failover automatique inchangé"
echo ""

echo "Prochaine étape:"
echo "  ./PATCH_02_haproxy_patroni_aware.sh"
echo ""
