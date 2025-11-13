#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    09_INSTALL_HAPROXY_AWARE - HAProxy qui suit Patroni leader     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Charger les credentials
source "$CREDS_DIR/postgres.env"

PROXY_NODES=(haproxy-01 haproxy-02)
DB_NODES=(db-master-01 db-slave-01 db-slave-02)

echo ""
echo "═══ Installation HAProxy Patroni-aware sur proxies ═══"
echo ""

# Récupérer les IPs
declare -A PROXY_IPS
for node in "${PROXY_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    PROXY_IPS[$node]=$ip
    echo "  Proxy $node: $ip"
done

declare -A DB_IPS
for node in "${DB_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    DB_IPS[$node]=$ip
    echo "  DB $node: $ip"
done

echo ""
echo "Installation sur les proxies..."
echo ""

for proxy in "${PROXY_NODES[@]}"; do
    PROXY_IP="${PROXY_IPS[$proxy]}"
    echo "  Configuration $proxy ($PROXY_IP):"
    
    ssh root@"$PROXY_IP" bash -s "$PROXY_IP" "${DB_IPS[db-master-01]}" "${DB_IPS[db-slave-01]}" "${DB_IPS[db-slave-02]}" "$PATRONI_API_PASSWORD" <<'INSTALL_HAPROXY'
PROXY_IP="$1"
DB1_IP="$2"
DB2_IP="$3"
DB3_IP="$4"
API_PASSWORD="$5"

# Arrêter l'ancien HAProxy
docker stop haproxy 2>/dev/null
docker rm -f haproxy 2>/dev/null

# Créer la structure
mkdir -p /opt/keybuzz/haproxy/{config,logs}

# Configuration HAProxy Patroni-aware
cat > /opt/keybuzz/haproxy/config/haproxy.cfg <<EOF
global
    log stdout local0
    maxconn 2000
    stats socket /var/run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  300000
    timeout server  300000
    retries 3

# Frontend pour écriture (port 5432) - suit le leader Patroni
frontend fe_pg_write
    bind ${PROXY_IP}:5432
    default_backend be_pg_master

# Backend master - utilise check HTTP Patroni /master
backend be_pg_master
    option httpchk GET /master
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server db1 ${DB1_IP}:5432 check port 8008
    server db2 ${DB2_IP}:5432 check port 8008
    server db3 ${DB3_IP}:5432 check port 8008

# Frontend pour lecture (port 5433) - round-robin sur replicas
frontend fe_pg_read
    bind ${PROXY_IP}:5433
    default_backend be_pg_replicas

# Backend replicas - utilise check HTTP Patroni /replica
backend be_pg_replicas
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server db1 ${DB1_IP}:5432 check port 8008
    server db2 ${DB2_IP}:5432 check port 8008
    server db3 ${DB3_IP}:5432 check port 8008

# Stats
stats enable
stats uri /stats
stats refresh 10s
stats admin if TRUE
stats auth admin:${API_PASSWORD}
stats show-node
stats show-legends
EOF

# Démarrer HAProxy
docker run -d \
  --name haproxy \
  --hostname $(hostname)-haproxy \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/haproxy/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  -v /opt/keybuzz/haproxy/logs:/var/log/haproxy \
  haproxy:2.8

echo "    ✓ HAProxy démarré"
INSTALL_HAPROXY
done

echo ""
echo "Installation PgBouncer sur les proxies..."
echo ""

for proxy in "${PROXY_NODES[@]}"; do
    PROXY_IP="${PROXY_IPS[$proxy]}"
    echo "  Configuration PgBouncer $proxy:"
    
    ssh root@"$PROXY_IP" bash -s "$POSTGRES_PASSWORD" "$PROXY_IP" <<'INSTALL_PGBOUNCER'
PG_PASSWORD="$1"
PROXY_IP="$2"

# Arrêter l'ancien PgBouncer
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null
pkill pgbouncer 2>/dev/null

# Créer la structure
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Configuration PgBouncer - pointe vers HAProxy local pour write
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
# Tout vers HAProxy local qui gère le routage Patroni-aware
* = host=127.0.0.1 port=5432 pool_mode=transaction

[pgbouncer]
listen_addr = ${PROXY_IP}
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 10
reserve_pool_size = 5
reserve_pool_timeout = 3
server_reset_query = DISCARD ALL
server_check_query = select 1
server_check_delay = 30
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

# Créer le Dockerfile pour PgBouncer
cd /opt/keybuzz/pgbouncer

cat > Dockerfile <<'DOCKERFILE'
FROM alpine:3.18

RUN apk add --no-cache pgbouncer

COPY config/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini

RUN adduser -D pgbouncer && \
    chown pgbouncer:pgbouncer /etc/pgbouncer/pgbouncer.ini && \
    chmod 644 /etc/pgbouncer/pgbouncer.ini

EXPOSE 6432

USER pgbouncer

CMD ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
DOCKERFILE

# Build et démarrer
docker build -t pgbouncer:custom .

docker run -d \
  --name pgbouncer \
  --hostname $(hostname)-pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer:custom

echo "    ✓ PgBouncer démarré"
INSTALL_PGBOUNCER
done

echo ""
echo "Test de connectivité..."
echo ""

# Test HAProxy Write (doit atteindre le leader)
echo -n "  HAProxy Write via proxy-01: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "${PROXY_IPS[haproxy-01]}" -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "f" && echo -e "$OK Leader" || echo -e "$KO"

echo -n "  HAProxy Read via proxy-01: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "${PROXY_IPS[haproxy-01]}" -p 5433 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "t" && echo -e "$OK Replica" || echo -e "$KO"

echo -n "  PgBouncer via proxy-01: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "${PROXY_IPS[haproxy-01]}" -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK HAProxy Patroni-aware + PgBouncer installés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Services sur haproxy-01/02:"
echo "  • HAProxy Write: :5432 (suit automatiquement le leader Patroni)"
echo "  • HAProxy Read: :5433 (round-robin sur replicas)"
echo "  • PgBouncer: :6432 (pooling vers HAProxy local)"
echo "  • Stats: http://<IP>:8404/stats (admin:$PATRONI_API_PASSWORD)"
echo ""
echo "Pour les applications:"
echo "  Via PgBouncer (pooling): 10.0.0.11:6432 ou 10.0.0.12:6432"
echo "  Via HAProxy direct: 10.0.0.11:5432 (write) ou :5433 (read)"
echo ""
echo "Prochaine étape: ./10_test_failover_auto.sh"
echo "═══════════════════════════════════════════════════════════════════"
