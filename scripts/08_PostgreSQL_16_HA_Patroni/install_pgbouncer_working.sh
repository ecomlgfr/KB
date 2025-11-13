#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       INSTALL_PGBOUNCER_WORKING - PgBouncer avec image correcte   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
HOST="${1:-haproxy-01}"

# Récupérer l'IP du proxy
IP_PRIV=$(awk -F'\t' -v h="$HOST" '$2==h {print $3}' "$SERVERS_TSV")
[ -z "$IP_PRIV" ] && { echo -e "$KO $HOST IP introuvable"; exit 1; }

# Récupérer l'IP du master DB
DB_MASTER=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")

# Récupérer le mot de passe depuis les credentials
if [ -f "$CREDS_DIR/postgres.env" ]; then
    source "$CREDS_DIR/postgres.env"
elif [ -f "$CREDS_DIR/secrets.json" ]; then
    POSTGRES_PASSWORD=$(jq -r '.postgres_password' "$CREDS_DIR/secrets.json")
else
    echo -e "$KO Aucun fichier de credentials trouvé"
    exit 1
fi

echo ""
echo "Configuration PgBouncer pour $HOST ($IP_PRIV)"
echo "  DB Master: $DB_MASTER"
echo ""

# 1. Nettoyage
echo "1. Nettoyage..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'CLEAN'
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null
pkill pgbouncer 2>/dev/null
rm -rf /opt/keybuzz/pgbouncer 2>/dev/null
echo "  Nettoyage terminé"
CLEAN

# 2. Utiliser l'image edoburu/pgbouncer qui existe
echo ""
echo "2. Installation PgBouncer (edoburu/pgbouncer)..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$DB_MASTER" "$POSTGRES_PASSWORD" <<'INSTALL'
DB_MASTER="$1"
PG_PASSWORD="$2"

# Créer les répertoires
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Configuration PgBouncer basique
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
postgres = host=$DB_MASTER port=5432 dbname=postgres
template1 = host=$DB_MASTER port=5432 dbname=template1
* = host=$DB_MASTER port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
reserve_pool_size = 5
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
log_connections = 0
log_disconnections = 0
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

# Créer userlist avec MD5
MD5_PASS=$(echo -n "${PG_PASSWORD}postgres" | md5sum | awk '{print $1}')
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5$MD5_PASS"
EOF

chmod 644 /opt/keybuzz/pgbouncer/config/*

# Démarrer avec edoburu/pgbouncer (version qui existe)
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  -p 6432:6432 \
  -e DATABASES_HOST="$DB_MASTER" \
  -e DATABASES_PORT=5432 \
  -e DATABASES_USER=postgres \
  -e DATABASES_PASSWORD="$PG_PASSWORD" \
  -e DATABASES_DBNAME=postgres \
  -e POOL_MODE=transaction \
  -e MAX_CLIENT_CONN=1000 \
  -e DEFAULT_POOL_SIZE=25 \
  -e AUTH_TYPE=md5 \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  edoburu/pgbouncer:latest

sleep 5

# Vérifier le démarrage
if docker ps | grep -q pgbouncer; then
    echo "  ✓ PgBouncer démarré"
    
    # Test du port
    echo -n "  Port 6432: "
    if netstat -tln | grep -q ":6432 "; then
        echo "✓ En écoute"
    else
        echo "✗ Pas en écoute"
    fi
else
    echo "  ✗ PgBouncer en erreur, logs:"
    docker logs pgbouncer 2>&1 | tail -10
fi
INSTALL

# 3. Test local
echo ""
echo "3. Test local sur le proxy..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$POSTGRES_PASSWORD" <<'TEST_LOCAL'
PG_PASSWORD="$1"

echo -n "  Connexion locale (6432): "
if PGPASSWORD="$PG_PASSWORD" timeout 3 psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'OK'" 2>/dev/null | grep -q "OK"; then
    echo "✓ OK"
else
    echo "✗ KO"
    # Debug
    PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 1" 2>&1 | head -2
fi
TEST_LOCAL

# 4. Test depuis install-01
echo ""
echo "4. Test depuis install-01..."

echo -n "  PgBouncer ($IP_PRIV:6432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer OK'" 2>/dev/null | grep -q "PgBouncer OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# 5. Si ça ne marche toujours pas, essayer une approche alternative
if ! PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
    echo ""
    echo "5. Installation alternative (pgbouncer natif)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$DB_MASTER" "$POSTGRES_PASSWORD" <<'NATIVE'
DB_MASTER="$1"
PG_PASSWORD="$2"

# Arrêter Docker
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Installer PgBouncer natif
echo "  Installation du package pgbouncer..."
apt-get update -qq
apt-get install -y pgbouncer -qq

# Configurer
cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
postgres = host=$DB_MASTER port=5432 dbname=postgres
* = host=$DB_MASTER port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
server_lifetime = 3600
server_idle_timeout = 600
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
admin_users = postgres
stats_users = postgres
EOF

# Créer userlist
MD5_PASS=$(echo -n "${PG_PASSWORD}postgres" | md5sum | awk '{print $1}')
cat > /etc/pgbouncer/userlist.txt <<EOF
"postgres" "md5$MD5_PASS"
EOF

chmod 640 /etc/pgbouncer/userlist.txt
chown postgres:postgres /etc/pgbouncer/userlist.txt

# Redémarrer le service
systemctl stop pgbouncer
pkill pgbouncer 2>/dev/null
su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini"

echo "  ✓ PgBouncer natif installé"
NATIVE
fi

# 6. État final
echo ""
echo "6. État final..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'STATUS'
# Vérifier Docker
if docker ps | grep -q pgbouncer; then
    echo "  PgBouncer Docker:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep pgbouncer
else
    # Vérifier natif
    if pgrep pgbouncer &>/dev/null; then
        echo "  PgBouncer natif: ✓ Actif (PID: $(pgrep pgbouncer))"
    fi
fi

echo ""
echo "  Port 6432:"
ss -tlnp | grep ":6432" | head -1
STATUS

# Test final
echo ""
echo -n "Test final PgBouncer: "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 'FINAL OK'" 2>/dev/null | grep -q "FINAL OK"; then
    echo -e "$OK Fonctionne!"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
    echo -e "$OK PgBouncer installé et fonctionnel sur $HOST"
else
    echo -e "$KO PgBouncer non fonctionnel sur $HOST"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Services sur $HOST:"
echo "  • PgBouncer: $IP_PRIV:6432"
echo "  • HAProxy RW: $IP_PRIV:5432"
echo "  • HAProxy RO: $IP_PRIV:5433"
echo "  • HAProxy Stats: http://$IP_PRIV:8404/"
echo ""
echo "Pour installer sur l'autre proxy:"
echo "  $0 haproxy-02"
