#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          FIX_ALL_ISSUES - Correction complète du cluster           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

echo ""
echo "1. Installation du client PostgreSQL sur install-01..."
echo ""

if ! command -v psql &>/dev/null; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y postgresql-client -qq >/dev/null 2>&1
    echo -e "  $OK psql installé"
else
    echo -e "  $OK psql déjà présent"
fi

echo ""
echo "2. Génération de nouveaux mots de passe SANS caractères spéciaux..."
echo ""

# Générer des mots de passe alphanumériques uniquement
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/!@#$%^&*(){}[]|\\:;\"'<>,.?" | cut -c1-20)
REPLICATOR_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/!@#$%^&*(){}[]|\\:;\"'<>,.?" | cut -c1-20)
PATRONI_API_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/!@#$%^&*(){}[]|\\:;\"'<>,.?" | cut -c1-20)

echo "  Nouveaux mots de passe générés (alphanumériques uniquement)"

# Sauvegarder dans le fichier de credentials
CREDS_FILE="/opt/keybuzz-installer/credentials/postgres.env"
cat > "$CREDS_FILE" <<EOF
#!/bin/bash
# PostgreSQL Credentials - Updated $(date)
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD"
export PATRONI_API_PASSWORD="$PATRONI_API_PASSWORD"
export PGBOUNCER_PASSWORD="$POSTGRES_PASSWORD"

# Connection strings
export MASTER_DSN="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.120:5432/postgres"
export REPLICA_DSN="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.121:5432/postgres"
export VIP_DSN="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:5432/postgres"
EOF

chmod 600 "$CREDS_FILE"
echo -e "  $OK Credentials sauvegardés"

echo ""
echo "3. Arrêt de tous les services..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Arrêt sur $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STOP' 2>/dev/null
docker stop patroni pgbouncer 2>/dev/null
docker rm patroni pgbouncer 2>/dev/null
rm -rf /opt/keybuzz/postgres/raft/*
STOP
    echo -e "$OK"
done

echo ""
echo "4. Mise à jour des configurations Patroni avec les nouveaux mots de passe..."
echo ""

# Fonction pour générer la config
generate_patroni_config() {
    local ip="$1"
    local hostname="$2"
    local is_bootstrap="$3"
    
    # Déterminer les partenaires
    local partners=""
    for peer_ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
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

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${ip}:7000
  partner_addrs:
$partners

EOF

    if [ "$is_bootstrap" = "true" ]; then
        cat <<EOF
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 33554432
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        shared_buffers: 512MB
        wal_level: replica
        hot_standby: 'on'
        wal_log_hints: 'on'
        shared_preload_libraries: 'pg_stat_statements,pgaudit,vector'

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5

  users:
    postgres:
      password: '$POSTGRES_PASSWORD'
      options:
        - createrole
        - createdb
    replicator:
      password: '$REPLICATOR_PASSWORD'
      options:
        - replication

EOF
    fi
    
    cat <<EOF
postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${ip}:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin
  authentication:
    superuser:
      username: postgres
      password: '$POSTGRES_PASSWORD'
    replication:
      username: replicator
      password: '$REPLICATOR_PASSWORD'
  parameters:
    unix_socket_directories: '/var/run/postgresql'
    port: 5432

watchdog:
  mode: off
EOF
}

# Déployer les configs
for i in 0 1 2; do
    ips=(10.0.0.120 10.0.0.121 10.0.0.122)
    hostnames=(db-master-01 db-slave-01 db-slave-02)
    
    ip="${ips[$i]}"
    hostname="${hostnames[$i]}"
    is_bootstrap="false"
    [ $i -eq 0 ] && is_bootstrap="true"
    
    echo -n "  Config $hostname: "
    
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
echo "5. Démarrage simultané du cluster Patroni..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START' 2>/dev/null &
chown -R 999:999 /opt/keybuzz/postgres

docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni:17-raft
START
done

wait
echo -e "  $OK Containers lancés"

echo "  Attente formation du quorum (40s)..."
sleep 40

echo ""
echo "6. Configuration PgBouncer avec les nouveaux mots de passe..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  PgBouncer $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$POSTGRES_PASSWORD" "$ip" <<'PGBOUNCER'
PG_PASSWORD="$1"
LOCAL_IP="$2"

# Hash MD5
MD5_POSTGRES=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)

# userlist.txt
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5${MD5_POSTGRES}"
EOF

# pgbouncer.ini simple
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
postgres = host=${LOCAL_IP} port=5432 dbname=postgres
* = host=${LOCAL_IP} port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = session
max_client_conn = 1000
default_pool_size = 25
admin_users = postgres
EOF

chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt

# Démarrer PgBouncer
docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  pgbouncer:latest
PGBOUNCER
    
    echo -e "$OK"
done

echo ""
echo "7. Tests finaux..."
echo ""

# Test Patroni
echo -n "  Cluster Patroni: "
if curl -s http://10.0.0.120:8008/cluster 2>/dev/null | grep -q "leader"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test PostgreSQL direct
echo -n "  PostgreSQL direct: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test PgBouncer
echo -n "  PgBouncer: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Cluster PostgreSQL HA complètement reconfiguré"
echo ""
echo "NOUVEAUX CREDENTIALS (sans caractères spéciaux):"
echo "  User: postgres"
echo "  Password: $POSTGRES_PASSWORD"
echo ""
echo "Connexions:"
echo "  Direct: psql -h 10.0.0.120 -p 5432 -U postgres"
echo "  PgBouncer: psql -h 10.0.0.120 -p 6432 -U postgres"
echo ""
echo "Fichier credentials: $CREDS_FILE"
echo ""
echo "Prochaine étape: ./04_install_haproxy.sh"
echo "═══════════════════════════════════════════════════════════════════"
