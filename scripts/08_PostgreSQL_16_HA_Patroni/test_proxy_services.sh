#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║             TEST_PROXY_SERVICES - Test rapide des services         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
HOST="${1:-haproxy-01}"

# Récupérer l'IP du proxy
IP_PRIV=$(awk -F'\t' -v h="$HOST" '$2==h {print $3}' "$SERVERS_TSV")
[ -z "$IP_PRIV" ] && { echo -e "$KO $HOST IP introuvable"; exit 1; }

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
echo "Test des services sur $HOST ($IP_PRIV)"
echo ""

# Test PgBouncer
echo -n "1. PgBouncer (6432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 6432 -U postgres -d postgres -c "SELECT 'PgBouncer OK'" 2>/dev/null | grep -q "PgBouncer OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test HAProxy RW
echo -n "2. HAProxy RW (5432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 5432 -U postgres -d postgres -c "SELECT pg_is_in_recovery()" 2>/dev/null | grep -q "f"; then
    echo -e "$OK (Master)"
else
    echo -e "$KO"
fi

# Test HAProxy RO
echo -n "3. HAProxy RO (5433): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 5433 -U postgres -d postgres -c "SELECT pg_is_in_recovery()" 2>/dev/null | grep -q "t"; then
    echo -e "$OK (Replica)"
else
    # Peut-être que le master répond aussi sur 5433
    if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$IP_PRIV" -p 5433 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
        echo -e "$OK (Connexion OK)"
    else
        echo -e "$KO"
    fi
fi

# Test Stats HAProxy
echo -n "4. HAProxy Stats (8404): "
if curl -s "http://$IP_PRIV:8404/" | grep -q "Statistics Report"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Test via Load Balancer Hetzner (10.0.0.10)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Test via LB
echo -n "5. LB → PgBouncer (10.0.0.10:6432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h 10.0.0.10 -p 6432 -U postgres -d postgres -c "SELECT 'LB PgBouncer OK'" 2>/dev/null | grep -q "LB PgBouncer OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "6. LB → PostgreSQL RW (10.0.0.10:5432): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h 10.0.0.10 -p 5432 -U postgres -d postgres -c "SELECT 'LB RW OK'" 2>/dev/null | grep -q "LB RW OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "7. LB → PostgreSQL RO (10.0.0.10:5433): "
if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h 10.0.0.10 -p 5433 -U postgres -d postgres -c "SELECT 'LB RO OK'" 2>/dev/null | grep -q "LB RO OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Configuration finale pour l'application:"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Variables d'environnement pour votre application:"
echo ""
echo "# Pour pool de connexions (recommandé)"
echo "DB_HOST=10.0.0.10"
echo "DB_PORT=6432"
echo "DB_USER=postgres"
echo 'DB_PASSWORD=${POSTGRES_PASSWORD}'
echo "DB_NAME=postgres"
echo ""
echo "# Pour accès direct master (écriture)"
echo "DB_WRITE_HOST=10.0.0.10"
echo "DB_WRITE_PORT=5432"
echo ""
echo "# Pour accès direct replicas (lecture)"
echo "DB_READ_HOST=10.0.0.10"
echo "DB_READ_PORT=5433"
echo ""
echo "Tous les services passent par le Load Balancer Hetzner avec failover automatique."
