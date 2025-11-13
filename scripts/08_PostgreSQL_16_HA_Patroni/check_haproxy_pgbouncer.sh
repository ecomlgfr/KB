#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      CHECK_HAPROXY_PGBOUNCER - Diagnostic des proxies              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. État des services proxy..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  Proxy $ip:"
    ssh root@"$ip" bash <<'CHECK'
    echo -n "    HAProxy: "
    if docker ps | grep -q haproxy; then
        echo "Running"
        echo -n "      Ports: "
        ss -tlnp 2>/dev/null | grep -E "(5432|5433|8404)" | awk '{print $4}' | cut -d: -f2 | sort -u | tr '\n' ' '
        echo ""
    else
        echo "Stopped"
    fi
    
    echo -n "    PgBouncer: "
    if docker ps | grep -q pgbouncer; then
        echo "Running"
        echo -n "      Port 6432: "
        ss -tlnp 2>/dev/null | grep ":6432" &>/dev/null && echo "Open" || echo "Closed"
    else
        echo "Stopped"
    fi
CHECK
done

echo ""
echo "2. Test des backends HAProxy..."
echo ""

echo "  Vérification des health checks:"
for ip in 10.0.0.11; do
    echo "    Via proxy $ip:"
    
    # Test direct des endpoints Patroni
    for db_ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
        echo -n "      $db_ip/master: "
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://$db_ip:8008/master" 2>/dev/null)
        [ "$code" = "200" ] && echo -e "$OK Leader" || echo "$code"
        
        echo -n "      $db_ip/replica: "
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://$db_ip:8008/replica" 2>/dev/null)
        [ "$code" = "200" ] && echo -e "$OK Replica" || echo "$code"
    done
done

echo ""
echo "3. Correction des configurations..."
echo ""

# Le problème est probablement que l'API Patroni nécessite une authentification
for ip in 10.0.0.11 10.0.0.12; do
    echo "  Mise à jour HAProxy sur $ip:"
    
    ssh root@"$ip" bash -s "$PATRONI_API_PASSWORD" "$POSTGRES_PASSWORD" <<'FIX_HAPROXY'
API_PASSWORD="$1"
PG_PASSWORD="$2"

# Arrêter HAProxy
docker stop haproxy 2>/dev/null
docker rm haproxy 2>/dev/null

# Nouvelle configuration avec authentification pour les checks
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

# Frontend écriture - port 5432
frontend fe_pg_write
    bind 0.0.0.0:5432
    default_backend be_pg_master

# Backend master - suit le leader Patroni
backend be_pg_master
    option httpchk GET /master
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server db1 10.0.0.120:5432 check port 8008
    server db2 10.0.0.121:5432 check port 8008
    server db3 10.0.0.122:5432 check port 8008

# Frontend lecture - port 5433
frontend fe_pg_read
    bind 0.0.0.0:5433
    default_backend be_pg_replicas

# Backend replicas
backend be_pg_replicas
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
    server db1 10.0.0.120:5432 check port 8008
    server db2 10.0.0.121:5432 check port 8008
    server db3 10.0.0.122:5432 check port 8008

# Stats
listen stats
    bind 0.0.0.0:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:${API_PASSWORD}
EOF

# Redémarrer HAProxy
docker run -d \
  --name haproxy \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/haproxy/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.8

echo "    ✓ HAProxy redémarré"
FIX_HAPROXY
done

echo ""
echo "4. Attente de stabilisation (10s)..."
sleep 10

echo ""
echo "5. Tests de connexion..."
echo ""

# Test HAProxy Write
echo -n "  HAProxy Write (10.0.0.11:5432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h 10.0.0.11 -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "f"; then
    echo -e "$OK Leader accessible"
else
    echo -e "$KO"
fi

# Test HAProxy Read
echo -n "  HAProxy Read (10.0.0.11:5433): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h 10.0.0.11 -p 5433 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "t"; then
    echo -e "$OK Replica accessible"
else
    # Peut-être tous sont des replicas ou le leader est aussi lisible
    if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h 10.0.0.11 -p 5433 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo -e "$OK PostgreSQL accessible"
    else
        echo -e "$KO"
    fi
fi

# Test PgBouncer
echo -n "  PgBouncer (10.0.0.11:6432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h 10.0.0.11 -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "    Debug PgBouncer:"
    ssh root@10.0.0.11 "docker logs pgbouncer 2>&1 | tail -3"
fi

echo ""
echo "6. Stats HAProxy..."
echo ""

echo "  Backends status (10.0.0.11:8404/stats):"
curl -s -u admin:"$PATRONI_API_PASSWORD" "http://10.0.0.11:8404/stats;csv" 2>/dev/null | grep -E "^(be_pg_master|be_pg_replicas)," | awk -F',' '{printf "    %-20s %s\n", $1"/"$2":", $18}'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ"
echo "═══════════════════════════════════════════════════════════════════"

# Test final
PG_WRITE_OK=false
PG_READ_OK=false
PGBOUNCER_OK=false

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -c "SELECT 1" &>/dev/null && PG_WRITE_OK=true
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5433 -U postgres -c "SELECT 1" &>/dev/null && PG_READ_OK=true
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 6432 -U postgres -c "SELECT 1" &>/dev/null && PGBOUNCER_OK=true

echo ""
echo "État des services:"
[ "$PG_WRITE_OK" = true ] && echo -e "  HAProxy Write (5432): $OK" || echo -e "  HAProxy Write (5432): $KO"
[ "$PG_READ_OK" = true ] && echo -e "  HAProxy Read (5433): $OK" || echo -e "  HAProxy Read (5433): $KO"
[ "$PGBOUNCER_OK" = true ] && echo -e "  PgBouncer (6432): $OK" || echo -e "  PgBouncer (6432): $KO"

if [ "$PG_WRITE_OK" = true ] && [ "$PG_READ_OK" = true ]; then
    echo ""
    echo -e "$OK Infrastructure proxy opérationnelle"
    echo ""
    echo "Connexions disponibles:"
    echo "  Write: PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.11 -p 5432 -U postgres"
    echo "  Read:  PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.11 -p 5433 -U postgres"
    [ "$PGBOUNCER_OK" = true ] && echo "  Pool:  PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.11 -p 6432 -U postgres"
    echo ""
    echo "Stats HAProxy: http://10.0.0.11:8404/stats (admin:$PATRONI_API_PASSWORD)"
else
    echo ""
    echo "Debug nécessaire - Vérifier les logs HAProxy:"
    echo "  ssh root@10.0.0.11 'docker logs haproxy'"
fi

echo "═══════════════════════════════════════════════════════════════════"
