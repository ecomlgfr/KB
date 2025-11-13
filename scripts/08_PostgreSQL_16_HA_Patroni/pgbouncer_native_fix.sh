#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        PGBOUNCER_NATIVE_FIX - Installation native PgBouncer        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "Installation de PgBouncer natif (plus simple et stable)..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'INSTALL_NATIVE'
PG_PASSWORD="$1"

# Arrêter et nettoyer Docker PgBouncer
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Installer PgBouncer natif
apt-get update -qq
apt-get install -y pgbouncer postgresql-client -qq

# Arrêter le service par défaut
systemctl stop pgbouncer
pkill pgbouncer 2>/dev/null

# Configuration simple
cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 200
default_pool_size = 25
server_reset_query = DISCARD ALL
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

# Permissions
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
chmod 644 /etc/pgbouncer/pgbouncer.ini

# Créer le répertoire de log
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# Démarrer PgBouncer
su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini"

echo "PgBouncer natif installé et démarré"
INSTALL_NATIVE

sleep 3

echo ""
echo "Tests de PgBouncer..."
echo ""

echo -n "  Port 6432 en écoute: "
ssh root@10.0.0.120 "ss -tlnp | grep :6432" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Connexion locale: "
ssh root@10.0.0.120 "PGPASSWORD='$POSTGRES_PASSWORD' psql -h localhost -p 6432 -U postgres -c 'SELECT 1' -t" 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo -n "  Connexion réseau: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 'PgBouncer OK'" -t 2>/dev/null | grep -q "PgBouncer OK" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VALIDATION COMPLÈTE PHASE 1"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tests finaux
SCORE=0
echo "Services validés:"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PostgreSQL 17 (port 5432)"; ((SCORE++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PgBouncer (port 6432)"; ((SCORE++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && { echo "  ✓ Base n8n"; ((SCORE++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && { echo "  ✓ Base chatwoot"; ((SCORE++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q "vector" && { echo "  ✓ Extension pgvector"; ((SCORE++)); }

echo ""
if [ $SCORE -eq 5 ]; then
    echo -e "$OK PHASE 1 COMPLÈTEMENT VALIDÉE ($SCORE/5)"
    echo ""
    echo "Connexions disponibles:"
    echo "  • Direct: psql -h 10.0.0.120 -p 5432 -U postgres"
    echo "  • Via PgBouncer: psql -h 10.0.0.120 -p 6432 -U postgres"
    echo "  • Mot de passe: $POSTGRES_PASSWORD"
    echo ""
    echo "PRÊT POUR LA PHASE 2:"
    echo "  ./phase_2_add_replicas.sh"
else
    echo -e "$KO Score: $SCORE/5 - Vérifier les services"
fi
echo "═══════════════════════════════════════════════════════════════════"
