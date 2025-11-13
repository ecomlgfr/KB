#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    04_POSTGRES16_PATRONI_RAFT - PostgreSQL 16 + Patroni RAFT       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_FILE="/opt/keybuzz-installer/logs/postgres_patroni_$(date +%Y%m%d_%H%M%S).log"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

mkdir -p "$CREDS_DIR" "$(dirname "$LOG_FILE")"

# Fonction pour générer un mot de passe sécurisé
generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 24 | head -n 1
}

echo "" | tee -a "$LOG_FILE"
echo "═══ 1. Gestion des credentials ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Charger ou générer les credentials
if [ -f "$CREDS_DIR/postgres.env" ]; then
    source "$CREDS_DIR/postgres.env"
    
    if [ -z "${POSTGRES_PASSWORD:-}" ] || [ -z "${REPLICATOR_PASSWORD:-}" ] || [ -z "${PATRONI_API_PASSWORD:-}" ]; then
        echo "  Credentials incomplets, régénération..." | tee -a "$LOG_FILE"
        NEED_GEN=true
    else
        echo "  Credentials existants conservés" | tee -a "$LOG_FILE"
        NEED_GEN=false
    fi
else
    echo "  Génération des nouveaux credentials..." | tee -a "$LOG_FILE"
    NEED_GEN=true
fi

if [ "$NEED_GEN" = true ]; then
    POSTGRES_PASSWORD=$(generate_password)
    REPLICATOR_PASSWORD=$(generate_password)
    PATRONI_API_PASSWORD=$(generate_password)
    
    cat > "$CREDS_DIR/postgres.env" <<EOF
#!/bin/bash
# Credentials PostgreSQL/Patroni - Générés le $(date '+%Y-%m-%d %H:%M:%S')

export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD"
export PATRONI_API_PASSWORD="$PATRONI_API_PASSWORD"
export PGPASSWORD="$POSTGRES_PASSWORD"

# URLs de connexion
export DATABASE_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:5432/postgres"
export KEYBUZZ_DATABASE_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:5432/keybuzz"
export N8N_DATABASE_URL="postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.10:5432/n8n"
export CHATWOOT_DATABASE_URL="postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.10:5432/chatwoot"

# HAProxy
export HAPROXY_WRITE_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.11:5432/postgres"
export HAPROXY_READ_URL="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.11:5433/postgres"
EOF
    
    chmod 600 "$CREDS_DIR/postgres.env"
    echo "  ✓ Nouveaux credentials générés" | tee -a "$LOG_FILE"
fi

source "$CREDS_DIR/postgres.env"

echo "" | tee -a "$LOG_FILE"
echo "═══ 2. Configuration des nœuds ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Mapping des nœuds
declare -A NODE_IPS=(
    [db-master-01]="10.0.0.120"
    [db-slave-01]="10.0.0.121"
    [db-slave-02]="10.0.0.122"
)

# Fonction pour créer la configuration Patroni
create_patroni_config() {
    local node_name="$1"
    local node_ip="$2"
    local partners="$3"
    
    cat <<EOF
scope: postgres-cluster
namespace: /service/
name: $node_name

restapi:
  listen: ${node_ip}:8008
  connect_address: ${node_ip}:8008
  authentication:
    username: patroni
    password: '${PATRONI_API_PASSWORD}'

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${node_ip}:7000
  partner_addrs:
$(echo "$partners" | tr ',' '\n' | awk '{print "    - " $1}')

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
        work_mem: 16MB
        maintenance_work_mem: 256MB
        wal_level: replica
        max_wal_size: 4GB
        min_wal_size: 512MB
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        archive_mode: 'on'
        archive_command: 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        hot_standby: 'on'
        wal_log_hints: 'on'
        track_commit_timestamp: 'on'
        random_page_cost: 1.1
        effective_io_concurrency: 200

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
      password: '${POSTGRES_PASSWORD}'
      options:
        - superuser
    replicator:
      password: '${REPLICATOR_PASSWORD}'
      options:
        - replication

postgresql:
  listen: '*:5432'
  connect_address: ${node_ip}:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    replication:
      username: replicator
      password: '${REPLICATOR_PASSWORD}'
    superuser:
      username: postgres
      password: '${POSTGRES_PASSWORD}'
  parameters:
    unix_socket_directories: '/var/run/postgresql'
  create_replica_methods:
    - basebackup

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
}

