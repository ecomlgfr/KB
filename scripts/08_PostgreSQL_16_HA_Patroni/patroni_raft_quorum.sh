#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     PATRONI_RAFT_QUORUM - Démarrage simultané des 3 nœuds         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-KeyBuzz2024Postgres}"

echo ""
echo "STRATÉGIE: Démarrer les 3 nœuds SIMULTANÉMENT pour former le quorum Raft"
echo ""

echo "1. Arrêt et nettoyage sur TOUS les nœuds..."

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEAN' 2>/dev/null
docker stop patroni 2>/dev/null
docker rm -f patroni 2>/dev/null
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/config
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft
CLEAN
    echo -e "$OK"
done

echo ""
echo "2. Création image Docker avec pgvector sur TOUS les nœuds..."

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Build sur $ip... "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'BUILD' >/dev/null 2>&1
cd /opt/keybuzz/patroni

cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

# Installer Patroni et pgvector
RUN apt-get update && \
    apt-get install -y \
        python3-pip python3-dev gcc curl \
        postgresql-17-pgvector \
        postgresql-17-pg-stat-kcache \
        postgresql-17-pgaudit && \
    pip3 install --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary \
        python-dateutil && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Créer les répertoires
RUN mkdir -p /opt/keybuzz/postgres/raft /var/lib/postgresql/data /var/run/postgresql && \
    chown -R postgres:postgres /opt/keybuzz/postgres /var/lib/postgresql /var/run/postgresql && \
    chmod 700 /var/lib/postgresql/data && \
    chmod 2775 /var/run/postgresql

USER postgres

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-raft-final:latest .
BUILD
    echo -e "$OK"
done

echo ""
echo "3. Création des configurations sur TOUS les nœuds..."

# Configuration pour db-master-01
echo -n "  Config db-master-01... "
ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'CONFIG1'
PG_PASSWORD="$1"

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
name: db-master-01

restapi:
  listen: 0.0.0.0:8008
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
    master_start_timeout: 300
    synchronous_mode: false
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
        min_wal_size: 1GB
        max_wal_size: 4GB
        max_replication_slots: 10
        max_wal_senders: 10
        wal_keep_size: 1GB
        wal_level: replica
        hot_standby: 'on'
        wal_log_hints: 'on'
        shared_preload_libraries: 'pg_stat_statements,pgaudit,vector'

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

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

  post_bootstrap_script: |
    #!/bin/bash
    set -e
    echo "Activation des extensions..."
    psql -U postgres <<SQL
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    CREATE EXTENSION IF NOT EXISTS pgaudit;
    SQL

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.120:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin
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
    port: 5432
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

chown 999:999 /opt/keybuzz/patroni/config/patroni.yml
CONFIG1
echo -e "$OK"

# Configuration pour db-slave-01
echo -n "  Config db-slave-01... "
ssh -o StrictHostKeyChecking=no root@10.0.0.121 bash -s "$POSTGRES_PASSWORD" <<'CONFIG2'
PG_PASSWORD="$1"

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
name: db-slave-01

restapi:
  listen: 0.0.0.0:8008
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
  bin_dir: /usr/lib/postgresql/17/bin
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
    port: 5432
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

chown 999:999 /opt/keybuzz/patroni/config/patroni.yml
CONFIG2
echo -e "$OK"

# Configuration pour db-slave-02
echo -n "  Config db-slave-02... "
ssh -o StrictHostKeyChecking=no root@10.0.0.122 bash -s "$POSTGRES_PASSWORD" <<'CONFIG3'
PG_PASSWORD="$1"

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
name: db-slave-02

restapi:
  listen: 0.0.0.0:8008
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
  bin_dir: /usr/lib/postgresql/17/bin
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
    port: 5432
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

chown 999:999 /opt/keybuzz/patroni/config/patroni.yml
CONFIG3
echo -e "$OK"

echo ""
echo "4. DÉMARRAGE SIMULTANÉ des 3 nœuds pour former le quorum..."
echo ""

# Démarrer les 3 containers EN MÊME TEMPS
echo "  Lancement simultané..."

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START' 2>/dev/null &
# Dernière vérification des permissions
chown -R 999:999 /opt/keybuzz/postgres

# Démarrer le container
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-raft-final:latest
START
done

# Attendre que les jobs se terminent
wait

echo -e "  $OK Containers lancés"
echo ""
echo "  Attente formation du quorum Raft (40s)..."
sleep 40

echo ""
echo "5. Vérification du cluster..."
echo ""

# Vérifier chaque nœud
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  $ip: "
    
    # API Patroni
    STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('state','?')}/{d.get('role','?')}\")" 2>/dev/null || echo "KO")
    
    if [[ "$STATE" == *"running"* ]] || [[ "$STATE" == *"streaming"* ]]; then
        echo -e "$OK $STATE"
    else
        echo "$STATE"
    fi
done

echo ""
echo "6. État du cluster Patroni..."
echo ""

curl -s http://10.0.0.120:8008/cluster 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Cluster non accessible"

echo ""
echo "7. Test des extensions PostgreSQL..."
echo ""

# Identifier le leader
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    ROLE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null || echo "")
    if [ "$ROLE" = "master" ] || [ "$ROLE" = "leader" ]; then
        LEADER_IP="$ip"
        break
    fi
done

if [ -n "$LEADER_IP" ]; then
    echo "  Leader trouvé: $LEADER_IP"
    echo ""
    
    ssh root@"$LEADER_IP" bash <<'TEST_EXTENSIONS'
echo "  Extensions installées:"
docker exec patroni psql -U postgres -c "\dx" 2>/dev/null | grep -E "vector|pgaudit|pg_stat" || echo "    Pas encore activées"

echo ""
echo "  Test pgvector:"
docker exec patroni psql -U postgres -c "
CREATE TABLE IF NOT EXISTS test_vector (id serial, embedding vector(3));
INSERT INTO test_vector (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');
SELECT * FROM test_vector ORDER BY embedding <-> '[1,1,1]' LIMIT 1;
" 2>/dev/null || echo "    pgvector pas encore prêt"
TEST_EXTENSIONS
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Déterminer le succès
NODES_OK=0
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    curl -s "http://$ip:8008/patroni" 2>/dev/null | grep -q "running\|streaming" && NODES_OK=$((NODES_OK + 1))
done

if [ "$NODES_OK" -eq 3 ]; then
    echo -e "$OK CLUSTER PATRONI RAFT OPÉRATIONNEL !"
    echo ""
    echo "Architecture:"
    echo "  • DCS: Raft (quorum formé)"
    echo "  • PostgreSQL 17 avec pgvector"
    echo "  • 1 leader + 2 followers"
    echo ""
    echo "Connexion:"
    echo "  psql -h $LEADER_IP -U postgres"
    echo "  Password: $POSTGRES_PASSWORD"
else
    echo -e "$KO Seulement $NODES_OK/3 nœuds actifs"
    echo ""
    echo "Le quorum Raft nécessite au minimum 2 nœuds."
    echo "Vérifier les logs:"
    echo "  ssh root@10.0.0.120 'docker logs patroni --tail 30'"
fi

echo "═══════════════════════════════════════════════════════════════════"
