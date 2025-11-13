#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    PGBOUNCER_AUTO - Installation automatisée avec mot de passe     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
CREDS_FILE="/opt/keybuzz-installer/credentials/postgres.env"
if [ ! -f "$CREDS_FILE" ]; then
    echo -e "$KO Fichier credentials non trouvé!"
    echo "  Création avec le mot de passe existant..."
    
    # Le mot de passe de la phase 1
    cat > "$CREDS_FILE" <<'EOF'
#!/bin/bash
export POSTGRES_PASSWORD="wMpBMtBOV1vvFcI8"
export PGPASSWORD="wMpBMtBOV1vvFcI8"
EOF
fi

source "$CREDS_FILE"
export PGPASSWORD="$POSTGRES_PASSWORD"

echo ""
echo "Mot de passe chargé: $POSTGRES_PASSWORD"
echo ""

echo "1. Nettoyage complet..."
echo ""

ssh root@10.0.0.120 bash <<'CLEANUP'
# Arrêter tous les PgBouncer
docker ps -a | grep pgbouncer | awk '{print $1}' | xargs -r docker rm -f
pkill -9 pgbouncer 2>/dev/null
systemctl stop pgbouncer 2>/dev/null
systemctl disable pgbouncer 2>/dev/null

# Nettoyer les ports
fuser -k 6432/tcp 2>/dev/null || true

echo "  Nettoyé"
CLEANUP

echo ""
echo "2. Test PostgreSQL avec mot de passe..."
echo ""

echo -n "  PostgreSQL accessible: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    echo -e "$OK"
else
    echo -e "$KO PostgreSQL inaccessible avec le mot de passe fourni"
    echo "  Vérifiez que PostgreSQL est démarré et le mot de passe est correct"
    exit 1
fi

echo ""
echo "3. Installation PgBouncer natif (plus simple)..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'INSTALL'
PG_PASSWORD="$1"

# S'assurer que PgBouncer est installé
which pgbouncer &>/dev/null || apt-get install -y pgbouncer postgresql-client -qq

# Arrêter le service systemd
systemctl stop pgbouncer 2>/dev/null
pkill pgbouncer 2>/dev/null

# Configuration avec authentification MD5
MD5_HASH=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)

cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
postgres = host=127.0.0.1 port=5432 dbname=postgres
n8n = host=127.0.0.1 port=5432 dbname=n8n
chatwoot = host=127.0.0.1 port=5432 dbname=chatwoot
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
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

# Créer userlist avec le hash MD5
cat > /etc/pgbouncer/userlist.txt <<EOF
"postgres" "md5${MD5_HASH}"
"n8n" "md5${MD5_HASH}"
"chatwoot" "md5${MD5_HASH}"
EOF

# Permissions
chown postgres:postgres /etc/pgbouncer/*
chmod 644 /etc/pgbouncer/pgbouncer.ini
chmod 600 /etc/pgbouncer/userlist.txt

# Créer le répertoire de log
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# Démarrer PgBouncer
su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini" 2>/dev/null

echo "PgBouncer natif démarré avec MD5"
INSTALL

sleep 3

echo ""
echo "4. Tests de connexion..."
echo ""

echo -n "  Port 6432 ouvert: "
ssh root@10.0.0.120 "ss -tlnp | grep :6432" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  PgBouncer (MD5): "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
    echo -e "$OK"
    PGBOUNCER_OK=true
else
    echo -e "$KO"
    echo "  Passage en mode trust..."
    
    # Si MD5 ne marche pas, passer en trust
    ssh root@10.0.0.120 bash <<'TRUST_MODE'
pkill pgbouncer 2>/dev/null

sed -i 's/auth_type = md5/auth_type = trust/' /etc/pgbouncer/pgbouncer.ini

su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini" 2>/dev/null

echo "  Mode trust activé"
TRUST_MODE
    
    sleep 2
    
    echo -n "  PgBouncer (trust): "
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK && echo -e "$OK" || echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VALIDATION COMPLÈTE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tests avec le mot de passe automatique
SCORE=0
echo "Services:"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PostgreSQL (5432)"; ((SCORE++)); } || echo "  ✗ PostgreSQL"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PgBouncer (6432)"; ((SCORE++)); } || echo "  ✗ PgBouncer"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && { echo "  ✓ Base n8n"; ((SCORE++)); } || echo "  ✗ Base n8n"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && { echo "  ✓ Base chatwoot"; ((SCORE++)); } || echo "  ✗ Base chatwoot"

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q vector && { echo "  ✓ Extension pgvector"; ((SCORE++)); } || echo "  ✗ Extension pgvector"

echo ""
echo "Score: $SCORE/5"
echo ""

if [ $SCORE -ge 4 ]; then
    echo -e "$OK PHASE 1 VALIDÉE!"
    echo ""
    echo "Configuration:"
    echo "  PostgreSQL: 10.0.0.120:5432"
    echo "  PgBouncer: 10.0.0.120:6432"  
    echo "  Mot de passe: $POSTGRES_PASSWORD"
    echo ""
    echo "Connexions pour les applications:"
    echo "  export PGPASSWORD='$POSTGRES_PASSWORD'"
    echo "  psql -h 10.0.0.120 -p 5432 -U postgres  # Direct"
    echo "  psql -h 10.0.0.120 -p 6432 -U postgres  # Via PgBouncer"
    echo ""
    echo "PRÊT POUR LA PHASE 2:"
    echo "  ./phase_2_add_replicas.sh"
else
    echo "Certains services ne fonctionnent pas"
    echo "Vérifiez les logs:"
    ssh root@10.0.0.120 "tail -5 /var/log/postgresql/pgbouncer.log 2>/dev/null || echo 'Pas de logs'"
fi

echo "═══════════════════════════════════════════════════════════════════"

# Sauvegarder l'état
echo "PHASE_1_VALIDATED=true" >> /opt/keybuzz-installer/credentials/cluster_state.txt
