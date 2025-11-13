#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FINAL_FIX_PATRONI_RAFT - Correction définitive             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Configuration
DB_NODES=(db-master-01 db-slave-01 db-slave-02)
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-KeyBuzz2024Postgres}"

# IPs fixes
declare -A NODE_IPS
NODE_IPS[db-master-01]="10.0.0.120"
NODE_IPS[db-slave-01]="10.0.0.121" 
NODE_IPS[db-slave-02]="10.0.0.122"

echo ""
echo "1. Arrêt complet et nettoyage..."

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEAN' 2>/dev/null
# Arrêt forcé
docker stop patroni 2>/dev/null
docker rm -f patroni 2>/dev/null

# Nettoyage complet
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /opt/keybuzz/postgres/archive/*
rm -rf /opt/keybuzz/patroni/config/patroni.yml

# Recréer structure
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/config

# Permissions correctes
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft
CLEAN
    echo -e "$OK"
done

echo ""
echo "2. Création des configurations CORRECTES..."

# Configuration pour db-master-01
echo "  Configuration db-master-01..."
ssh -o StrictHostKeyChecking=no root@"10.0.0.120" bash -s "$POSTGRES_PASSWORD" <<'MASTER_CONFIG'
PG_PASSWORD="$1"

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: db-master-01

restapi:
  listen: 10.0.0.120:8008
  connect_address: 10.0.0.120:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.120:7000
  partner_addrs:
    - 10.0.0.121:7000
    - 10.0.0.122:7000

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: false
      use_slots: true
      parameters:
        max_connections: 100
        shared_buffers: 256MB
        effective_cache_size: 1GB
        maintenance_work_mem: 256MB
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        min_wal_size: 1GB
        max_wal_size: 4GB
        max_replication_slots: 10
        max_wal_senders: 10
        wal_keep_size: 1GB
        wal_level: replica
        hot_standby: 'on'
        wal_log_hints: 'on'
        archive_mode: 'on'
        archive_command: 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'
        archive_timeout: 1800s

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all ::1/128 trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5

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
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.120:5432
  data_dir: /var/lib/postgresql/data
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
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
EOF

echo "    Config créée"
MASTER_CONFIG

# Configuration pour db-slave-01
echo "  Configuration db-slave-01..."
ssh -o StrictHostKeyChecking=no root@"10.0.0.121" bash -s "$POSTGRES_PASSWORD" <<'SLAVE1_CONFIG'
PG_PASSWORD="$1"

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: db-slave-01

restapi:
  listen: 10.0.0.121:8008
  connect_address: 10.0.0.121:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.121:7000
  partner_addrs:
    - 10.0.0.120:7000
    - 10.0.0.122:7000

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.121:5432
  data_dir: /var/lib/postgresql/data
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
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
EOF

echo "    Config créée"
SLAVE1_CONFIG

# Configuration pour db-slave-02
echo "  Configuration db-slave-02..."
ssh -o StrictHostKeyChecking=no root@"10.0.0.122" bash -s "$POSTGRES_PASSWORD" <<'SLAVE2_CONFIG'
PG_PASSWORD="$1"

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: db-slave-02

restapi:
  listen: 10.0.0.122:8008
  connect_address: 10.0.0.122:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.122:7000
  partner_addrs:
    - 10.0.0.120:7000
    - 10.0.0.121:7000

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.122:5432
  data_dir: /var/lib/postgresql/data
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
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
EOF

echo "    Config créée"
SLAVE2_CONFIG

echo ""
echo "3. Vérification des images Docker..."

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    # Vérifier si l'image existe et la reconstruire si nécessaire
    if ! ssh -o StrictHostKeyChecking=no root@"$ip" "docker images | grep -q patroni-pg17-raft" 2>/dev/null; then
        echo -n "Build... "
        ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'BUILD' >/dev/null 2>&1
cd /opt/keybuzz/patroni

cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17-alpine

RUN apk add --no-cache python3 py3-pip python3-dev gcc musl-dev linux-headers && \
    pip3 install --no-cache-dir --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary \
        python-dateutil && \
    apk del gcc musl-dev linux-headers

EXPOSE 5432 8008 7000

USER postgres

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-pg17-raft:latest .
BUILD
        echo -e "$OK"
    else
        echo -e "$OK (existe)"
    fi
done

echo ""
echo "4. Test des ports réseau..."

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node - Port 7000: "
    
    # S'assurer que le port 7000 est ouvert dans UFW
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'PORTS' 2>/dev/null
# Ouvrir le port 7000
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni Raft' 2>/dev/null
ufw allow 8008/tcp comment 'Patroni API' 2>/dev/null
ufw allow 5432/tcp comment 'PostgreSQL' 2>/dev/null
ufw --force reload >/dev/null 2>&1

# Vérifier qu'aucun process n'utilise déjà le port
fuser -k 7000/tcp 2>/dev/null || true
PORTS
    echo -e "$OK"
done

echo ""
echo "5. Démarrage séquentiel du cluster..."

# Démarrer UNIQUEMENT db-master-01 d'abord
echo "  Démarrage db-master-01 (leader initial)..."
ssh -o StrictHostKeyChecking=no root@"10.0.0.120" bash <<'START_LEADER'
# S'assurer que les permissions sont correctes
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/raft

# Démarrer le container
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  --user 999:999 \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg17-raft:latest
START_LEADER

echo "  Attente initialisation leader (30s)..."
sleep 30

# Vérifier que le leader est bien initialisé
echo -n "  Vérification leader: "
if curl -s http://10.0.0.120:8008/patroni 2>/dev/null | grep -q "running"; then
    echo -e "$OK"
    
    # Démarrer les replicas seulement si le leader est OK
    echo ""
    echo "  Démarrage des replicas..."
    
    for node in db-slave-01 db-slave-02; do
        ip="${NODE_IPS[$node]}"
        echo -n "    $node: "
        
        ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START_REPLICA'
# Permissions
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/raft

# Démarrer
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  --user 999:999 \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg17-raft:latest
START_REPLICA
        echo -e "$OK"
        sleep 5
    done
else
    echo -e "$KO"
    echo "  Leader non initialisé, vérification des logs:"
    ssh -o StrictHostKeyChecking=no root@"10.0.0.120" \
        "docker logs patroni --tail 20 2>&1 | grep -E 'ERROR|error|Failed'" | head -10
fi

echo ""
echo "6. Attente stabilisation complète (20s)..."
sleep 20

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAT FINAL DU CLUSTER"
echo "═══════════════════════════════════════════════════════════════════"

# Vérification finale
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo ""
    echo "$node ($ip):"
    
    # Container
    echo -n "  Container: "
    if ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q patroni" 2>/dev/null; then
        echo -e "$OK"
        
        # API
        echo -n "  API: "
        STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('state','?')}/{d.get('role','?')}\")" 2>/dev/null || echo "KO")
        if [[ "$STATE" == *"running"* ]] || [[ "$STATE" == *"streaming"* ]]; then
            echo -e "$OK ($STATE)"
        else
            echo -e "$KO ($STATE)"
        fi
        
        # PostgreSQL
        echo -n "  PostgreSQL: "
        if ssh -o StrictHostKeyChecking=no root@"$ip" \
            "docker exec patroni pg_isready -h localhost" 2>/dev/null | grep -q "accepting"; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    else
        echo -e "$KO"
    fi
done

echo ""
echo "Cluster Patroni:"
curl -s http://10.0.0.120:8008/cluster 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Non accessible"

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Test final
LEADER_OK=false
if curl -s http://10.0.0.120:8008/cluster 2>/dev/null | grep -q '"role":"leader"'; then
    LEADER_OK=true
fi

if [ "$LEADER_OK" = true ]; then
    echo -e "$OK CLUSTER PATRONI RAFT OPÉRATIONNEL"
    echo ""
    echo "Test PostgreSQL:"
    echo "  psql -h 10.0.0.120 -U postgres -d postgres"
else
    echo -e "$KO CLUSTER NON OPÉRATIONNEL"
    echo ""
    echo "Débugger avec:"
    echo "  ssh root@10.0.0.120 'docker logs patroni --tail 50'"
fi

echo "═══════════════════════════════════════════════════════════════════"
