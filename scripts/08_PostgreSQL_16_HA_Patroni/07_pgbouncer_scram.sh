#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     07_PGBOUNCER_SCRAM - PgBouncer avec authentification SCRAM     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_FILE="/opt/keybuzz-installer/logs/pgbouncer_$(date +%Y%m%d_%H%M%S).log"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
[ ! -f "$CREDS_DIR/postgres.env" ] && { echo -e "$KO postgres.env introuvable"; exit 1; }

source "$CREDS_DIR/postgres.env"

mkdir -p "$(dirname "$LOG_FILE")"

PROXY_NODES=(haproxy-01 haproxy-02)

echo "" | tee -a "$LOG_FILE"
echo "═══ Installation PgBouncer avec SCRAM-SHA-256 ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

for node in "${PROXY_NODES[@]}"; do
    PROXY_IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$PROXY_IP" ] && { echo -e "$KO $node IP introuvable" | tee -a "$LOG_FILE"; continue; }
    
    echo "→ Configuration $node ($PROXY_IP)" | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$PROXY_IP" "$POSTGRES_PASSWORD" <<'PGBOUNCER_INSTALL'
set -u
set -o pipefail

PROXY_IP="$1"
PG_PASSWORD="$2"

# Arrêter si existe
docker stop pgbouncer 2>/dev/null || true
docker rm -f pgbouncer 2>/dev/null || true

# Créer la structure
mkdir -p /opt/keybuzz/pgbouncer/{config,logs,status}

# Fonction pour générer le hash SCRAM-SHA-256
# Note: PgBouncer 1.21+ supporte SCRAM nativement, mais on va utiliser une approche compatible
generate_scram_hash() {
    local username="$1"
    local password="$2"
    
    # Méthode 1: Récupérer directement depuis PostgreSQL via HAProxy
    # C'est la méthode la plus fiable car elle garantit la compatibilité
    docker run --rm postgres:16 psql \
        "host=127.0.0.1 port=5432 user=postgres password=$PG_PASSWORD dbname=postgres" \
        -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='$username'" 2>/dev/null | \
        grep SCRAM | xargs || echo ""
}

# Récupérer les hashes SCRAM depuis PostgreSQL
echo "    Récupération des hashes SCRAM..." >&2

# Attendre que HAProxy soit prêt
sleep 2

POSTGRES_HASH=$(generate_scram_hash "postgres" "$PG_PASSWORD")
N8N_HASH=$(generate_scram_hash "n8n" "$PG_PASSWORD")
CHATWOOT_HASH=$(generate_scram_hash "chatwoot" "$PG_PASSWORD")
PGBOUNCER_HASH=$(generate_scram_hash "pgbouncer" "$PG_PASSWORD")

# Si les hashes ne sont pas récupérés, utiliser l'auth md5 en fallback
if [ -z "$POSTGRES_HASH" ]; then
    echo "    ⚠ Impossible de récupérer les hashes SCRAM" >&2
    echo "    → Utilisation de l'authentification MD5 en fallback" >&2
    
    # Fonction pour générer le hash MD5
    md5_hash() {
        local user=$1
        local pass=$2
        echo -n "md5$(echo -n "${pass}${user}" | md5sum | cut -d' ' -f1)"
    }
    
    # Créer userlist.txt avec MD5
    cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "$(md5_hash postgres "$PG_PASSWORD")"
"n8n" "$(md5_hash n8n "$PG_PASSWORD")"
"chatwoot" "$(md5_hash chatwoot "$PG_PASSWORD")"
"pgbouncer" "$(md5_hash pgbouncer "$PG_PASSWORD")"
EOF
    AUTH_TYPE="md5"
else
    echo "    ✓ Hashes SCRAM récupérés" >&2
    
    # Créer userlist.txt avec SCRAM
    cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "$POSTGRES_HASH"
"n8n" "$N8N_HASH"
"chatwoot" "$CHATWOOT_HASH"
"pgbouncer" "$PGBOUNCER_HASH"
EOF
    AUTH_TYPE="scram-sha-256"
fi

chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt

# Configuration PgBouncer
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=5432 auth_user=pgbouncer

[pgbouncer]
listen_addr = ${PROXY_IP}
listen_port = 6432
auth_type = ${AUTH_TYPE}
auth_file = /etc/pgbouncer/userlist.txt
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=\$1

pool_mode = transaction
max_client_conn = 2000
default_pool_size = 50
min_pool_size = 10
reserve_pool_size = 10
reserve_pool_timeout = 5

server_round_robin = 1
server_check_delay = 30
server_check_query = SELECT 1

server_lifetime = 3600
server_idle_timeout = 600

server_connect_timeout = 15
server_login_retry = 15

