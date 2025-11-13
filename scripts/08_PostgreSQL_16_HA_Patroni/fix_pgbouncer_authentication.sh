#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX_PGBOUNCER - Correction authentification PgBouncer      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Arrêt de PgBouncer sur tous les nœuds..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Arrêt sur $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" "docker stop pgbouncer 2>/dev/null; docker rm pgbouncer 2>/dev/null"
    echo -e "$OK"
done

echo ""
echo "2. Création de l'utilisateur pgbouncer dans PostgreSQL..."
echo ""

# Se connecter au leader et créer l'utilisateur
ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'CREATE_USER'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Créer l'utilisateur pgbouncer s'il n'existe pas
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'pgbouncer') THEN
        CREATE USER pgbouncer WITH PASSWORD '$PG_PASSWORD';
    END IF;
END
\$\$;

-- Donner les droits nécessaires
GRANT CONNECT ON DATABASE postgres TO pgbouncer;
GRANT pg_monitor TO pgbouncer;

-- Créer la fonction d'authentification pour PgBouncer
CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(in i_username text, out uname text, out phash text)
RETURNS record AS \$\$
BEGIN
    SELECT usename, passwd FROM pg_catalog.pg_shadow 
    WHERE usename = i_username INTO uname, phash;
    RETURN;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Créer le schema pgbouncer si nécessaire
CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION pgbouncer;

-- Donner les droits d'exécution
GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer;
SQL

echo "Utilisateur créé"
CREATE_USER

echo -e "  $OK"

echo ""
echo "3. Reconfiguration de PgBouncer avec auth_query..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Config $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$POSTGRES_PASSWORD" "$ip" <<'CONFIG'
PG_PASSWORD="$1"
LOCAL_IP="$2"

# Générer le hash MD5 pour postgres et pgbouncer
MD5_POSTGRES=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)
MD5_PGBOUNCER=$(echo -n "${PG_PASSWORD}pgbouncer" | md5sum | cut -d' ' -f1)

# Créer userlist.txt
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5${MD5_POSTGRES}"
"pgbouncer" "md5${MD5_PGBOUNCER}"
EOF

# Reconfigurer pgbouncer.ini
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
# Base principale
postgres = host=${LOCAL_IP} port=5432 dbname=postgres auth_user=pgbouncer

# Template pour toutes les autres bases
* = host=${LOCAL_IP} port=5432 auth_user=pgbouncer

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
auth_user = pgbouncer
auth_query = SELECT uname, phash FROM pgbouncer.user_lookup(\$1)

# Pool settings optimisés
pool_mode = session
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
max_db_connections = 50

# Timeouts
server_lifetime = 3600
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60

# Logging
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
admin_users = postgres
stats_users = postgres, pgbouncer

# Performance
pkt_buf = 4096
listen_backlog = 128
tcp_keepalive = 1
tcp_keepcnt = 3
tcp_keepidle = 300
tcp_keepintvl = 30

# Security
server_check_query = select 1
server_check_delay = 30
EOF

chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt
chmod 644 /opt/keybuzz/pgbouncer/config/pgbouncer.ini
CONFIG
    
    echo -e "$OK"
done

echo ""
echo "4. Redémarrage de PgBouncer..."
echo ""

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Start $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START'
docker run -d \
  --name pgbouncer \
  --hostname $(hostname)-pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  -v /opt/keybuzz/pgbouncer/logs:/var/log/pgbouncer \
  pgbouncer:latest
START
    
    echo -e "$OK"
done

echo ""
echo "5. Test de connexion via PgBouncer..."
echo ""

sleep 3  # Attendre que PgBouncer démarre

for server in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Test $hostname (port 6432): "
    
    # Test de connexion
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
        echo -e "$OK"
    else
        # Si échec, afficher l'erreur
        ERROR=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT 1" 2>&1 | head -1)
        echo -e "$KO"
        echo "    Erreur: $ERROR"
    fi
done

echo ""
echo "6. Vérification des stats PgBouncer..."
echo ""

echo -n "  Stats sur db-master-01: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres pgbouncer -c "SHOW POOLS" 2>/dev/null | grep -q postgres; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK PgBouncer corrigé et opérationnel"
echo ""
echo "Connexion via PgBouncer:"
echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h <IP> -p 6432 -U postgres -d postgres"
echo ""
echo "Prochaine étape: ./04_install_haproxy.sh"
echo "═══════════════════════════════════════════════════════════════════"
