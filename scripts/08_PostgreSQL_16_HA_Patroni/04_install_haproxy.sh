#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       04_INSTALL_HAPROXY - Load Balancer pour PostgreSQL           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Configuration
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/04_haproxy_$TIMESTAMP.log"

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    source /opt/keybuzz-installer/credentials/postgres.env
else
    echo -e "$KO Credentials non trouvés"
    exit 1
fi

echo ""
echo "Installation HAProxy sur haproxy-01 et haproxy-02"
echo ""

# Serveurs HAProxy
HAPROXY_SERVERS=("10.0.0.11:haproxy-01" "10.0.0.12:haproxy-02")

echo "1. Préparation des serveurs HAProxy..."
echo ""

for server in "${HAPROXY_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Préparation $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'PREPARE' 2>/dev/null
# Structure
mkdir -p /opt/keybuzz/haproxy/{config,logs,ssl}

# Firewall
ufw allow from 10.0.0.0/16 to any port 5432 proto tcp comment 'PostgreSQL LB' 2>/dev/null
ufw allow from 10.0.0.0/16 to any port 5433 proto tcp comment 'PostgreSQL LB Read' 2>/dev/null
ufw allow from 10.0.0.0/16 to any port 8080 proto tcp comment 'HAProxy Stats' 2>/dev/null
ufw --force enable >/dev/null 2>&1

# Nettoyer ancien
docker stop haproxy 2>/dev/null
docker rm haproxy 2>/dev/null
PREPARE
    
    echo -e "$OK"
done

echo ""
echo "2. Configuration HAProxy..."
echo ""

for server in "${HAPROXY_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Config $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$POSTGRES_PASSWORD" <<'CONFIG'
PG_PASSWORD="$1"

cat > /opt/keybuzz/haproxy/config/haproxy.cfg <<'EOF'
global
    maxconn 10000
    log stdout local0
    
defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    timeout check 5s
    log global
    option tcplog
    option dontlognull
    
# Stats page
stats enable
stats uri /stats
stats refresh 30s
stats show-node
stats auth admin:admin

# PostgreSQL Write (Master only)
listen postgres_write
    bind *:5432
    option tcp-check
    tcp-check connect
    tcp-check send-binary 00000008 # startup packet length
    tcp-check send-binary 00030000 # protocol version
    tcp-check expect binary 52      # 'R' authentication
    default-server inter 3s fall 3 rise 2
    server db-master-01 10.0.0.120:5432 check
    server db-slave-01 10.0.0.121:5432 check backup
    server db-slave-02 10.0.0.122:5432 check backup

# PostgreSQL Read (All nodes)
listen postgres_read
    bind *:5433
    balance roundrobin
    option tcp-check
    tcp-check connect
    tcp-check send-binary 00000008
    tcp-check send-binary 00030000
    tcp-check expect binary 52
    default-server inter 3s fall 3 rise 2
    server db-master-01 10.0.0.120:5432 check weight 100
    server db-slave-01 10.0.0.121:5432 check weight 100
    server db-slave-02 10.0.0.122:5432 check weight 100

# PgBouncer Write (via Master's PgBouncer)
listen pgbouncer_write
    bind *:6432
    option tcp-check
    default-server inter 3s fall 3 rise 2
    server pgb-master-01 10.0.0.120:6432 check
    server pgb-slave-01 10.0.0.121:6432 check backup
    server pgb-slave-02 10.0.0.122:6432 check backup

# PgBouncer Read (All PgBouncers)
listen pgbouncer_read
    bind *:6433
    balance roundrobin
    option tcp-check
    default-server inter 3s fall 3 rise 2
    server pgb-master-01 10.0.0.120:6432 check weight 100
    server pgb-slave-01 10.0.0.121:6432 check weight 100
    server pgb-slave-02 10.0.0.122:6432 check weight 100
EOF

chmod 644 /opt/keybuzz/haproxy/config/haproxy.cfg
CONFIG
    
    echo -e "$OK"
done

echo ""
echo "3. Démarrage HAProxy..."
echo ""

for server in "${HAPROXY_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Start $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START' 2>/dev/null
docker run -d \
  --name haproxy \
  --hostname $(hostname)-haproxy \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/haproxy/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  -v /opt/keybuzz/haproxy/logs:/var/log \
  haproxy:2.9-alpine
START
    
    echo -e "$OK"
done

echo ""
echo "4. Tests de connexion via HAProxy..."
echo ""

for server in "${HAPROXY_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  Tests sur $hostname:"
    
    # Test port 5432 (écriture)
    echo -n "    Port 5432 (write): "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Test port 5433 (lecture)
    echo -n "    Port 5433 (read): "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5433 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Test stats
    echo -n "    Stats page: "
    if curl -s -u admin:admin "http://$ip:8080/stats" | grep -q "Statistics Report"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK HAProxy installé sur haproxy-01 et haproxy-02"
echo ""
echo "Endpoints:"
echo "  • haproxy-01:5432 : Write (master only)"
echo "  • haproxy-01:5433 : Read (all replicas)"
echo "  • haproxy-02:5432 : Write (master only)"
echo "  • haproxy-02:5433 : Read (all replicas)"
echo ""
echo "Stats: http://haproxy-01:8080/stats (admin/admin)"
echo ""
echo "Prochaine étape: ./05_test_cluster.sh"
echo "═══════════════════════════════════════════════════════════════════"