# Configurer chaque nœud
for node_name in db-master-01 db-slave-01 db-slave-02; do
    node_ip="${NODE_IPS[$node_name]}"
    
    # Définir les partners
    case "$node_name" in
        db-master-01) partners="10.0.0.121:7000,10.0.0.122:7000" ;;
        db-slave-01)  partners="10.0.0.120:7000,10.0.0.122:7000" ;;
        db-slave-02)  partners="10.0.0.120:7000,10.0.0.121:7000" ;;
    esac
    
    echo "→ Configuration $node_name ($node_ip)" | tee -a "$LOG_FILE"
    
    # Créer la config Patroni localement
    config_content=$(create_patroni_config "$node_name" "$node_ip" "$partners")
    
    # Transférer et déployer
    ssh -o StrictHostKeyChecking=no root@"$node_ip" bash -s "$node_name" <<DEPLOY
set -u
set -o pipefail

# Préparer les répertoires
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/{config,logs}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 755 /opt/keybuzz/postgres/raft

# Écrire la config Patroni
cat > /opt/keybuzz/patroni/config/patroni.yml <<'CONFIG'
$config_content
CONFIG

# Créer le Dockerfile
cat > /opt/keybuzz/patroni/Dockerfile <<'DOCKERFILE'
FROM postgres:16

USER root

