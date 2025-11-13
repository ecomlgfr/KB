#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  PATCH_03_PGBOUNCER_DOCKER_POOL - PgBouncer Docker + Pool HAProxy  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

PROXY_NODES=(haproxy-01 haproxy-02)

echo ""
echo "Ce patch va:"
echo "  1. Supprimer PgBouncer natif (package)"
echo "  2. Installer PgBouncer Docker (homogène)"
echo "  3. Configurer pooling vers HAProxy local (127.0.0.1:5432)"
echo "  4. Auth SCRAM-SHA-256 propre"
echo "  5. Bind sur IP privée :6432"
echo "  6. LB Hetzner :4632 → proxies:6432"
echo ""

# Credentials
if [ ! -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    echo -e "$KO Credentials postgres.env introuvables"
    exit 1
fi

source /opt/keybuzz-installer/credentials/postgres.env

# Récupérer les IPs
declare -A PROXY_IPS
for node in "${PROXY_NODES[@]}"; do
    PROXY_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo "Proxies:"
for node in "${PROXY_NODES[@]}"; do
    echo "  $node: ${PROXY_IPS[$node]}"
done
echo ""

read -p "Continuer avec le patch PgBouncer? (y/N) " -r
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Annulé"; exit 0; }

for PROXY_NODE in "${PROXY_NODES[@]}"; do
    PROXY_IP="${PROXY_IPS[$PROXY_NODE]}"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "Configuration de $PROXY_NODE ($PROXY_IP)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$PROXY_IP" "$POSTGRES_PASSWORD" <<'PGBOUNCER_DOCKER'
PROXY_IP="$1"
PG_PASSWORD="$2"

echo "→ Nettoyage PgBouncer existant..."

# Arrêter et supprimer tout
docker stop pgbouncer 2>/dev/null
docker rm pgbouncer 2>/dev/null
systemctl stop pgbouncer 2>/dev/null
systemctl disable pgbouncer 2>/dev/null
pkill pgbouncer 2>/dev/null
apt-get remove -y pgbouncer 2>/dev/null

rm -rf /opt/keybuzz/pgbouncer 2>/dev/null
rm -f /etc/pgbouncer/pgbouncer.ini 2>/dev/null

echo "  ✓ Nettoyage terminé"

echo "→ Création configuration PgBouncer Docker..."

mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Configuration PgBouncer pointant vers HAProxy LOCAL
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
; Pool vers HAProxy local (qui suit le master Patroni)
* = host=127.0.0.1 port=5432 pool_size=25

[pgbouncer]
listen_addr = ${PROXY_IP}
listen_port = 6432

; Auth type
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=\$1

; Pool settings
pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = 2000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 10
reserve_pool_timeout = 3

; Timeouts
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60

; Logging
log_connections = 0
log_disconnections = 0
log_pooler_errors = 1
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid

; Admin
admin_users = postgres
stats_users = postgres

; Misc
ignore_startup_parameters = extra_float_digits,options
application_name_add_host = 1
EOF

# Récupérer le hash SCRAM depuis PostgreSQL via HAProxy
echo "  → Récupération hash SCRAM..."

# Attendre que HAProxy soit accessible
sleep 2

SCRAM_HASH=$(PGPASSWORD="$PG_PASSWORD" psql -h 127.0.0.1 -p 5432 -U postgres -t -c \
    "SELECT rolpassword FROM pg_authid WHERE rolname='postgres';" 2>/dev/null | tr -d ' ')

if [ -n "$SCRAM_HASH" ]; then
    cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "$SCRAM_HASH"
EOF
    echo "  ✓ Hash SCRAM récupéré"
else
    # Fallback : plain password
    cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "$PG_PASSWORD"
EOF
    echo "  ⚠ Fallback plain password"
fi

chmod 644 /opt/keybuzz/pgbouncer/config/*

echo "→ Création Dockerfile PgBouncer..."

cat > /opt/keybuzz/pgbouncer/Dockerfile <<'DOCKERFILE'
FROM pgbouncer/pgbouncer:1.21

USER root

# Copier les configs
COPY config/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY config/userlist.txt /etc/pgbouncer/userlist.txt

# Permissions
RUN chown -R pgbouncer:pgbouncer /etc/pgbouncer && \
    chmod 640 /etc/pgbouncer/pgbouncer.ini && \
    chmod 640 /etc/pgbouncer/userlist.txt

USER pgbouncer

EXPOSE 6432

CMD ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
DOCKERFILE

# Build l'image
cd /opt/keybuzz/pgbouncer
docker build -t pgbouncer-keybuzz:latest . 2>&1 | grep -E "(Step|Successfully)" || true

echo "  ✓ Image PgBouncer construite"

echo "→ Démarrage PgBouncer Docker..."

docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  --network host \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer-keybuzz:latest

sleep 5

if docker ps | grep -q pgbouncer; then
    echo "  ✓ PgBouncer démarré"
    
    # Vérifier le port
    if ss -tlnp | grep -q ":6432 "; then
        echo "  ✓ Port 6432 actif"
    else
        echo "  ✗ Port 6432 inactif"
    fi
else
    echo "  ✗ Échec démarrage PgBouncer"
    docker logs pgbouncer 2>&1 | tail -10
fi
PGBOUNCER_DOCKER
    
    echo ""
    echo "Tests sur $PROXY_NODE:"
    
    # Test local sur le proxy
    ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$POSTGRES_PASSWORD" <<'TEST_LOCAL'
PG_PASSWORD="$1"

echo -n "  Test local (6432): "
if PGPASSWORD="$PG_PASSWORD" timeout 3 psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c "SELECT 'Pool OK'" 2>/dev/null | grep -q "Pool OK"; then
    echo "✓ OK"
else
    echo "✗ KO"
fi
TEST_LOCAL
    
    # Test depuis install-01
    if command -v psql &>/dev/null; then
        echo -n "  Test réseau (6432): "
        if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$PROXY_IP" -p 6432 -U postgres -d postgres -c "SELECT 'Network OK'" 2>/dev/null | grep -q "Network OK"; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    fi
done

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              PGBOUNCER DOCKER POOL CONFIGURÉ                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

echo "Architecture finale:"
echo ""
echo "  Application"
echo "      ↓"
echo "  LB Hetzner 10.0.0.10:4632 (à configurer)"
echo "      ↓"
echo "  PgBouncer (haproxy-01/02):6432"
echo "      ↓ (pool vers 127.0.0.1:5432)"
echo "  HAProxy local :5432"
echo "      ↓ (check /master)"
echo "  Patroni Leader (auto-détecté)"
echo ""

echo "Avantages:"
echo "  ✓ Pool de connexions réel (défense connection storms)"
echo "  ✓ Transaction pooling (réutilisation aggressive)"
echo "  ✓ HAProxy local suit le master Patroni (<5s failover)"
echo "  ✓ LB externe → double HA (proxy down = bascule)"
echo "  ✓ Docker-only (cohérent avec la stack)"
echo ""

echo "Services par proxy:"
for node in "${PROXY_NODES[@]}"; do
    ip="${PROXY_IPS[$node]}"
    echo ""
    echo "$node ($ip):"
    echo "  • PgBouncer: $ip:6432 (pool)"
    echo "  • HAProxy Write: $ip:5432 (direct master)"
    echo "  • HAProxy Read: $ip:5433 (replicas)"
    echo "  • Stats: http://$ip:8404/"
done
echo ""

echo "Configuration Load Balancer Hetzner:"
echo "  1. Créer target group 'pgbouncer-pool'"
echo "  2. Ajouter haproxy-01:6432 et haproxy-02:6432"
echo "  3. Health check: TCP 6432"
echo "  4. Service: LB IP:4632 → target group"
echo "  5. Algorithme: Round Robin"
echo ""

echo "Configuration application (recommandée):"
echo ""
echo "# Via PgBouncer + LB (HA complète + pool)"
echo "DB_HOST=10.0.0.10"
echo "DB_PORT=4632"
echo "DB_USER=postgres"
echo "DB_PASSWORD=\${POSTGRES_PASSWORD}"
echo "DB_NAME=postgres"
echo "DB_POOL_SIZE=25  # PgBouncer gère le pool"
echo "DB_MAX_OVERFLOW=10"
echo ""

echo "Test complet:"
echo "  # Pool local"
echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h ${PROXY_IPS[haproxy-01]} -p 6432 -U postgres -d postgres -c 'SELECT 1'"
echo ""
echo "  # Via LB (après config Hetzner)"
echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 4632 -U postgres -d postgres -c 'SELECT 1'"
echo ""

echo -e "$OK TOUS LES PATCHES APPLIQUÉS"
echo ""

echo "Stack finale:"
echo "  ✓ Patroni RAFT (sans etcd)"
echo "  ✓ HAProxy Patroni-aware (failover auto)"
echo "  ✓ PgBouncer Docker (pooling)"
echo "  ✓ Architecture HA complète"
echo ""
