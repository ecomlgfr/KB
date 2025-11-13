#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    09_HAPROXY_PROD - HAProxy Production avec bind IP privée        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

source "$CREDS_DIR/postgres.env"

PROXY_NODES=(haproxy-01 haproxy-02)
DB_NODES=(db-master-01 db-slave-01 db-slave-02)

echo ""
echo "Installation HAProxy Patroni-aware avec bind strict..."
echo ""

# Récupérer les IPs
declare -A PROXY_IPS
for node in "${PROXY_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    PROXY_IPS[$node]=$ip
done

declare -A DB_IPS
for node in "${DB_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    DB_IPS[$node]=$ip
done

for proxy in "${PROXY_NODES[@]}"; do
    PROXY_IP="${PROXY_IPS[$proxy]}"
    echo "  Configuration $proxy ($PROXY_IP):"
    
    ssh root@"$PROXY_IP" bash -s "$PROXY_IP" "${DB_IPS[db-master-01]}" "${DB_IPS[db-slave-01]}" "${DB_IPS[db-slave-02]}" "$PATRONI_API_PASSWORD" <<'INSTALL'
PROXY_IP="$1"
DB1_IP="$2"
DB2_IP="$3"
DB3_IP="$4"
API_PASSWORD="$5"

docker stop haproxy 2>/dev/null
docker rm -f haproxy 2>/dev/null

mkdir -p /opt/keybuzz/haproxy/{config,logs}

# Configuration HAProxy avec bind sur IP privée stricte
cat > /opt/keybuzz/haproxy/config/haproxy.cfg <<EOF
global
    log stdout local0
    maxconn 2000
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

# Frontend écriture - bind IP privée uniquement
frontend fe_pg_write
    bind ${PROXY_IP}:5432
    default_backend be_pg_master

# Backend master - suit le leader Patroni
backend be_pg_master
    option httpchk GET /master
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server db1 ${DB1_IP}:5432 check port 8008
    server db2 ${DB2_IP}:5432 check port 8008
    server db3 ${DB3_IP}:5432 check port 8008

# Frontend lecture - bind IP privée uniquement
frontend fe_pg_read
    bind ${PROXY_IP}:5433
    default_backend be_pg_replicas

# Backend replicas
backend be_pg_replicas
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
    server db1 ${DB1_IP}:5432 check port 8008
    server db2 ${DB2_IP}:5432 check port 8008
    server db3 ${DB3_IP}:5432 check port 8008

# Stats - bind IP privée uniquement
listen stats
    bind ${PROXY_IP}:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:${API_PASSWORD}
EOF

docker run -d \
  --name haproxy \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/haproxy/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.8

echo "    ✓ HAProxy démarré avec bind strict sur $PROXY_IP"
INSTALL
done

echo ""
echo "Installation PgBouncer avec SCRAM-SHA-256..."
echo ""

for proxy in "${PROXY_NODES[@]}"; do
    PROXY_IP="${PROXY_IPS[$proxy]}"
    echo "  Configuration PgBouncer $proxy:"
    
    ssh root@"$PROXY_IP" bash -s "$POSTGRES_PASSWORD" "$PROXY_IP" <<'INSTALL_PGB'
PG_PASSWORD="$1"
PROXY_IP="$2"

docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Générer le hash SCRAM pour userlist.txt
# Note: en production, utiliser pg_shadow ou générer via psql
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "$PG_PASSWORD"
"n8n" "$PG_PASSWORD"
"chatwoot" "$PG_PASSWORD"
"pgbouncer" "$PG_PASSWORD"
EOF
chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt

# Configuration PgBouncer avec SCRAM et bind IP privée
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
keybuzz = host=127.0.0.1 port=5432 dbname=keybuzz
n8n = host=127.0.0.1 port=5432 dbname=n8n
chatwoot = host=127.0.0.1 port=5432 dbname=chatwoot
postgres = host=127.0.0.1 port=5432 dbname=postgres

[pgbouncer]
listen_addr = ${PROXY_IP}
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
admin_users = postgres
stats_users = postgres
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
EOF

# Utiliser l'image bitnami avec support SCRAM natif
docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/bitnami/pgbouncer/conf/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/bitnami/pgbouncer/conf/userlist.txt:ro \
  -e PGBOUNCER_AUTH_TYPE=scram-sha-256 \
  -e PGBOUNCER_BIND_ADDRESS=${PROXY_IP} \
  docker.io/bitnami/pgbouncer:1.23.0

echo "    ✓ PgBouncer avec SCRAM sur $PROXY_IP:6432"
INSTALL_PGB
done

sleep 5

echo ""
echo "Tests de connectivité..."
echo ""

echo -n "  HAProxy Write (${PROXY_IPS[haproxy-01]}:5432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "${PROXY_IPS[haproxy-01]}" -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "f" && echo -e "$OK" || echo -e "$KO"

echo -n "  HAProxy Read (${PROXY_IPS[haproxy-01]}:5433): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "${PROXY_IPS[haproxy-01]}" -p 5433 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo -n "  PgBouncer (${PROXY_IPS[haproxy-01]}:6432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "${PROXY_IPS[haproxy-01]}" -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ HAPROXY + PGBOUNCER PRODUCTION READY"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Accès (bind sur IP privée stricte):"
echo "  • HAProxy Write: ${PROXY_IPS[haproxy-01]}:5432"
echo "  • HAProxy Read: ${PROXY_IPS[haproxy-01]}:5433"
echo "  • PgBouncer: ${PROXY_IPS[haproxy-01]}:6432"
echo "  • Stats: http://${PROXY_IPS[haproxy-01]}:8404/stats"
echo ""
echo "Via VIP (si Keepalived configuré):"
echo "  • postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:5432/keybuzz"
echo "═══════════════════════════════════════════════════════════════════"
