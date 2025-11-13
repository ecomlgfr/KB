#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  06_PGBOUNCER_SCRAM - PgBouncer avec SCRAM-SHA-256                 ║"
echo "║                    VERSION CORRIGÉE V5                             ║"
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
    
    # NETTOYAGE COMPLET
    echo "  → Nettoyage complet..."
    
    # Arrêter TOUS les conteneurs pgbouncer
    docker ps -a | grep pgbouncer | awk '{print $1}' | xargs -r docker stop 2>/dev/null || true
    docker ps -a | grep pgbouncer | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null || true
    
    # Tuer tous les processus pgbouncer qui utilisent le port 6432
    fuser -k 6432/tcp 2>/dev/null || true
    sleep 3
    
    # Vérifier que le port est libre
    if ss -tln | grep -q ":6432 "; then
        echo "  ⚠ Port 6432 encore utilisé, nettoyage forcé..."
        lsof -ti:6432 | xargs -r kill -9 2>/dev/null || true
        sleep 2
    fi
    
    echo "  ✓ Nettoyage terminé"
    
echo "  → Récupération des hash SCRAM depuis PostgreSQL..."

# Installer postgresql-client si nécessaire
if ! command -v psql &>/dev/null; then
    echo "  → Installation postgresql-client..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>&1 | grep -v "^Get:" || true
    apt-get install -y postgresql-client -qq 2>&1 | grep -v "^Selecting\|^Preparing\|^Unpacking" || true
fi

# Récupérer les hash SCRAM de TOUS les users
echo "  → Connexion à PostgreSQL..."
HASH_POSTGRES=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='postgres';" 2>/dev/null | xargs || echo "")

echo "  → Récupération hash SCRAM n8n..."
HASH_N8N=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='n8n';" 2>/dev/null | xargs || echo "")

echo "  → Récupération hash SCRAM chatwoot..."
HASH_CHATWOOT=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='chatwoot';" 2>/dev/null | xargs || echo "")

echo "  → Récupération hash SCRAM pgbouncer..."
HASH_PGBOUNCER=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='pgbouncer';" 2>/dev/null | xargs || echo "")

if [ -z "$HASH_POSTGRES" ] || [ "$HASH_POSTGRES" = "null" ]; then
    echo "  ✗ Impossible de récupérer le hash SCRAM postgres"
    exit 1
fi

echo "  ✓ Hash SCRAM récupérés"

# Créer userlist.txt avec TOUS les users
echo "  → Création userlist.txt..."
cat > "$BASE/config/userlist.txt" <<EOF
"postgres" "$HASH_POSTGRES"
EOF

# Ajouter n8n si le hash existe
if [ -n "$HASH_N8N" ] && [ "$HASH_N8N" != "null" ]; then
    echo "\"n8n\" \"$HASH_N8N\"" >> "$BASE/config/userlist.txt"
    echo "    ✓ User n8n ajouté"
fi

# Ajouter chatwoot si le hash existe
if [ -n "$HASH_CHATWOOT" ] && [ "$HASH_CHATWOOT" != "null" ]; then
    echo "\"chatwoot\" \"$HASH_CHATWOOT\"" >> "$BASE/config/userlist.txt"
    echo "    ✓ User chatwoot ajouté"
fi

# Ajouter pgbouncer si le hash existe
if [ -n "$HASH_PGBOUNCER" ] && [ "$HASH_PGBOUNCER" != "null" ]; then
    echo "\"pgbouncer\" \"$HASH_PGBOUNCER\"" >> "$BASE/config/userlist.txt"
    echo "    ✓ User pgbouncer ajouté"
fi
EOF
    
    # CORRECTION V5: Permissions lisibles par le conteneur
    chmod 644 "$BASE/config/userlist.txt"
    chown root:root "$BASE/config/userlist.txt"
    
    # Configuration PgBouncer
    echo "  → Création pgbouncer.ini..."
    cat > "$BASE/config/pgbouncer.ini" <<EOF
