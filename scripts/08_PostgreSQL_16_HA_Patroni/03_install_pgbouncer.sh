#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      03_INSTALL_PGBOUNCER - Connection Pooling pour PostgreSQL     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Configuration
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/03_pgbouncer_$TIMESTAMP.log"

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    source /opt/keybuzz-installer/credentials/postgres.env
else
    echo -e "$KO Credentials non trouvés"
    exit 1
fi

echo ""
echo "Installation de PgBouncer sur tous les nœuds PostgreSQL"
echo ""

DB_SERVERS=("10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")

echo "1. Création de l'image Docker PgBouncer..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Build sur $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'BUILD' >> "$MAIN_LOG" 2>&1
cd /opt/keybuzz/pgbouncer

cat > Dockerfile <<'DOCKERFILE'
FROM debian:12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pgbouncer \
        postgresql-client \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Créer l'utilisateur pgbouncer
RUN useradd -r -s /bin/false pgbouncer && \
    mkdir -p /var/log/pgbouncer /var/run/pgbouncer && \
    chown pgbouncer:pgbouncer /var/log/pgbouncer /var/run/pgbouncer

USER pgbouncer

EXPOSE 6432

CMD ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
DOCKERFILE

docker build -t pgbouncer:latest . >/dev/null 2>&1
BUILD
    
    echo -e "$OK"
done

echo ""
echo "2. Configuration de PgBouncer..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Config $hostname: "
    
    # Créer le fichier de configuration
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$POSTGRES_PASSWORD" "$ip" <<'CONFIG'
PG_PASSWORD="$1"
LOCAL_IP="$2"

# Créer le fichier userlist (format: "username" "md5password")
# Pour générer: echo -n "passwordusername" | md5sum
MD5_PASS=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)

cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5${MD5_PASS}"
"pgbouncer" "md5${MD5_PASS}"
EOF

# Configuration PgBouncer
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
# Base de données par défaut - pointe vers localhost
postgres = host=${LOCAL_IP} port=5432 dbname=postgres

# Pool pour écriture (master uniquement)
postgres_master = host=10.0.0.120 port=5432 dbname=postgres

# Pool pour lecture (tous les replicas)
postgres_replica = host=10.0.0.121,10.0.0.122 port=5432 dbname=postgres

# Wildcard pour toutes les autres bases
* = host=${LOCAL_IP} port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
auth_user = pgbouncer
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=\$1

# Pool settings
pool_mode = session
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
max_db_connections = 100
max_user_connections = 100

# Timeouts
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_timeout = 0
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60

# Logging
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
admin_users = postgres, pgbouncer
stats_users = postgres, pgbouncer, stats

# Security
server_tls_sslmode = prefer
server_check_query = select 1
server_check_delay = 30

# Performance
pkt_buf = 4096
sbuf_loopcnt = 2
tcp_keepalive = 1
tcp_keepcnt = 3
tcp_keepidle = 300
tcp_keepintvl = 60
EOF

# Permissions
chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt
chmod 644 /opt/keybuzz/pgbouncer/config/pgbouncer.ini
CONFIG
    
    echo -e "$OK"
done

echo ""
echo "3. Démarrage de PgBouncer..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Start $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START' 2>/dev/null
# Arrêter l'ancien si présent
docker stop pgbouncer 2>/dev/null
docker rm pgbouncer 2>/dev/null

# Démarrer PgBouncer
docker run -d \
  --name pgbouncer \
  --hostname $(hostname)-pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer:latest
START
    
    echo -e "$OK"
done

echo ""
echo "4. Test de connexion via PgBouncer..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Test $hostname (port 6432): "
    
    # Test de connexion via PgBouncer
    TEST=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | tr -d ' \n')
    
    if [ "$TEST" = "OK" ]; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK PgBouncer installé sur tous les nœuds"
echo ""
echo "Ports:"
echo "  • 5432 : PostgreSQL direct"
echo "  • 6432 : PgBouncer (connection pooling)"
echo ""
echo "Connexion via PgBouncer:"
echo "  psql -h <IP> -p 6432 -U postgres -d postgres"
echo ""
echo "Prochaine étape: ./04_install_haproxy.sh"
echo "═══════════════════════════════════════════════════════════════════"
