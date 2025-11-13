#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX_HAPROXY_FINAL - Correction définitive HAProxy/PgBouncer║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
PROXY_NODE="${1:-haproxy-01}"
PROXY_IP=$(awk -F'\t' -v h="$PROXY_NODE" '$2==h {print $3}' "$SERVERS_TSV")

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

# IPs des DB
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2_IP=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "Correction pour $PROXY_NODE ($PROXY_IP)"
echo ""

echo "1. Voir les vraies erreurs..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash <<'LOGS'
echo "  Logs complets PgBouncer:"
docker logs pgbouncer --tail 20 2>&1 | grep -v "^$"

echo ""
echo "  Logs complets HAProxy:"
docker logs haproxy --tail 20 2>&1 | grep -v "^$"
LOGS

echo ""
echo "2. Arrêt forcé et nettoyage..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash <<'CLEANUP'
# Arrêt forcé
docker kill pgbouncer haproxy 2>/dev/null
docker rm -f pgbouncer haproxy 2>/dev/null

# Libérer le volume
umount /opt/keybuzz/haproxy/data 2>/dev/null || true

# Nettoyer complètement
rm -rf /opt/keybuzz/pgbouncer 2>/dev/null
rm -rf /opt/keybuzz/haproxy 2>/dev/null

# Recréer proprement
mkdir -p /opt/keybuzz/pgbouncer/config
mkdir -p /opt/keybuzz/haproxy/config

echo "  Nettoyage terminé"
CLEANUP

echo ""
echo "3. Installation client PostgreSQL sur le proxy..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash <<'INSTALL_PSQL'
if ! command -v psql &>/dev/null; then
    echo "  Installation postgresql-client..."
    apt-get update -qq
    apt-get install -y postgresql-client -qq
fi
echo "  psql installé"
INSTALL_PSQL

echo ""
echo "4. Configuration PgBouncer ultra-simple..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$DB_MASTER_IP" "$POSTGRES_PASSWORD" <<'PGBOUNCER'
DB_MASTER="$1"
PG_PASSWORD="$2"

# Config minimaliste pour tester
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
postgres = host=$DB_MASTER port=5432 dbname=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 100
default_pool_size = 25
ignore_startup_parameters = extra_float_digits
EOF

# Pas de userlist en mode trust pour tester
touch /opt/keybuzz/pgbouncer/config/userlist.txt

echo "  PgBouncer configuré (mode trust pour test)"
PGBOUNCER

echo ""
echo "5. Configuration HAProxy ultra-simple..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$DB_MASTER_IP" "$DB_SLAVE1_IP" "$DB_SLAVE2_IP" <<'HAPROXY'
DB_MASTER="$1"
DB_SLAVE1="$2"
DB_SLAVE2="$3"

# Config minimaliste sans health checks complexes
cat > /opt/keybuzz/haproxy/config/haproxy.cfg <<EOF
global
    daemon
    maxconn 100

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s

listen postgres_write
    bind 0.0.0.0:5432
    server master $DB_MASTER:5432 check

listen postgres_read
    bind 0.0.0.0:5433
    balance roundrobin
    server slave1 $DB_SLAVE1:5432 check
    server slave2 $DB_SLAVE2:5432 check

listen stats
    bind 0.0.0.0:8080
    mode http
    stats enable
    stats uri /
EOF

echo "  HAProxy configuré (config simple)"
HAPROXY

echo ""
echo "6. Test direct des DB depuis le proxy..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$DB_MASTER_IP" "$POSTGRES_PASSWORD" <<'TEST_DB'
DB_MASTER="$1"
PG_PASSWORD="$2"

echo -n "  Connexion directe à DB Master: "
if PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -c "SELECT 'OK'" 2>/dev/null | grep -q "OK"; then
    echo "✓ OK"
else
    echo "✗ KO"
    PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -c "SELECT 1" 2>&1 | head -2
fi
TEST_DB

echo ""
echo "7. Démarrage PgBouncer simple..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash <<'START_PGBOUNCER'
# Version simple avec port mapping explicite
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  -p 6432:6432 \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  pgbouncer/pgbouncer:latest \
  /etc/pgbouncer/pgbouncer.ini

sleep 3

if docker ps | grep -q pgbouncer; then
    echo "  ✓ PgBouncer démarré"
    docker logs pgbouncer --tail 5
else
    echo "  ✗ PgBouncer échoué"
    docker logs pgbouncer 2>&1
fi

# Test du port
echo -n "  Port 6432: "
if netstat -tln | grep -q ":6432 "; then
    echo "✓ En écoute"
else
    echo "✗ Pas en écoute"
fi
START_PGBOUNCER

echo ""
echo "8. Démarrage HAProxy simple..."
ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash <<'START_HAPROXY'
# Version simple avec port mapping explicite
docker run -d \
  --name haproxy \
  --restart unless-stopped \
  -p 5432:5432 \
  -p 5433:5433 \
  -p 8080:8080 \
  -v /opt/keybuzz/haproxy/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.8-alpine

sleep 3

if docker ps | grep -q haproxy; then
    echo "  ✓ HAProxy démarré"
    docker logs haproxy --tail 5
else
    echo "  ✗ HAProxy échoué"
    docker logs haproxy 2>&1
fi

# Test des ports
for port in 5432 5433 8080; do
    echo -n "  Port $port: "
    if netstat -tln | grep -q ":$port "; then
        echo "✓ En écoute"
    else
        echo "✗ Pas en écoute"
    fi
done
START_HAPROXY

echo ""
echo "9. Test depuis install-01..."

# Test PgBouncer (mode trust, pas de mot de passe)
echo -n "  PgBouncer (6432): "
if timeout 3 psql -h "$PROXY_IP" -p 6432 -U postgres -d postgres -c "SELECT 'OK'" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test HAProxy
echo -n "  HAProxy Write (5432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$PROXY_IP" -p 5432 -U postgres -d postgres -c "SELECT 'OK'" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "  HAProxy Read (5433): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$PROXY_IP" -p 5433 -U postgres -d postgres -c "SELECT 'OK'" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "  HAProxy Stats (8080): "
if curl -s "http://$PROXY_IP:8080/" | grep -q "Statistics"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "10. Restauration auth PgBouncer si tout fonctionne..."
if timeout 3 psql -h "$PROXY_IP" -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
    echo "  Services fonctionnels, ajout authentification..."
    
    ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$DB_MASTER_IP" "$POSTGRES_PASSWORD" <<'FIX_AUTH'
DB_MASTER="$1"
PG_PASSWORD="$2"

# Reconfigurer avec auth MD5
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
postgres = host=$DB_MASTER port=5432 dbname=postgres
* = host=$DB_MASTER port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
pool_mode = transaction
max_client_conn = 100
default_pool_size = 25
ignore_startup_parameters = extra_float_digits
EOF

# Créer userlist avec MD5
MD5_PASS=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5$MD5_PASS"
EOF

# Redémarrer PgBouncer
docker restart pgbouncer
sleep 3
echo "  Auth MD5 configurée"
FIX_AUTH
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Configuration terminée pour $PROXY_NODE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Services disponibles:"
echo "  • PgBouncer: $PROXY_IP:6432"
echo "  • PostgreSQL Write: $PROXY_IP:5432"
echo "  • PostgreSQL Read: $PROXY_IP:5433"
echo "  • Stats: http://$PROXY_IP:8080/"
echo ""
echo "Test via Load Balancer:"
echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 6432 -U postgres -d postgres -c 'SELECT 1'"
echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 5432 -U postgres -d postgres -c 'SELECT 1'"
