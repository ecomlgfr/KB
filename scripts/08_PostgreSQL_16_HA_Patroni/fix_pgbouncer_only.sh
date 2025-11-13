#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          FIX_PGBOUNCER_ONLY - Correction PgBouncer seul            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Diagnostic PgBouncer actuel..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  Proxy $ip:"
    ssh root@"$ip" bash <<'DIAG'
    echo -n "    Container status: "
    docker ps -a | grep pgbouncer | awk '{print $7, $8}'
    
    echo "    Dernières erreurs:"
    docker logs pgbouncer 2>&1 | tail -3 | sed 's/^/      /'
    
    echo -n "    Port 6432: "
    netstat -tlnp 2>/dev/null | grep -q ":6432" && echo "OUVERT" || echo "FERMÉ"
DIAG
done

echo ""
echo "2. Nettoyage complet PgBouncer..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo -n "  Nettoyage $ip: "
    ssh root@"$ip" bash <<'CLEAN'
# Arrêter tous les containers pgbouncer
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Nettoyer les répertoires
rm -rf /opt/keybuzz/pgbouncer/*
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

echo "OK"
CLEAN
    echo -e "$OK"
done

echo ""
echo "3. Installation PgBouncer simple..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  Installation sur $ip:"
    
    ssh root@"$ip" bash -s "$POSTGRES_PASSWORD" <<'INSTALL_PGB'
PG_PASSWORD="$1"

# Configuration minimale
cat > /opt/keybuzz/pgbouncer/pgbouncer.ini <<EOF
[databases]
keybuzz = host=127.0.0.1 port=5432 dbname=keybuzz
n8n = host=127.0.0.1 port=5432 dbname=n8n
chatwoot = host=127.0.0.1 port=5432 dbname=chatwoot
postgres = host=127.0.0.1 port=5432 dbname=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
admin_users = postgres
stats_users = postgres
EOF

# Créer un script de démarrage simple
cat > /opt/keybuzz/pgbouncer/start.sh <<'SCRIPT'
#!/bin/sh
exec pgbouncer -n /etc/pgbouncer/pgbouncer.ini 2>&1
SCRIPT
chmod +x /opt/keybuzz/pgbouncer/start.sh

# Utiliser l'image officielle pgbouncer en mode debug
docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  docker.io/bitnami/pgbouncer:latest

sleep 3

# Vérifier
if docker ps | grep -q pgbouncer; then
    echo "    ✓ Container démarré"
    
    # Test connexion
    if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo "    ✓ Connexion OK"
    else
        echo "    ✗ Connexion échouée"
        # Essayer une autre approche
        docker stop pgbouncer 2>/dev/null
        docker rm -f pgbouncer 2>/dev/null
        
        # Créer userlist.txt
        echo "\"postgres\" \"$PG_PASSWORD\"" > /opt/keybuzz/pgbouncer/userlist.txt
        echo "\"n8n\" \"$PG_PASSWORD\"" >> /opt/keybuzz/pgbouncer/userlist.txt
        echo "\"chatwoot\" \"$PG_PASSWORD\"" >> /opt/keybuzz/pgbouncer/userlist.txt
        
        # Modifier config pour md5
        cat > /opt/keybuzz/pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
admin_users = postgres
EOF
        
        # Démarrer avec auth md5
        docker run -d \
          --name pgbouncer \
          --network host \
          --restart unless-stopped \
          -v /opt/keybuzz/pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
          -v /opt/keybuzz/pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
          docker.io/bitnami/pgbouncer:latest
        
        sleep 3
        
        if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
            echo "    ✓ Connexion OK avec auth MD5"
        else
            echo "    ✗ Échec définitif"
        fi
    fi
else
    echo "    ✗ Container non démarré"
fi
INSTALL_PGB
done

echo ""
echo "4. Test final PgBouncer..."
echo ""

PGBOUNCER_OK=0

for ip in 10.0.0.11 10.0.0.12; do
    echo -n "  Test $ip:6432: "
    if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$ip" -p 6432 -U postgres -d postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL"; then
        echo -e "$OK PostgreSQL accessible via PgBouncer"
        ((PGBOUNCER_OK++))
    else
        echo -e "$KO"
        echo "    Debug:"
        ssh root@"$ip" bash <<'DEBUG'
        # Vérifier le port
        echo -n "      Port 6432: "
        netstat -an | grep ":6432" | grep LISTEN && echo "En écoute" || echo "Fermé"
        
        # Logs
        echo "      Dernière erreur:"
        docker logs pgbouncer 2>&1 | grep -E "(ERROR|FATAL)" | tail -1 | sed 's/^/        /'
DEBUG
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if [ $PGBOUNCER_OK -ge 1 ]; then
    echo -e "$OK PgBouncer opérationnel sur $PGBOUNCER_OK/2 proxies"
    echo ""
    echo "Connexion via PgBouncer:"
    echo "  export PGPASSWORD='$POSTGRES_PASSWORD'"
    echo "  psql -h 10.0.0.11 -p 6432 -U postgres -d keybuzz"
else
    echo -e "$KO PgBouncer non fonctionnel"
    echo ""
    echo "HAProxy fonctionne parfaitement, PgBouncer est optionnel."
    echo "Utilisez HAProxy directement:"
    echo "  psql -h 10.0.0.11 -p 5432 -U postgres"
fi
echo "═══════════════════════════════════════════════════════════════════"