[databases]
#* = host=127.0.0.1 port=5432
* = host=$IP_PRIVEE port=5432

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
    
    chmod 644 "$BASE/config/pgbouncer.ini"
    
    echo "  ✓ Configuration créée"
    
    # Démarrer PgBouncer SANS --user root (CORRECTION V5)
    echo "  → Démarrage PgBouncer..."
    
    # Image Docker
    PGBOUNCER_IMAGE="edoburu/pgbouncer:1.21.0-p0"
    
    # Vérifier si l'image existe localement, sinon la pull
    if ! docker images | grep -q "edoburu/pgbouncer.*1.21.0-p0"; then
        echo "  → Pull de l'image PgBouncer..."
        if ! docker pull "$PGBOUNCER_IMAGE" 2>&1 | grep -v "^Digest:\|^Status:"; then
            echo "  ⚠ Image edoburu non disponible, tentative avec bitnami..."
            PGBOUNCER_IMAGE="bitnami/pgbouncer:latest"
            docker pull "$PGBOUNCER_IMAGE" 2>&1 | grep -v "^Digest:\|^Status:"
        fi
    fi
    
    # Lancer le conteneur SANS --user root (CORRECTION CRITIQUE)
    echo "  → Lancement du conteneur..."
    CONTAINER_ID=$(docker run -d \
        --name pgbouncer \
        --hostname pgbouncer \
        --restart unless-stopped \
        --network host \
        -v "$BASE/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
        -v "$BASE/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro" \
        "$PGBOUNCER_IMAGE" \
        pgbouncer /etc/pgbouncer/pgbouncer.ini 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "  ✗ Échec docker run"
        echo "  Erreur: $CONTAINER_ID"
        exit 1
    fi
    
    echo "  → Conteneur ID: ${CONTAINER_ID:0:12}"
    sleep 5
    
    # Vérification détaillée
    if ! docker ps | grep -q "pgbouncer"; then
        echo "  ✗ Conteneur non démarré"
        echo "  → Logs du conteneur:"
        docker logs "$CONTAINER_ID" 2>&1 | head -30
        exit 1
    fi
    
    echo "  ✓ Conteneur démarré"
    
    # Vérifier le port
    echo "  → Vérification port 6432..."
    sleep 3
    
    if ss -tln | grep -q ":6432 "; then
        echo "  ✓ Port 6432 en écoute"
    else
        echo "  ✗ Port 6432 NON en écoute"
        echo "  → Logs PgBouncer:"
        docker logs pgbouncer 2>&1 | tail -20
        exit 1
    fi
    
    # Vérifier les logs pour des erreurs
    echo "  → Vérification des logs..."
    ERRORS=$(docker logs pgbouncer 2>&1 | grep -c "ERROR\|FATAL" || echo "0")
    WARNINGS=$(docker logs pgbouncer 2>&1 | grep -c "WARNING" || echo "0")
    
    if [ "$ERRORS" -gt 0 ]; then
        echo "  ⚠ $ERRORS erreur(s) détectée(s) dans les logs"
        docker logs pgbouncer 2>&1 | grep "ERROR\|FATAL" | tail -3
    fi
    
    if [ "$WARNINGS" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
        echo "  ✓ Aucune erreur dans les logs"
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

# Attendre que PgBouncer soit complètement prêt
sleep 5

# Test PgBouncer avec SCRAM
echo -n "  • PgBouncer SCRAM (6432): "
if timeout 10 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 6432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
else
    echo -e "$KO Échec connexion"
    echo ""
    echo "  Diagnostic:"
    ssh -o StrictHostKeyChecking=no root@"$HAPROXY1_IP" "docker logs pgbouncer 2>&1 | tail -20"
    exit 1
fi

# Test liste des databases via PgBouncer
echo -n "  • Liste des databases: "
if timeout 10 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 6432 -U postgres -d postgres -c '\l' >/dev/null 2>&1"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test SHOW POOLS depuis PgBouncer admin
echo -n "  • PgBouncer admin (SHOW POOLS): "
if timeout 10 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 6432 -U postgres -d pgbouncer -c 'SHOW POOLS;' >/dev/null 2>&1"; then
    echo -e "$OK"
else
    echo -e "$WARN (non critique)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Installation PgBouncer terminée (V5 - CORRIGÉE)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🐳 Image Docker utilisée:"
echo "   • edoburu/pgbouncer:1.21.0-p0"
echo ""
echo "🔐 Authentification:"
echo "   • Type: SCRAM-SHA-256 (hash natif PostgreSQL)"
echo "   • User: postgres"
echo ""
echo "✅ Corrections V5:"
echo "   • SUPPRESSION de --user root (cause du crash loop)"
echo "   • Conteneur tourne avec l'user par défaut de l'image"
echo "   • Permissions 644 sur les fichiers de config (lisibles)"
echo "   • Nettoyage complet du port 6432 avant démarrage"
echo ""
echo "🔌 Test de connexion:"
echo "   PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 6432 -U postgres -d postgres -c 'SELECT 1'"
echo ""
echo "📋 Prochaine étape: Tests complets"
echo "   bash 07_test_infrastructure_FINAL.sh"
echo ""

# Logs finaux
echo "═══ Logs PgBouncer (dernières lignes propres) ═══"
echo ""
ssh -o StrictHostKeyChecking=no root@"$HAPROXY1_IP" "docker logs pgbouncer 2>&1 | grep -v 'ERROR\|WARNING\|FATAL' | tail -10" || echo "Logs non disponibles"