# Installer les dépendances
RUN apt-get update && apt-get install -y \\
    python3-pip python3-psycopg2 python3-dev gcc curl \\
    postgresql-16-pgvector \\
    && apt-get clean \\
    && rm -rf /var/lib/apt/lists/*

# Installer Patroni avec RAFT
RUN pip3 install --break-system-packages \\
    'patroni[raft]==3.3.2' \\
    psycopg2-binary

# Créer les répertoires nécessaires
RUN mkdir -p /opt/keybuzz/postgres/raft \\
    && chown -R postgres:postgres /opt/keybuzz/postgres

# Copier la configuration
COPY --chown=postgres:postgres config/patroni.yml /etc/patroni/patroni.yml

USER postgres

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

# Build l'image
cd /opt/keybuzz/patroni
docker build -t patroni-pg16-raft:latest . >/dev/null 2>&1

if [ \$? -eq 0 ]; then
    echo "  ✓ Image construite"
else
    echo "  ✗ Échec build image"
    exit 1
fi
DEPLOY
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Configuration terminée" | tee -a "$LOG_FILE"
    else
        echo -e "  $KO Échec configuration" | tee -a "$LOG_FILE"
        exit 1
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "═══ 3. Démarrage du cluster ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Démarrer le premier nœud (bootstrap)
echo "→ Bootstrap db-master-01 (premier nœud)" | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'START'
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg16-raft:latest

if [ $? -eq 0 ]; then
    echo "  ✓ Conteneur démarré"
else
    echo "  ✗ Échec démarrage"
    docker logs patroni 2>&1 | tail -20
    exit 1
fi
START

echo "  Attente initialisation (45s)..." | tee -a "$LOG_FILE"
sleep 45

# Vérifier le bootstrap
echo -n "  Vérification bootstrap: " | tee -a "$LOG_FILE"
if ssh -o StrictHostKeyChecking=no root@10.0.0.120 \
    "docker exec patroni psql -U postgres -c 'SELECT 1' -t 2>/dev/null | grep -q '1'"; then
    echo -e "$OK" | tee -a "$LOG_FILE"
else
    echo -e "$KO" | tee -a "$LOG_FILE"
    echo "  Logs:" | tee -a "$LOG_FILE"
    ssh -o StrictHostKeyChecking=no root@10.0.0.120 "docker logs patroni 2>&1 | tail -30" | tee -a "$LOG_FILE"
    exit 1
fi

# Démarrer les replicas
for node in "db-slave-01:10.0.0.121" "db-slave-02:10.0.0.122"; do
    IFS=':' read -r node_name node_ip <<< "$node"
    echo "" | tee -a "$LOG_FILE"
    echo "→ Démarrage $node_name" | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$node_ip" bash -s "$node_name" <<'START'
NODE_NAME="$1"
docker run -d \
  --name patroni \
  --hostname $NODE_NAME \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg16-raft:latest

sleep 2
if docker ps | grep -q patroni; then
    echo "  ✓ Conteneur démarré"
else
    echo "  ✗ Échec"
    docker logs patroni 2>&1 | tail -20
    exit 1
fi
START
    
    [ $? -eq 0 ] && echo -e "  $OK" | tee -a "$LOG_FILE" || echo -e "  $KO" | tee -a "$LOG_FILE"
done

echo "" | tee -a "$LOG_FILE"
echo "  Attente synchronisation (30s)..." | tee -a "$LOG_FILE"
sleep 30

echo "" | tee -a "$LOG_FILE"
echo "═══ 4. Création des bases et utilisateurs ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Trouver le leader
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    if ssh -o StrictHostKeyChecking=no root@"$ip" \
        "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'"; then
        LEADER_IP="$ip"
        echo "  Leader identifié: $ip" | tee -a "$LOG_FILE"
        break
    fi
done

if [ -z "$LEADER_IP" ]; then
    echo -e "$KO Aucun leader trouvé" | tee -a "$LOG_FILE"
    exit 1
fi

# Créer les bases et users
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" <<'SETUP_DBS'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Créer les utilisateurs applicatifs
CREATE USER IF NOT EXISTS n8n WITH PASSWORD '${PG_PASSWORD}';
CREATE USER IF NOT EXISTS chatwoot WITH PASSWORD '${PG_PASSWORD}';
CREATE USER IF NOT EXISTS pgbouncer WITH PASSWORD '${PG_PASSWORD}';

-- Créer les bases
CREATE DATABASE IF NOT EXISTS keybuzz;
CREATE DATABASE IF NOT EXISTS n8n OWNER n8n;
CREATE DATABASE IF NOT EXISTS chatwoot OWNER chatwoot;

-- Extensions sur keybuzz
\c keybuzz
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Extensions sur n8n
\c n8n
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Extensions sur chatwoot
\c chatwoot
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Permissions
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
SQL

if [ $? -eq 0 ]; then
    echo "  ✓ Bases et utilisateurs créés"
else
    echo "  ✗ Échec création bases"
    exit 1
fi
SETUP_DBS

[ $? -eq 0 ] && echo -e "  $OK" | tee -a "$LOG_FILE" || echo -e "  $KO" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "═══ 5. Vérification du cluster ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

SUCCESS=0
for node_name in db-master-01 db-slave-01 db-slave-02; do
    node_ip="${NODE_IPS[$node_name]}"
    echo -n "  $node_name ($node_ip): " | tee -a "$LOG_FILE"
    
    # Test conteneur
    if ! ssh -o StrictHostKeyChecking=no root@"$node_ip" "docker ps | grep -q patroni"; then
        echo -e "$KO conteneur arrêté" | tee -a "$LOG_FILE"
        continue
    fi
    
    # Test connexion
    if ssh -o StrictHostKeyChecking=no root@"$node_ip" \
        "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
        
        # Vérifier le rôle
        IS_LEADER=$(ssh -o StrictHostKeyChecking=no root@"$node_ip" \
            "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
        
        if [ "$IS_LEADER" = "f" ]; then
            echo -e "$OK Leader" | tee -a "$LOG_FILE"
        else
            echo -e "$OK Replica" | tee -a "$LOG_FILE"
        fi
        ((SUCCESS++))
    else
        echo -e "$KO Non prêt" | tee -a "$LOG_FILE"
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"

if [ $SUCCESS -eq 3 ]; then
    echo -e "$OK CLUSTER PATRONI RAFT OPÉRATIONNEL ($SUCCESS/3 nœuds)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Credentials: $CREDS_DIR/postgres.env" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Test connexion:" | tee -a "$LOG_FILE"
    echo "  export PGPASSWORD='$POSTGRES_PASSWORD'" | tee -a "$LOG_FILE"
    echo "  psql -h ${LEADER_IP} -U postgres -d keybuzz -c 'SELECT version()'" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "API Patroni:" | tee -a "$LOG_FILE"
    echo "  curl -u patroni:$PATRONI_API_PASSWORD http://${LEADER_IP}:8008/cluster" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Prochaine étape: ./05_haproxy_db.sh" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    echo "OK" > /opt/keybuzz/postgres/status/STATE
    
    tail -n 50 "$LOG_FILE"
    exit 0
else
    echo -e "$KO CLUSTER NON OPÉRATIONNEL ($SUCCESS/3 nœuds)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    echo "KO" > /opt/keybuzz/postgres/status/STATE
    
    tail -n 50 "$LOG_FILE"
    exit 1
fi
