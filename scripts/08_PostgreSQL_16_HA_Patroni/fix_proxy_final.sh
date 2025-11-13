#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX_PROXY_FINAL - Correction définitive des proxies        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Correction PgBouncer (sans fichier log)..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  Fix PgBouncer $ip:"
    
    ssh root@"$ip" bash -s "$POSTGRES_PASSWORD" <<'FIX_PGBOUNCER'
PG_PASSWORD="$1"

# Arrêter et nettoyer
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Configuration minimale sans fichier log
cat > /opt/keybuzz/pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
server_connect_timeout = 15
query_wait_timeout = 120
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

# Démarrer PgBouncer en mode foreground (pas de log file)
docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  pgbouncer/pgbouncer:latest \
  sh -c 'pgbouncer -n /etc/pgbouncer/pgbouncer.ini'

# Attendre le démarrage
sleep 3

# Test
if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
    echo "    ✓ PgBouncer opérationnel sur :6432"
else
    # Essayer avec l'image alpine custom
    docker stop pgbouncer 2>/dev/null
    docker rm -f pgbouncer 2>/dev/null
    
    docker run -d \
        --name pgbouncer \
        --network host \
        --restart unless-stopped \
        -e DATABASES_HOST=127.0.0.1 \
        -e DATABASES_PORT=5432 \
        -e DATABASES_USER=postgres \
        -e DATABASES_PASSWORD="$PG_PASSWORD" \
        edoburu/pgbouncer:latest
    
    sleep 3
    
    if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo "    ✓ PgBouncer opérationnel (image alternative)"
    else
        echo "    ✗ PgBouncer échec"
    fi
fi
FIX_PGBOUNCER
done

echo ""
echo "2. Vérification des ports HAProxy..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  Ports sur $ip:"
    ssh root@"$ip" bash <<'CHECK_PORTS'
    # Utiliser netstat au lieu de ss
    echo -n "    HAProxy: "
    netstat -tlnp 2>/dev/null | grep -E "(5432|5433|8404)" | awk '{print $4}' | cut -d: -f2 | sort -u | tr '\n' ' '
    echo ""
    
    echo -n "    PgBouncer: "
    netstat -tlnp 2>/dev/null | grep ":6432" | awk '{print $4}' | cut -d: -f2 | sort -u | tr '\n' ' '
    echo ""
CHECK_PORTS
done

echo ""
echo "3. Test complet de connectivité..."
echo ""

# Test HAProxy Write
echo -n "  HAProxy Write (10.0.0.11:5432): "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "f"; then
    echo -e "$OK Leader"
else
    echo -e "$KO"
fi

echo -n "  HAProxy Write (10.0.0.12:5432): "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.12 -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "f"; then
    echo -e "$OK Leader"
else
    echo -e "$KO"
fi

# Test HAProxy Read
echo -n "  HAProxy Read (10.0.0.11:5433): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5433 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo -n "  HAProxy Read (10.0.0.12:5433): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.12 -p 5433 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

# Test PgBouncer
echo -n "  PgBouncer (10.0.0.11:6432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo -n "  PgBouncer (10.0.0.12:6432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.12 -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "4. Test via VIP si configurée..."
echo ""

if ping -c 1 -W 1 10.0.0.10 &>/dev/null; then
    echo "  VIP 10.0.0.10 active"
    echo -n "    PostgreSQL via VIP: "
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"
else
    echo "  VIP 10.0.0.10 non configurée"
fi

echo ""
echo "5. Stats HAProxy..."
echo ""

echo "  Backend status (10.0.0.11):"
curl -s -u admin:"$PATRONI_API_PASSWORD" "http://10.0.0.11:8404/stats;csv" 2>/dev/null | \
    grep -E "^be_pg_(master|replicas)," | \
    awk -F',' '{printf "    %-25s %s (%s sessions)\n", $1"/"$2":", $18, $34}'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "INFRASTRUCTURE CORRIGÉE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Points d'accès PostgreSQL:"
echo "  • Leader direct: psql -h 10.0.0.121 -p 5432"
echo "  • Via HAProxy Write: psql -h 10.0.0.11 -p 5432"
echo "  • Via HAProxy Read: psql -h 10.0.0.11 -p 5433"
echo "  • Via PgBouncer: psql -h 10.0.0.11 -p 6432"
echo ""
echo "Configuration applications:"
echo "  DATABASE_URL='postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.11:5432/keybuzz'"
echo "  N8N_DB_URL='postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.11:5432/n8n'"
echo "  CHATWOOT_DB_URL='postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.11:5432/chatwoot'"
echo ""
echo "Monitoring:"
echo "  • Stats HAProxy: http://10.0.0.11:8404/stats"
echo "  • User: admin / Pass: $PATRONI_API_PASSWORD"
echo ""
echo "Test rapide:"
echo "  export PGPASSWORD='$POSTGRES_PASSWORD'"
echo "  psql -h 10.0.0.11 -p 5432 -U postgres -c 'SELECT version()'"
echo "═══════════════════════════════════════════════════════════════════"