query_timeout = 0
query_wait_timeout = 120
client_idle_timeout = 0

max_db_connections = 0
max_user_connections = 0

admin_users = postgres, pgbouncer
stats_users = postgres

log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

ignore_startup_parameters = extra_float_digits,options
EOF

# Créer le Dockerfile
cat > /opt/keybuzz/pgbouncer/Dockerfile <<'DOCKERFILE'
FROM pgbouncer/pgbouncer:1.21.0

USER root

# Installer PostgreSQL client pour auth_query
RUN apt-get update && \
    apt-get install -y postgresql-client && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copier les configs
COPY config/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY config/userlist.txt /etc/pgbouncer/userlist.txt

RUN chmod 644 /etc/pgbouncer/pgbouncer.ini && \
    chmod 600 /etc/pgbouncer/userlist.txt && \
    chown -R pgbouncer:pgbouncer /etc/pgbouncer

USER pgbouncer

EXPOSE 6432

CMD ["/usr/bin/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
DOCKERFILE

# Build l'image
cd /opt/keybuzz/pgbouncer
docker build -t pgbouncer-scram:latest . >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "    ✓ Image construite (auth: $AUTH_TYPE)"
else
    echo "    ✗ Échec build image"
    exit 1
fi

# Démarrer PgBouncer
docker run -d \
  --name pgbouncer \
  --hostname pgbouncer-$(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config:/etc/pgbouncer:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer-scram:latest

sleep 5

# Vérifier
if docker ps | grep -q pgbouncer; then
    echo "    ✓ PgBouncer démarré"
    echo "OK" > /opt/keybuzz/pgbouncer/status/STATE
else
    echo "    ✗ PgBouncer échec démarrage"
    docker logs pgbouncer 2>&1 | tail -20
    echo "KO" > /opt/keybuzz/pgbouncer/status/STATE
    exit 1
fi
PGBOUNCER_INSTALL
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Configuration terminée" | tee -a "$LOG_FILE"
    else
        echo -e "  $KO Échec configuration" | tee -a "$LOG_FILE"
        exit 1
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "═══ Tests de connectivité PgBouncer ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

SUCCESS=0
TOTAL=0

for node in "${PROXY_NODES[@]}"; do
    PROXY_IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "→ Tests sur $node ($PROXY_IP:6432):" | tee -a "$LOG_FILE"
    
    # Test connexion postgres
    echo -n "  User postgres: " | tee -a "$LOG_FILE"
    ((TOTAL++))
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$PROXY_IP" -p 6432 -U postgres -d postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL"; then
        echo -e "$OK" | tee -a "$LOG_FILE"
        ((SUCCESS++))
    else
        echo -e "$KO" | tee -a "$LOG_FILE"
    fi
    
    # Test connexion n8n
    echo -n "  User n8n: " | tee -a "$LOG_FILE"
    ((TOTAL++))
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$PROXY_IP" -p 6432 -U n8n -d n8n -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo -e "$OK" | tee -a "$LOG_FILE"
        ((SUCCESS++))
    else
        echo -e "$KO" | tee -a "$LOG_FILE"
    fi
    
    # Test connexion chatwoot
    echo -n "  User chatwoot: " | tee -a "$LOG_FILE"
    ((TOTAL++))
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$PROXY_IP" -p 6432 -U chatwoot -d chatwoot -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo -e "$OK" | tee -a "$LOG_FILE"
        ((SUCCESS++))
    else
        echo -e "$KO" | tee -a "$LOG_FILE"
    fi
    
    echo "" | tee -a "$LOG_FILE"
done

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"

if [ $SUCCESS -ge $((TOTAL * 2 / 3)) ]; then
    echo -e "$OK PGBOUNCER OPÉRATIONNEL ($SUCCESS/$TOTAL tests OK)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Points d'accès PgBouncer (pooling de connexions):" | tee -a "$LOG_FILE"
    echo "  • postgresql://postgres:****@10.0.0.11:6432/keybuzz" | tee -a "$LOG_FILE"
    echo "  • postgresql://n8n:****@10.0.0.11:6432/n8n" | tee -a "$LOG_FILE"
    echo "  • postgresql://chatwoot:****@10.0.0.11:6432/chatwoot" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Pour les applications, utiliser le port 6432 (avec pooling)" | tee -a "$LOG_FILE"
    echo "Pour l'admin direct, utiliser le port 5432 (sans pooling)" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Prochaine étape: ./08_test_infrastructure.sh" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    tail -n 50 "$LOG_FILE"
    exit 0
else
    echo -e "$KO PGBOUNCER PARTIELLEMENT OPÉRATIONNEL ($SUCCESS/$TOTAL tests OK)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    tail -n 50 "$LOG_FILE"
    exit 1
fi
