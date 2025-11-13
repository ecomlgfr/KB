#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    PGBOUNCER_SCRAM_CORRECT - PgBouncer avec vrais hash SCRAM       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials depuis .env
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Récupération des hash SCRAM depuis PostgreSQL..."
echo ""

# Trouver le leader Patroni
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    if ssh root@"$ip" "docker exec patroni psql -U postgres -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null | grep -q 'f'" 2>/dev/null; then
        LEADER_IP="$ip"
        echo "  Leader trouvé: $ip"
        break
    fi
done

if [ -z "$LEADER_IP" ]; then
    echo -e "$KO Aucun leader trouvé"
    exit 1
fi

# Récupérer les hash SCRAM depuis pg_authid
echo "  Récupération des hash d'authentification..."
USERLIST=$(ssh root@"$LEADER_IP" bash <<'GET_HASH'
docker exec patroni psql -U postgres -t -A -c "
SELECT format('\"%s\" \"%s\"', rolname, rolpassword)
FROM pg_authid
WHERE rolname IN ('postgres','n8n','chatwoot','pgbouncer')
  AND rolpassword IS NOT NULL
ORDER BY rolname;
"
GET_HASH
)

if [ -z "$USERLIST" ]; then
    echo -e "$KO Impossible de récupérer les hash"
    exit 1
fi

echo "  Hash récupérés pour: $(echo "$USERLIST" | wc -l) utilisateurs"

echo ""
echo "2. Configuration PgBouncer avec SCRAM réel..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  Configuration $ip:"
    
    ssh root@"$ip" bash -s "$ip" "$USERLIST" <<'INSTALL_PGB'
PROXY_IP="$1"
USERLIST="$2"

# Arrêter l'ancien
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Écrire les vrais hash SCRAM
echo "$USERLIST" > /opt/keybuzz/pgbouncer/config/userlist.txt
chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt

# Configuration PgBouncer avec SCRAM et bind IP privée
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = ${PROXY_IP}
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 10
reserve_pool_size = 5
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

# Vérifier que HAProxy écoute bien localement
if ! netstat -tlnp 2>/dev/null | grep -q "127.0.0.1:5432"; then
    # Si HAProxy n'écoute pas sur localhost, pointer directement vers le leader
    sed -i "s/host=127.0.0.1/host=${PROXY_IP}/" /opt/keybuzz/pgbouncer/config/pgbouncer.ini
fi

# Utiliser l'image officielle
docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config:/etc/pgbouncer:ro \
  pgbouncer/pgbouncer:latest

echo "    ✓ PgBouncer démarré avec SCRAM"
INSTALL_PGB
done

sleep 5

echo ""
echo "3. Tests de connectivité..."
echo ""

SUCCESS=0
for ip in 10.0.0.11 10.0.0.12; do
    echo -n "  PgBouncer $ip:6432: "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL"; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if [ $SUCCESS -ge 1 ]; then
    echo -e "$OK PGBOUNCER AVEC SCRAM OPÉRATIONNEL"
else
    echo "PgBouncer nécessite peut-être une configuration directe vers les DB"
fi
echo "═══════════════════════════════════════════════════════════════════"
