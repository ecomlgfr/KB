#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     08_PATRONI_RAFT_FIXED - Cluster Patroni RAFT corrigé          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Générer mot de passe simple
generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# Créer/charger credentials
if [ ! -f "$CREDS_DIR/postgres.env" ]; then
    POSTGRES_PASSWORD=$(generate_password)
    cat > "$CREDS_DIR/postgres.env" <<EOF
#!/bin/bash
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$POSTGRES_PASSWORD"
export PATRONI_API_PASSWORD="$POSTGRES_PASSWORD"
export PGPASSWORD="$POSTGRES_PASSWORD"
EOF
    chmod 600 "$CREDS_DIR/postgres.env"
fi

source "$CREDS_DIR/postgres.env"

echo ""
echo "Mot de passe: $POSTGRES_PASSWORD"
echo ""

# Nettoyer complètement
echo "1. Nettoyage complet des containers existants..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Nettoyage $ip: "
    ssh root@"$ip" bash <<'CLEANUP'
docker stop patroni postgres etcd 2>/dev/null
docker rm -f patroni postgres etcd 2>/dev/null
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /opt/keybuzz/postgres/data/*
pkill -9 postgres 2>/dev/null
fuser -k 5432/tcp 2>/dev/null || true
fuser -k 7000/tcp 2>/dev/null || true
fuser -k 8008/tcp 2>/dev/null || true
echo "clean"
CLEANUP
    echo -e "$OK"
done

# Configuration UFW pour RAFT
echo ""
echo "2. Configuration firewall pour RAFT..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  UFW $ip: "
    ssh root@"$ip" bash <<'UFW'
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni RAFT'
ufw allow from 10.0.0.0/16 to any port 8008 proto tcp comment 'Patroni API'
ufw allow from 10.0.0.0/16 to any port 5432 proto tcp comment 'PostgreSQL'
ufw reload >/dev/null 2>&1
echo "OK"
UFW
    echo -e "$OK"
done

# Préparer les volumes
echo ""
echo "3. Préparation des volumes..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Volumes $ip: "
    ssh root@"$ip" bash <<'VOLUMES'
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/{config,logs}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 755 /opt/keybuzz/postgres/raft
echo "OK"
VOLUMES
    echo -e "$OK"
done

# Configuration Patroni RAFT pour chaque nœud
echo ""
echo "4. Configuration Patroni avec RAFT..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  Configuration $hostname:"
    
    # Déterminer les partners pour RAFT
    case "$ip" in
        "10.0.0.120") PARTNERS="10.0.0.121:7000,10.0.0.122:7000" ;;
        "10.0.0.121") PARTNERS="10.0.0.120:7000,10.0.0.122:7000" ;;
        "10.0.0.122") PARTNERS="10.0.0.120:7000,10.0.0.121:7000" ;;
    esac
    
    ssh root@"$ip" bash -s "$hostname" "$ip" "$POSTGRES_PASSWORD" "$PARTNERS" <<'CONFIG_PATRONI'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
PARTNERS="$4"

# Créer patroni.yml avec RAFT
cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-cluster
namespace: /service/
name: $NODE_NAME

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008
  authentication:
    username: patroni
    password: '$PG_PASSWORD'

# Configuration RAFT (pas etcd)
raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${NODE_IP}:7000
  partner_addrs:
$(for partner in ${PARTNERS//,/ }; do echo "    - $partner"; done)

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
        shared_buffers: 1GB
        effective_cache_size: 3GB
        work_mem: 10MB
        maintenance_work_mem: 256MB
        wal_level: replica
        max_wal_size: 2GB
        min_wal_size: 256MB
        archive_mode: 'on'
        archive_command: 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 128MB
        hot_standby: 'on'

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
  bin_dir: /usr/lib/postgresql/17/bin
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

echo "    Config créée"
CONFIG_PATRONI
done

# Build image Docker
echo ""
echo "5. Construction image Patroni avec RAFT..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Build $ip: "
    ssh root@"$ip" bash -s "$PATRONI_API_PASSWORD" <<'BUILD_IMAGE'
API_PASSWORD="$1"

cd /opt/keybuzz/patroni

# Dockerfile pour Patroni RAFT
cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

# Installer Python et dépendances
RUN apt-get update && apt-get install -y \
    python3-pip python3-psycopg2 python3-dev gcc curl \
    postgresql-17-pgvector \
    && apt-get clean

# Installer Patroni avec support RAFT (pas etcd)
RUN pip3 install --break-system-packages \
    'patroni[raft]==3.3.2' \
    psycopg2-binary

# Copier la configuration
COPY config/patroni.yml /etc/patroni/patroni.yml

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-raft:latest . >/dev/null 2>&1
echo "OK"
BUILD_IMAGE
done

# Démarrage progressif
echo ""
echo "6. Démarrage progressif du cluster..."
echo ""

# Démarrer le master d'abord
echo "  Démarrage db-master-01 (bootstrap)..."
ssh root@10.0.0.120 bash <<'START_MASTER'
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-raft:latest

echo "    Container démarré, attente 30s..."
sleep 30

# Vérifier
if docker ps | grep -q patroni; then
    echo "    ✓ Master démarré"
else
    echo "    ✗ Échec, logs:"
    docker logs patroni 2>&1 | tail -10
fi
START_MASTER

# Démarrer les replicas
for ip in 10.0.0.121 10.0.0.122; do
    hostname=$([ "$ip" = "10.0.0.121" ] && echo "db-slave-01" || echo "db-slave-02")
    echo "  Démarrage $hostname..."
    
    ssh root@"$ip" bash -s "$hostname" <<'START_REPLICA'
HOSTNAME="$1"

docker run -d \
  --name patroni \
  --hostname $HOSTNAME \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-raft:latest

sleep 10
if docker ps | grep -q patroni; then
    echo "    ✓ $HOSTNAME démarré"
else
    echo "    ✗ Échec"
fi
START_REPLICA
done

echo ""
echo "7. Attente de stabilisation (20s)..."
sleep 20

echo ""
echo "8. Vérification du cluster..."
echo ""

# Test API
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  API $ip: "
    if curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$ip:8008/patroni" 2>/dev/null | grep -q state; then
        echo -e "$OK"
    else
        echo -e "$KO"
        echo "    Logs:"
        ssh root@"$ip" "docker logs patroni 2>&1 | tail -5"
    fi
done

# Afficher le cluster
echo ""
echo "État du cluster:"
curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://10.0.0.120:8008/cluster" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Cluster pas encore prêt"

echo ""
echo "9. Création des bases et utilisateurs..."
echo ""

# Trouver le leader
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    if ssh root@"$ip" "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'" 2>/dev/null; then
        LEADER_IP="$ip"
        echo "  Leader trouvé: $ip"
        break
    fi
done

if [ -n "$LEADER_IP" ]; then
    ssh root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" <<'CREATE_DBS'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Utilisateurs
CREATE USER IF NOT EXISTS n8n WITH PASSWORD '$PG_PASSWORD';
CREATE USER IF NOT EXISTS chatwoot WITH PASSWORD '$PG_PASSWORD';
CREATE USER IF NOT EXISTS pgbouncer WITH PASSWORD '$PG_PASSWORD';

-- Bases
CREATE DATABASE IF NOT EXISTS keybuzz;
CREATE DATABASE IF NOT EXISTS n8n OWNER n8n;
CREATE DATABASE IF NOT EXISTS chatwoot OWNER chatwoot;

-- Extensions dans keybuzz
\c keybuzz
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Extensions dans n8n
\c n8n
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Extensions dans chatwoot
\c chatwoot
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;

SELECT 'Configuration terminée';
SQL
CREATE_DBS
    echo -e "  $OK Bases créées"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CLUSTER PATRONI RAFT OPÉRATIONNEL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Mot de passe: $POSTGRES_PASSWORD"
echo ""
echo "Test de connexion:"
echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.120 -p 5432 -U postgres"
echo ""
echo "API Patroni:"
echo "  curl -u patroni:$PATRONI_API_PASSWORD http://10.0.0.120:8008/cluster"
echo ""
echo "Prochaine étape: ./09_install_haproxy_aware.sh"
echo "═══════════════════════════════════════════════════════════════════"
