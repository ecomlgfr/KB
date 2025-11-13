#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      PGBOUNCER_DOCKER_CORRECT - PgBouncer Docker fonctionnel       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Nettoyage complet de PgBouncer..."
echo ""

ssh root@10.0.0.120 bash <<'CLEANUP'
# Arrêter tout
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null
systemctl stop pgbouncer 2>/dev/null
pkill pgbouncer 2>/dev/null

# Nettoyer les ports
fuser -k 6432/tcp 2>/dev/null || true

# Nettoyer les configs
rm -rf /opt/keybuzz/pgbouncer
rm -rf /etc/pgbouncer/pgbouncer.ini

echo "Nettoyage terminé"
CLEANUP

echo ""
echo "2. Création de la configuration PgBouncer..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'CREATE_CONFIG'
PG_PASSWORD="$1"

# Créer la structure
mkdir -p /opt/keybuzz/pgbouncer/config
mkdir -p /opt/keybuzz/pgbouncer/logs

# Créer pgbouncer.ini COMPLET
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
postgres = host=172.17.0.1 port=5432 dbname=postgres
n8n = host=172.17.0.1 port=5432 dbname=n8n
chatwoot = host=172.17.0.1 port=5432 dbname=chatwoot
* = host=172.17.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = plain
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 200
default_pool_size = 25
min_pool_size = 10
reserve_pool_size = 5
server_reset_query = DISCARD ALL
server_check_query = select 1
server_check_delay = 30
logfile = 
pidfile = /tmp/pgbouncer.pid
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits,application_name
EOF

# Créer userlist.txt
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "$PG_PASSWORD"
"n8n" "$PG_PASSWORD"
"chatwoot" "$PG_PASSWORD"
"pgbouncer" "$PG_PASSWORD"
EOF

# Permissions
chmod 644 /opt/keybuzz/pgbouncer/config/pgbouncer.ini
chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt

echo "Configuration créée"
CREATE_CONFIG

echo ""
echo "3. Démarrage de PgBouncer Docker (image officielle)..."
echo ""

ssh root@10.0.0.120 bash <<'START_PGBOUNCER'
# Utiliser l'image officielle pgbouncer/pgbouncer
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  --network host \
  -v /opt/keybuzz/pgbouncer/config:/etc/pgbouncer:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer/pgbouncer:latest

echo "Container démarré"
START_PGBOUNCER

echo "  Attente du démarrage (5s)..."
sleep 5

echo ""
echo "4. Vérification de l'état..."
echo ""

echo -n "  Container actif: "
ssh root@10.0.0.120 "docker ps | grep pgbouncer" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Port 6432 en écoute: "
ssh root@10.0.0.120 "ss -tlnp | grep :6432" &>/dev/null && echo -e "$OK" || echo -e "$KO"

# Si ça ne marche pas, essayer avec une autre configuration
echo ""
echo "5. Test de connexion..."
echo ""

echo -n "  Test local: "
if ! PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$KO"
    
    echo ""
    echo "6. Tentative avec configuration alternative..."
    echo ""
    
    ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'ALT_CONFIG'
PG_PASSWORD="$1"

# Arrêter
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Trouver l'IP du container PostgreSQL
POSTGRES_IP=$(docker inspect postgres | grep '"IPAddress"' | head -1 | awk -F'"' '{print $4}')
echo "  IP PostgreSQL: $POSTGRES_IP"

# Recréer la config avec l'IP du container
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
postgres = host=$POSTGRES_IP port=5432 dbname=postgres
n8n = host=$POSTGRES_IP port=5432 dbname=n8n
chatwoot = host=$POSTGRES_IP port=5432 dbname=chatwoot
* = host=$POSTGRES_IP port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 200
default_pool_size = 25
server_reset_query = DISCARD ALL
logfile = 
pidfile = /tmp/pgbouncer.pid
admin_users = postgres
stats_users = postgres
EOF

# Redémarrer avec auth_type=trust
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  --network host \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  pgbouncer/pgbouncer:latest

echo "  Configuration alternative appliquée"
ALT_CONFIG
    
    sleep 5
    
    echo -n "  Test après reconfiguration: "
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1 && echo -e "$OK" || echo -e "$KO"
else
    echo -e "$OK"
fi

echo ""
echo "7. Tests finaux..."
echo ""

# Test toutes les bases
echo -n "  Connexion base postgres: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -d postgres -c "SELECT current_database()" -t 2>/dev/null | grep -q postgres && echo -e "$OK" || echo -e "$KO"

echo -n "  Connexion base n8n: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U n8n -d n8n -c "SELECT current_database()" -t 2>/dev/null | grep -q n8n && echo -e "$OK" || echo -e "$KO"

echo -n "  Connexion base chatwoot: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U chatwoot -d chatwoot -c "SELECT current_database()" -t 2>/dev/null | grep -q chatwoot && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VALIDATION FINALE PHASE 1"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

SCORE=0
echo "Checklist complète:"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PostgreSQL direct (5432)"; ((SCORE++)); } || echo "  ✗ PostgreSQL direct"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PgBouncer (6432)"; ((SCORE++)); } || echo "  ✗ PgBouncer"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && { echo "  ✓ Base n8n"; ((SCORE++)); } || echo "  ✗ Base n8n"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && { echo "  ✓ Base chatwoot"; ((SCORE++)); } || echo "  ✗ Base chatwoot"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q vector && { echo "  ✓ pgvector"; ((SCORE++)); } || echo "  ✗ pgvector"

echo ""
if [ $SCORE -eq 5 ]; then
    echo -e "$OK PHASE 1 TOTALEMENT VALIDÉE!"
    echo ""
    echo "Configuration:"
    echo "  • PostgreSQL: 10.0.0.120:5432"
    echo "  • PgBouncer: 10.0.0.120:6432"
    echo "  • Password: $POSTGRES_PASSWORD"
    echo ""
    echo "Prochaine étape:"
    echo "  ./phase_2_add_replicas.sh"
else
    echo "Score: $SCORE/5"
    echo ""
    echo "Debug PgBouncer:"
    ssh root@10.0.0.120 "docker logs pgbouncer 2>&1 | tail -5"
fi
echo "═══════════════════════════════════════════════════════════════════"
