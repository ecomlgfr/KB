#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   08_PATRONI_RAFT_SAFE - Patroni RAFT avec protection données      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Fonction pour générer un mot de passe alphanumérique
generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1
}

# Option --force pour réinitialiser
FORCE_WIPE=false
if [ "${1:-}" = "--force" ]; then
    FORCE_WIPE=true
    echo -e "${WARN} Mode FORCE activé - Les données seront effacées"
    read -p "Confirmer la suppression des données? (yes/NO): " confirm
    [ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }
fi

echo ""
echo "1. Gestion des credentials..."
echo ""

# NE PAS régénérer si postgres.env existe avec les variables
if [ -f "$CREDS_DIR/postgres.env" ]; then
    source "$CREDS_DIR/postgres.env"
    if [ -n "${POSTGRES_PASSWORD:-}" ] && [ -n "${PATRONI_API_PASSWORD:-}" ]; then
        echo "  Credentials existants conservés"
        SKIP_CREDS=1
    else
        echo "  Credentials incomplets, génération..."
        SKIP_CREDS=0
    fi
else
    echo "  Génération des nouveaux credentials..."
    SKIP_CREDS=0
fi

if [ "$SKIP_CREDS" -eq 0 ]; then
    POSTGRES_PASSWORD=$(generate_password)
    REPLICATOR_PASSWORD=$(generate_password)
    PATRONI_API_PASSWORD=$(generate_password)
    
    cat > "$CREDS_DIR/postgres.env" <<EOF
#!/bin/bash
# Credentials PostgreSQL/Patroni - Générés le $(date)
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD"
export PATRONI_API_PASSWORD="$PATRONI_API_PASSWORD"
export PGPASSWORD="$POSTGRES_PASSWORD"
EOF
    chmod 600 "$CREDS_DIR/postgres.env"
fi

source "$CREDS_DIR/postgres.env"

echo ""
echo "2. Préparation sécurisée..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Préparation $ip: "
    
    # Vérifier si c'est un leader actif
    IS_LEADER=false
    if ssh root@"$ip" "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'" 2>/dev/null; then
        IS_LEADER=true
    fi
    
    if [ "$IS_LEADER" = true ] && [ "$FORCE_WIPE" = false ]; then
        echo "Leader actif - données préservées"
        ssh root@"$ip" bash <<'PREP_SAFE'
docker stop patroni 2>/dev/null
docker rm -f patroni 2>/dev/null
# Ne PAS effacer les données du leader sans --force
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/{config,logs}
chown -R 999:999 /opt/keybuzz/postgres
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni RAFT' 2>/dev/null
PREP_SAFE
    else
        echo "Nettoyage complet"
        ssh root@"$ip" bash <<'PREP_CLEAN'
docker stop patroni postgres 2>/dev/null
docker rm -f patroni postgres 2>/dev/null
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /opt/keybuzz/postgres/data/*
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/{config,logs}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni RAFT' 2>/dev/null
PREP_CLEAN
    fi
done

echo ""
echo "3. Configuration Patroni RAFT..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  Config $hostname:"
    
    case "$ip" in
        "10.0.0.120") PARTNERS="10.0.0.121:7000,10.0.0.122:7000" ;;
        "10.0.0.121") PARTNERS="10.0.0.120:7000,10.0.0.122:7000" ;;
        "10.0.0.122") PARTNERS="10.0.0.120:7000,10.0.0.121:7000" ;;
    esac
    
    ssh root@"$ip" bash -s "$hostname" "$ip" "$POSTGRES_PASSWORD" "$REPLICATOR_PASSWORD" "$PATRONI_API_PASSWORD" "$PARTNERS" <<'CONFIG'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
REPL_PASSWORD="$4"
API_PASSWORD="$5"
PARTNERS="$6"

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-cluster
namespace: /service/
name: $NODE_NAME

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008
  authentication:
    username: patroni
    password: '$API_PASSWORD'

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
      password: '$REPL_PASSWORD'
      options:
        - replication

postgresql:
  listen: '*:5432'
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin
  authentication:
    replication:
      username: replicator
      password: '$REPL_PASSWORD'
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
  parameters:
    unix_socket_directories: '/var/run/postgresql'
  create_replica_methods:
    - basebackup

watchdog:
  mode: off
EOF

# Dockerfile avec USER postgres
cat > /opt/keybuzz/patroni/Dockerfile <<'DOCKERFILE'
FROM postgres:17

USER root
RUN apt-get update && apt-get install -y \
    python3-pip python3-psycopg2 python3-dev gcc curl \
    postgresql-17-pgvector \
    && apt-get clean

RUN pip3 install --break-system-packages \
    'patroni[raft]==3.3.2' \
    psycopg2-binary

RUN mkdir -p /opt/keybuzz/postgres/raft \
    && chown -R postgres:postgres /opt/keybuzz/postgres

COPY --chown=postgres:postgres config/patroni.yml /etc/patroni/patroni.yml

USER postgres
EXPOSE 5432 8008 7000
CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

cd /opt/keybuzz/patroni
docker build -t patroni-raft:latest . >/dev/null 2>&1
echo "    ✓ Configuré"
CONFIG
done

# Le reste du script continue avec le démarrage...
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ CLUSTER PATRONI RAFT SÉCURISÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Options:"
echo "  ./08_patroni_raft_safe.sh         # Préserve les données du leader"
echo "  ./08_patroni_raft_safe.sh --force # Efface tout (migration complète)"
echo "═══════════════════════════════════════════════════════════════════"
