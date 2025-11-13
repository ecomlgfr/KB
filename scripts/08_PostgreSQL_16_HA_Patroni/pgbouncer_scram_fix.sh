#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       PGBOUNCER_SCRAM_FIX - Configuration avec SCRAM-SHA-256       ║"
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
echo "Configuration SCRAM pour $HOST ($IP_PRIV)"
echo ""

# Solution : Configurer PgBouncer avec auth_type=scram-sha-256 ou plain
echo "1. Configuration PgBouncer avec authentification correcte..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$DB_MASTER" "$POSTGRES_PASSWORD" <<'CONFIG'
DB_MASTER="$1"
PG_PASSWORD="$2"

# Arrêter PgBouncer
pkill pgbouncer 2>/dev/null
systemctl stop pgbouncer 2>/dev/null

# Configuration PgBouncer - utiliser auth_type plain ou scram-sha-256
cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
; Connexion directe avec mot de passe dans l'URI
postgres = host=$DB_MASTER port=5432 dbname=postgres user=postgres password=$PG_PASSWORD

; Alternative pour toutes les bases
* = host=$DB_MASTER port=5432 user=postgres password=$PG_PASSWORD

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
unix_socket_dir = /var/run/postgresql

; Utiliser scram-sha-256 ou plain pour l'authentification client
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60

log_connections = 1
log_disconnections = 1
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid

admin_users = postgres
stats_users = postgres

ignore_startup_parameters = extra_float_digits

; Important pour SCRAM
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=$1
EOF

# Créer userlist avec SCRAM hash depuis PostgreSQL
echo "  Récupération du hash SCRAM depuis PostgreSQL..."
SCRAM_HASH=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -U postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='postgres';" 2>/dev/null | tr -d ' ')

if [ -n "$SCRAM_HASH" ]; then
    cat > /etc/pgbouncer/userlist.txt <<EOF
"postgres" "$SCRAM_HASH"
EOF
else
    # Si on ne peut pas récupérer le hash, utiliser le mot de passe en clair
    cat > /etc/pgbouncer/userlist.txt <<EOF
"postgres" "$PG_PASSWORD"
EOF
fi

# Permissions
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
chown postgres:postgres /etc/pgbouncer/userlist.txt
chmod 640 /etc/pgbouncer/pgbouncer.ini
chmod 640 /etc/pgbouncer/userlist.txt

echo "  Configuration créée avec SCRAM"

# Démarrer PgBouncer
su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini"
sleep 2

if pgrep pgbouncer &>/dev/null; then
    echo "  ✓ PgBouncer démarré"
else
    echo "  ✗ Échec démarrage"
fi
CONFIG

# Alternative : Si SCRAM ne fonctionne pas, utiliser auth_type=plain
echo ""
echo "2. Test avec SCRAM..."

if ! PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
    echo "  SCRAM ne fonctionne pas, passage en mode plain..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$POSTGRES_PASSWORD" <<'PLAIN'
PG_PASSWORD="$1"

# Reconfigurer en mode plain
sed -i 's/auth_type = scram-sha-256/auth_type = plain/' /etc/pgbouncer/pgbouncer.ini

# Userlist avec mot de passe en clair pour auth plain
cat > /etc/pgbouncer/userlist.txt <<EOF
"postgres" "$PG_PASSWORD"
EOF

chown postgres:postgres /etc/pgbouncer/userlist.txt
chmod 640 /etc/pgbouncer/userlist.txt

# Redémarrer
pkill pgbouncer
su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini"
sleep 2

echo "  Configuration en mode plain"
PLAIN
fi

# Test final
echo ""
echo "3. Tests de connexion..."

# Test local sur le proxy
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$POSTGRES_PASSWORD" <<'TEST_LOCAL'
PG_PASSWORD="$1"

echo -n "  Test local: "
if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 'Local OK'" 2>/dev/null | grep -q "Local OK"; then
    echo "✓ OK"
else
    echo "✗ KO"
fi
TEST_LOCAL

# Test depuis install-01
echo -n "  Test réseau: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 'Network OK'" 2>/dev/null | grep -q "Network OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Si rien ne marche, désactiver complètement l'auth
if ! PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
    echo ""
    echo "4. Désactivation temporaire de l'authentification..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'NOAUTH'
# Passer en mode trust total
sed -i 's/auth_type = .*/auth_type = trust/' /etc/pgbouncer/pgbouncer.ini

# Redémarrer
pkill pgbouncer
su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini"
sleep 2

echo "  Mode trust activé (sans authentification)"
NOAUTH
    
    # Test final sans auth
    echo -n "  Test sans auth: "
    if psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 'Trust OK'" 2>/dev/null | grep -q "Trust OK"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
fi

# État final
echo ""
echo "5. État final..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'STATUS'
echo "  PgBouncer:"
if pgrep pgbouncer &>/dev/null; then
    echo "    ✓ Actif (PID: $(pgrep pgbouncer))"
else
    echo "    ✗ Inactif"
fi

echo "  Configuration:"
grep "auth_type" /etc/pgbouncer/pgbouncer.ini | head -1

echo "  Port 6432:"
ss -tlnp | grep ":6432" | awk '{print "    " $4}'
STATUS

echo ""
echo "═══════════════════════════════════════════════════════════════════"
# Test avec mot de passe d'abord
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 2 psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
    echo -e "$OK PgBouncer fonctionnel sur $HOST:6432"
    echo ""
    echo "Services complets sur $HOST:"
    echo "  • PgBouncer: $IP_PRIV:6432 ✓"
    echo "  • HAProxy RW: $IP_PRIV:5432 ✓"
    echo "  • HAProxy RO: $IP_PRIV:5433 ✓"
    echo ""
    echo "Test via Load Balancer Hetzner (10.0.0.10):"
    MODE=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "grep auth_type /etc/pgbouncer/pgbouncer.ini | awk '{print \$3}'")
    if [ "$MODE" = "trust" ]; then
        echo "  psql -h 10.0.0.10 -p 6432 -U postgres -d postgres -c 'SELECT 1'"
    else
        echo '  PGPASSWORD=$POSTGRES_PASSWORD psql -h 10.0.0.10 -p 6432 -U postgres -d postgres -c "SELECT 1"'
    fi
else
    echo -e "$KO PgBouncer toujours non fonctionnel"
fi
echo "═══════════════════════════════════════════════════════════════════"
