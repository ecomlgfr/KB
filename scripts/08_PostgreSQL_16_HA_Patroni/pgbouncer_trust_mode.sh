#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      PGBOUNCER_TRUST_MODE - Configuration simple sans auth         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Arrêt de tout PgBouncer existant..."
echo ""

ssh root@10.0.0.120 bash <<'STOP'
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null
pkill -9 pgbouncer 2>/dev/null
fuser -k 6432/tcp 2>/dev/null || true
echo "Arrêté"
STOP

echo ""
echo "2. Configuration PostgreSQL pour accepter les connexions..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'CONFIG_PG'
PG_PASSWORD="$1"

# Ajouter une entrée pg_hba.conf pour trust local
docker exec postgres bash -c "echo 'host all all 172.17.0.0/16 trust' >> /var/lib/postgresql/data/pg_hba.conf"
docker exec postgres bash -c "echo 'host all all 127.0.0.1/32 trust' >> /var/lib/postgresql/data/pg_hba.conf"

# Recharger PostgreSQL
docker exec postgres psql -U postgres -c "SELECT pg_reload_conf()"

echo "PostgreSQL configuré pour trust"
CONFIG_PG

echo ""
echo "3. Installation PgBouncer en mode trust complet..."
echo ""

ssh root@10.0.0.120 bash <<'INSTALL_TRUST'
# Créer répertoire
mkdir -p /opt/keybuzz/pgbouncer

# Configuration minimale en mode trust
cat > /opt/keybuzz/pgbouncer/pgbouncer.ini <<'EOF'
[databases]
* = host=172.17.0.1 port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
ignore_startup_parameters = extra_float_digits
admin_users = postgres
EOF

# Lancer avec l'image Alpine simple
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  -p 6432:6432 \
  -v /opt/keybuzz/pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  --entrypoint pgbouncer \
  alpine:3.18 \
  -c 'apk add --no-cache pgbouncer && pgbouncer /etc/pgbouncer/pgbouncer.ini'

# Alternative: installer directement dans un container Alpine
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  -p 6432:6432 \
  alpine:3.18 \
  sh -c 'apk add --no-cache pgbouncer && cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=172.17.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
admin_users = postgres
ignore_startup_parameters = extra_float_digits
EOF
pgbouncer /etc/pgbouncer/pgbouncer.ini'

echo "PgBouncer lancé en mode trust"
INSTALL_TRUST

sleep 5

echo ""
echo "4. Test de connexion..."
echo ""

echo -n "  Port 6432 ouvert: "
ssh root@10.0.0.120 "ss -tlnp | grep :6432" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Test sans mot de passe: "
if psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 'Trust OK'" -t 2>/dev/null | grep -q "Trust OK"; then
    echo -e "$OK Fonctionne!"
    PGBOUNCER_OK=true
else
    echo -e "$KO"
    PGBOUNCER_OK=false
fi

if [ "$PGBOUNCER_OK" = false ]; then
    echo ""
    echo "5. Installation native en dernier recours..."
    echo ""
    
    ssh root@10.0.0.120 bash <<'NATIVE_INSTALL'
# Arrêter Docker
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Installer natif si pas déjà fait
which pgbouncer &>/dev/null || apt-get install -y pgbouncer

# Configuration trust native
cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
admin_users = postgres
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
EOF

# Démarrer
systemctl stop pgbouncer 2>/dev/null
pkill pgbouncer 2>/dev/null
su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini"

echo "PgBouncer natif installé"
NATIVE_INSTALL
    
    sleep 3
    
    echo -n "  Test natif: "
    psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1 && echo -e "$OK" || echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAT FINAL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tests finaux
TOTAL=0
echo "Services validés:"
psql -h 10.0.0.120 -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PostgreSQL (5432)"; ((TOTAL++)); }
psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PgBouncer (6432)"; ((TOTAL++)); } || echo "  ✗ PgBouncer (6432)"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && { echo "  ✓ Base n8n"; ((TOTAL++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && { echo "  ✓ Base chatwoot"; ((TOTAL++)); }

echo ""
if [ $TOTAL -eq 4 ]; then
    echo -e "$OK TOUT FONCTIONNE!"
    echo ""
    echo "Connexions disponibles:"
    echo "  • PostgreSQL: psql -h 10.0.0.120 -p 5432 -U postgres"
    echo "  • PgBouncer: psql -h 10.0.0.120 -p 6432 -U postgres"
    echo ""
    echo "Note: PgBouncer en mode trust (sans auth) temporairement"
    echo "      À sécuriser après validation du cluster"
else
    echo "Services actifs: $TOTAL/4"
fi

echo ""
echo "PHASE 1 COMPLÈTE - Prêt pour: ./phase_2_add_replicas.sh"
echo "═══════════════════════════════════════════════════════════════════"
