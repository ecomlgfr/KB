#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     FIX_PGBOUNCER_PGVECTOR - Correction complète PgBouncer/pgvector║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "PARTIE 1 : CORRECTION DE PGVECTOR"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "1. Installation de pgvector dans PostgreSQL..."
echo ""

# Identifier le leader
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    ROLE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('role', ''))
except:
    pass
" 2>/dev/null)
    
    if [ "$ROLE" = "master" ] || [ "$ROLE" = "leader" ]; then
        LEADER_IP="$ip"
        echo "  Leader identifié: $ip"
        break
    fi
done

if [ -z "$LEADER_IP" ]; then
    echo -e "  $KO Aucun leader trouvé!"
    exit 1
fi

# Installer pgvector sur le leader
echo -n "  Installation pgvector: "
ssh root@"$LEADER_IP" bash <<'INSTALL_PGVECTOR'
# Entrer dans le container et installer
docker exec patroni bash -c "
apt-get update -qq >/dev/null 2>&1
apt-get install -y postgresql-17-pgvector >/dev/null 2>&1
"

# Créer l'extension
docker exec patroni psql -U postgres <<SQL
CREATE EXTENSION IF NOT EXISTS vector;
\dx vector
SQL
INSTALL_PGVECTOR

if ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c '\\dx' | grep -q vector" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "2. Test complet de pgvector..."
echo ""

ssh root@"$LEADER_IP" bash <<'TEST_PGVECTOR'
docker exec patroni psql -U postgres <<SQL
-- Supprimer les tables de test existantes
DROP TABLE IF EXISTS test_embeddings CASCADE;

-- Créer une table avec colonne vector
CREATE TABLE test_embeddings (
    id serial PRIMARY KEY,
    content text,
    embedding vector(384)  -- dimension pour sentence-transformers
);

-- Créer un index pour la recherche rapide
CREATE INDEX ON test_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Insérer des données de test
INSERT INTO test_embeddings (content, embedding) VALUES
    ('PostgreSQL est une base de données', (SELECT array_agg(random())::vector(384) FROM generate_series(1, 384))),
    ('Patroni gère la haute disponibilité', (SELECT array_agg(random())::vector(384) FROM generate_series(1, 384))),
    ('PgBouncer est un pooler de connexions', (SELECT array_agg(random())::vector(384) FROM generate_series(1, 384)));

-- Test de recherche par similarité
SELECT content, embedding <-> (SELECT array_agg(random())::vector(384) FROM generate_series(1, 384)) as distance
FROM test_embeddings
ORDER BY distance
LIMIT 1;

-- Afficher les stats
SELECT 'pgvector installé et fonctionnel' as status;
SQL
TEST_PGVECTOR

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "PARTIE 2 : CORRECTION COMPLÈTE DE PGBOUNCER"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "3. Arrêt de tous les PgBouncer..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Arrêt sur $ip: "
    ssh root@"$ip" "docker stop pgbouncer 2>/dev/null; docker rm pgbouncer 2>/dev/null"
    echo -e "$OK"
done

echo ""
echo "4. Configuration de l'authentification dans PostgreSQL..."
echo ""

ssh root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" <<'SETUP_AUTH'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Créer l'utilisateur pgbouncer avec le même mot de passe
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'pgbouncer') THEN
        CREATE USER pgbouncer WITH PASSWORD '$PG_PASSWORD';
    ELSE
        ALTER USER pgbouncer PASSWORD '$PG_PASSWORD';
    END IF;
END
\$\$;

-- Créer le schéma pgbouncer
CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION pgbouncer;

-- Fonction pour l'authentification
CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(in i_username text, out uname text, out phash text)
RETURNS record AS \$\$
BEGIN
    SELECT usename, passwd INTO uname, phash 
    FROM pg_catalog.pg_shadow 
    WHERE usename = i_username;
    RETURN;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Permissions
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer;
GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer;
GRANT CONNECT ON DATABASE postgres TO pgbouncer;

-- Vérifier
SELECT 'Authentification configurée' as status;
SQL
SETUP_AUTH

echo -e "  $OK Authentification configurée"

echo ""
echo "5. Déploiement de PgBouncer avec configuration corrigée..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  Configuration $hostname:"
    
    ssh root@"$ip" bash -s "$POSTGRES_PASSWORD" "$ip" <<'DEPLOY_PGBOUNCER'
PG_PASSWORD="$1"
LOCAL_IP="$2"

# Créer les répertoires
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Générer le hash MD5
MD5_HASH=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)

# userlist.txt avec tous les utilisateurs
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5${MD5_HASH}"
"pgbouncer" "md5${MD5_HASH}"
EOF

