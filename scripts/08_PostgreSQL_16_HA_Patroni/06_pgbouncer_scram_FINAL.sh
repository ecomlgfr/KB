#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  06_PGBOUNCER_SCRAM - PgBouncer avec SCRAM-SHA-256 Authentification║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
mkdir -p "$LOG_DIR"

# Charger credentials
CRED_FILE="/opt/keybuzz-installer/credentials/postgres.env"
if [ -f "$CRED_FILE" ]; then
    source "$CRED_FILE"
else
    echo -e "$KO Fichier credentials manquant: $CRED_FILE"
    exit 1
fi

# IPs depuis servers.tsv
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══ Installation PgBouncer avec SCRAM-SHA-256 ═══"
echo ""
echo "  db-master-01  : $DB_MASTER_IP"
echo "  haproxy-01    : $HAPROXY1_IP"
echo "  haproxy-02    : $HAPROXY2_IP"
echo ""

for PROXY_NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NODE IP <<< "$PROXY_NODE"
    LOG_FILE="$LOG_DIR/pgbouncer_${NODE}.log"
    
    echo "→ Configuration PgBouncer sur $NODE ($IP)" | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash -s "$DB_MASTER_IP" "$POSTGRES_PASSWORD" "$IP" <<'PGBOUNCER_INSTALL' >> "$LOG_FILE" 2>&1
    set -u
    set -o pipefail
    
    DB_MASTER="$1"
    PG_PASSWORD="$2"
    IP_PRIVEE="$3"
    
    BASE="/opt/keybuzz/pgbouncer"
    mkdir -p "$BASE"/{config,logs,status}
    
    # Arrêter l'ancien conteneur
    docker rm -f pgbouncer 2>/dev/null || true
    
    echo "  → Récupération des hash SCRAM depuis PostgreSQL..."
    
    # Installer postgresql-client si nécessaire
    if ! command -v psql &>/dev/null; then
        apt-get update -qq
        apt-get install -y postgresql-client -qq
    fi
    
    # Récupérer les hash SCRAM directement depuis PostgreSQL
    HASH_POSTGRES=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='postgres';" 2>/dev/null | xargs || echo "")
    
    if [ -z "$HASH_POSTGRES" ] || [ "$HASH_POSTGRES" = "null" ]; then
        echo "  ✗ Impossible de récupérer le hash SCRAM"
        exit 1
    fi
    
    echo "  ✓ Hash SCRAM récupéré"
    
    # Créer userlist.txt avec le vrai hash SCRAM
    echo "  → Création userlist.txt..."
    cat > "$BASE/config/userlist.txt" <<EOF
"postgres" "$HASH_POSTGRES"
EOF
    
    chmod 600 "$BASE/config/userlist.txt"
    
    # Configuration PgBouncer
    echo "  → Création pgbouncer.ini..."
    cat > "$BASE/config/pgbouncer.ini" <<EOF
[databases]
* = host=$DB_MASTER port=5432

[pgbouncer]
listen_addr = $IP_PRIVEE
listen_port = 6432

; Authentification SCRAM-SHA-256
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

; Pooling
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
reserve_pool_size = 5
reserve_pool_timeout = 3

; Admin
admin_users = postgres
stats_users = postgres

; Timeouts
server_idle_timeout = 600
server_lifetime = 3600
server_connect_timeout = 15
query_timeout = 0
query_wait_timeout = 120
client_idle_timeout = 0
idle_transaction_timeout = 0

; Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

; Sécurité
ignore_startup_parameters = extra_float_digits,options

; DNS
dns_max_ttl = 15
dns_zone_check_period = 0
EOF
    
    echo "  ✓ Configuration créée"
    
    # Démarrer PgBouncer
    echo "  → Démarrage PgBouncer..."
    docker run -d \
        --name pgbouncer \
        --hostname pgbouncer \
        --restart unless-stopped \
        --network host \
        -v "$BASE/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
        -v "$BASE/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro" \
        pgbouncer/pgbouncer:1.21.0 \
        /etc/pgbouncer/pgbouncer.ini >/dev/null 2>&1
    
    sleep 3
    
    # Vérification
    if docker ps | grep -q "pgbouncer"; then
        echo "  ✓ Conteneur démarré"
    else
        echo "  ✗ Échec démarrage"
        docker logs pgbouncer 2>&1 | tail -10
        exit 1
    fi
    
    # Vérifier le port
    if ss -tln | grep -q ":6432 "; then
        echo "  ✓ Port 6432 en écoute"
    else
        echo "  ✗ Port 6432 NON en écoute"
        exit 1
    fi
    
    # État final
    echo "OK" > "$BASE/status/STATE"
PGBOUNCER_INSTALL
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Installation réussie"
    else
        echo -e "  $KO Échec installation"
        echo ""
        echo "  Logs disponibles: tail -f $LOG_FILE"
        exit 1
    fi
    
    echo ""
    sleep 2
done

echo ""
echo "═══ Tests de connectivité PgBouncer ═══"
echo ""

# Test via haproxy-01
echo "Tests via haproxy-01 ($HAPROXY1_IP):"

# Test PgBouncer avec SCRAM
echo -n "  • PgBouncer SCRAM (6432): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 6432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
else
    echo -e "$WARN Vérification logs..."
    ssh -o StrictHostKeyChecking=no root@"$HAPROXY1_IP" "docker logs pgbouncer --tail 10" 2>&1 | grep -i "error\|fatal\|scram" || true
fi

# Test liste des databases via PgBouncer
echo -n "  • Liste des databases: "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 6432 -U postgres -d postgres -c '\l' >/dev/null 2>&1"; then
    echo -e "$OK"
else
    echo -e "$WARN"
fi

# Test SHOW POOLS depuis PgBouncer admin
echo ""
echo "  → Stats PgBouncer (SHOW POOLS):"
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 6432 -U postgres -d pgbouncer -c 'SHOW POOLS;' 2>/dev/null"; then
    :
else
    echo "    Pas de stats disponibles pour le moment"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Installation PgBouncer terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🔐 Authentification:"
echo "   • Type: SCRAM-SHA-256 (hash natif PostgreSQL)"
echo "   • User: postgres"
echo "   • Password: (voir /opt/keybuzz-installer/credentials/postgres.env)"
echo ""
echo "🔌 Connexions disponibles:"
echo ""
echo "   Via PgBouncer (recommandé pour les applications):"
echo "   PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 6432 -U postgres -d postgres"
echo ""
echo "   Via HAProxy Write (connexions directes):"
echo "   PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 5432 -U postgres -d postgres"
echo ""
echo "   Via HAProxy Read (replicas en round-robin):"
echo "   PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 5433 -U postgres -d postgres"
echo ""
echo "📊 Administration PgBouncer:"
echo "   PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 6432 -U postgres -d pgbouncer"
echo "   Commandes: SHOW POOLS; SHOW STATS; SHOW DATABASES;"
echo ""
echo "✅ Avantages PgBouncer:"
echo "   • Pooling de connexions (économie de ressources)"
echo "   • Mode transaction (performance)"
echo "   • Reconnexion automatique"
echo "   • Monitoring intégré"
echo ""
echo "📋 Prochaine étape: Tests complets"
echo "   bash 07_test_infrastructure_complete.sh"
echo ""

# Logs finaux
echo "═══ Logs PgBouncer (50 dernières lignes) ═══"
echo ""
tail -n 50 "$LOG_DIR/pgbouncer_haproxy-01.log" 2>/dev/null || echo "Aucun log disponible"