# Configuration PgBouncer optimisée
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
# Base par défaut
postgres = host=${LOCAL_IP} port=5432 dbname=postgres

# Pour l'authentification
pgbouncer = host=${LOCAL_IP} port=5432 dbname=pgbouncer auth_user=pgbouncer

# Template pour autres bases
* = host=${LOCAL_IP} port=5432

[pgbouncer]
# Écoute
listen_addr = 0.0.0.0
listen_port = 6432

# Authentification
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
auth_user = pgbouncer
auth_query = SELECT uname, phash FROM pgbouncer.user_lookup(\$1)

# Pool
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 5

# Connexions serveur
max_db_connections = 100
max_user_connections = 100
server_reset_query = DISCARD ALL
server_check_query = select 1
server_check_delay = 30

# Timeouts
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60

# Logs
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid

# Admin
admin_users = postgres
stats_users = postgres, pgbouncer

# Paramètres à ignorer
ignore_startup_parameters = extra_float_digits, application_name

# Performance
pkt_buf = 4096
listen_backlog = 128
tcp_keepalive = 1
tcp_keepcnt = 3
tcp_keepidle = 300
tcp_keepintvl = 30
EOF

chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt
chmod 644 /opt/keybuzz/pgbouncer/config/pgbouncer.ini

echo "    Config créée"
DEPLOY_PGBOUNCER
    
    # Démarrer PgBouncer
    echo -n "    Démarrage: "
    ssh root@"$ip" bash <<'START_PGBOUNCER'
docker run -d \
  --name pgbouncer \
  --hostname $(hostname)-pgbouncer \
  --network host \
  --restart unless-stopped \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer:latest
START_PGBOUNCER
    
    echo -e "$OK"
done

echo ""
echo "6. Test de connexion via PgBouncer..."
echo ""

sleep 5  # Attendre le démarrage

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo -n "  Test $hostname (port 6432): "
    
    # Test de connexion
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT 'PGBOUNCER_OK'" -t 2>/dev/null | grep -q PGBOUNCER_OK; then
        echo -e "$OK"
    else
        # Afficher l'erreur pour debug
        ERROR=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT 1" 2>&1 | head -1)
        echo -e "$KO"
        echo "      Erreur: $ERROR"
        
        # Afficher les logs PgBouncer
        echo "      Logs PgBouncer:"
        ssh root@"$ip" "docker logs pgbouncer --tail 5 2>&1" | sed 's/^/        /'
    fi
done

echo ""
echo "7. Test des stats PgBouncer..."
echo ""

echo -n "  Accès stats sur $LEADER_IP: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 6432 -U postgres pgbouncer -c "SHOW POOLS" 2>/dev/null | grep -q postgres; then
    echo -e "$OK"
    echo ""
    echo "  Pools actifs:"
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 6432 -U postgres pgbouncer -c "SHOW POOLS" 2>/dev/null | head -5
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ DES CORRECTIONS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tests finaux
PGVECTOR_OK=false
PGBOUNCER_OK=false

# Test pgvector
if ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c 'SELECT * FROM test_embeddings LIMIT 1' 2>/dev/null | grep -q content" 2>/dev/null; then
    PGVECTOR_OK=true
fi

# Test PgBouncer
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
    PGBOUNCER_OK=true
fi

echo "État des services:"
echo "  • pgvector: $([ "$PGVECTOR_OK" = true ] && echo -e "$OK Fonctionnel" || echo -e "$KO Non fonctionnel")"
echo "  • PgBouncer: $([ "$PGBOUNCER_OK" = true ] && echo -e "$OK Fonctionnel" || echo -e "$KO Non fonctionnel")"
echo ""

if [ "$PGVECTOR_OK" = true ] && [ "$PGBOUNCER_OK" = true ]; then
    echo -e "$OK TOUS LES SERVICES SONT MAINTENANT FONCTIONNELS"
    echo ""
    echo "Connexions disponibles:"
    echo "  • Direct: psql -h $LEADER_IP -p 5432 -U postgres"
    echo "  • Via PgBouncer: psql -h $LEADER_IP -p 6432 -U postgres"
    echo "  • Via HAProxy Write: psql -h 10.0.0.11 -p 5432 -U postgres"
    echo "  • Via HAProxy Read: psql -h 10.0.0.11 -p 5433 -U postgres"
    echo ""
    echo "Password: $POSTGRES_PASSWORD"
else
    echo -e "$KO Certains services ont encore des problèmes"
    echo ""
    echo "Vérifiez les logs pour plus de détails"
fi

echo "═══════════════════════════════════════════════════════════════════"
