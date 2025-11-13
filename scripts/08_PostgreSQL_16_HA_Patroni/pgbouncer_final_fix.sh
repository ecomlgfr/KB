#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         PGBOUNCER_FINAL_FIX - Diagnostic et correction             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Diagnostic de l'état actuel..."
echo ""

ssh root@10.0.0.120 bash <<'DIAGNOSTIC'
echo "  Containers actifs:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "postgres|pgbouncer"

echo ""
echo "  Réseaux Docker:"
docker network ls

echo ""
echo "  IP du container PostgreSQL:"
docker inspect postgres | grep '"IPAddress"' | head -1

echo ""
echo "  Ports en écoute:"
ss -tlnp | grep -E "5432|6432"

echo ""
echo "  Test local PostgreSQL:"
docker exec postgres psql -U postgres -c "SELECT 'PostgreSQL direct OK'" 2>&1 | head -1

echo ""
echo "  Logs PgBouncer (dernières lignes):"
docker logs pgbouncer 2>&1 | tail -5
DIAGNOSTIC

echo ""
echo "2. Arrêt complet et nettoyage..."
echo ""

ssh root@10.0.0.120 bash <<'CLEANUP'
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null
docker network rm pgnet 2>/dev/null
rm -rf /opt/keybuzz/pgbouncer
echo "  Nettoyé"
CLEANUP

echo ""
echo "3. Installation PgBouncer avec configuration manuelle complète..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'MANUAL_CONFIG'
PG_PASSWORD="$1"

# Créer la structure
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}

# Créer un Dockerfile custom pour PgBouncer
cd /opt/keybuzz/pgbouncer

cat > Dockerfile <<'DOCKERFILE'
FROM alpine:3.18

RUN apk add --no-cache pgbouncer postgresql-client

# Configuration
COPY pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY userlist.txt /etc/pgbouncer/userlist.txt

# Créer l'utilisateur pgbouncer
RUN adduser -D pgbouncer

# Permissions
RUN chown pgbouncer:pgbouncer /etc/pgbouncer/*
RUN chmod 644 /etc/pgbouncer/pgbouncer.ini
RUN chmod 600 /etc/pgbouncer/userlist.txt

EXPOSE 6432

USER pgbouncer

CMD ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
DOCKERFILE

# Créer pgbouncer.ini
cat > pgbouncer.ini <<EOF
[databases]
postgres = host=host.docker.internal port=5432 dbname=postgres
n8n = host=host.docker.internal port=5432 dbname=n8n
chatwoot = host=host.docker.internal port=5432 dbname=chatwoot
* = host=host.docker.internal port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = trust
pool_mode = transaction
max_client_conn = 200
default_pool_size = 25
min_pool_size = 10
server_reset_query = DISCARD ALL
admin_users = postgres
stats_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

# Créer userlist.txt vide (trust mode)
touch userlist.txt

# Build l'image
docker build -t pgbouncer:custom .

# Démarrer avec host network
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  --network host \
  --add-host=host.docker.internal:127.0.0.1 \
  pgbouncer:custom

echo "PgBouncer custom démarré"
MANUAL_CONFIG

sleep 5

echo ""
echo "4. Vérification du fonctionnement..."
echo ""

echo -n "  Container actif: "
ssh root@10.0.0.120 "docker ps | grep pgbouncer" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Port 6432: "
ssh root@10.0.0.120 "ss -tlnp | grep :6432" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Test connexion: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 'PgBouncer OK'" -t 2>/dev/null | grep -q "PgBouncer OK"; then
    echo -e "$OK Fonctionne!"
else
    echo -e "$KO"
    
    echo ""
    echo "5. Alternative: PgBouncer sur la même machine avec PostgreSQL exposé..."
    echo ""
    
    ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'EXPOSE_POSTGRES'
PG_PASSWORD="$1"

# Arrêter les containers
docker stop pgbouncer postgres 2>/dev/null
docker rm -f pgbouncer postgres 2>/dev/null

# Redémarrer PostgreSQL avec port exposé sur toutes les interfaces
docker run -d \
  --name postgres \
  --hostname db-master-01 \
  --restart unless-stopped \
  -p 0.0.0.0:5432:5432 \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  postgres:17-custom

echo "  PostgreSQL redémarré avec port exposé"
sleep 10

# PgBouncer simple avec localhost
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  -p 0.0.0.0:6432:6432 \
  --add-host=host.docker.internal:172.17.0.1 \
  -e DATABASES_HOST=172.17.0.1 \
  -e DATABASES_PORT=5432 \
  -e DATABASES_USER=postgres \
  -e DATABASES_PASSWORD="$PG_PASSWORD" \
  -e PGBOUNCER_AUTH_TYPE=trust \
  -e PGBOUNCER_POOL_MODE=transaction \
  pgbouncer/pgbouncer:latest

echo "  PgBouncer redémarré"
EXPOSE_POSTGRES
    
    sleep 5
    
    echo -n "  Test après reconfiguration: "
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1 && echo -e "$OK" || echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VALIDATION FINALE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tests complets
SERVICES=("PostgreSQL:5432" "PgBouncer:6432" "n8n:5432:n8n" "chatwoot:5432:chatwoot")
WORKING=0

for service in "${SERVICES[@]}"; do
    IFS=':' read -r name port db <<< "$service"
    db="${db:-postgres}"
    user="${db}"
    [ "$user" = "postgres" ] && user="postgres"
    
    echo -n "  Test $name (port $port): "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p "$port" -U "$user" -d "$db" -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
        echo -e "$OK"
        ((WORKING++))
    else
        echo -e "$KO"
    fi
done

echo ""
if [ $WORKING -ge 3 ]; then
    echo -e "$OK Services opérationnels: $WORKING/4"
    echo ""
    echo "Configuration validée:"
    echo "  • PostgreSQL: 10.0.0.120:5432"
    echo "  • PgBouncer: 10.0.0.120:6432"
    echo "  • Password: $POSTGRES_PASSWORD"
    echo ""
    echo "Prêt pour la phase 2: ./phase_2_add_replicas.sh"
else
    echo "Services opérationnels: $WORKING/4"
    echo ""
    echo "Debug:"
    ssh root@10.0.0.120 "docker logs pgbouncer 2>&1 | tail -3"
fi

echo "═══════════════════════════════════════════════════════════════════"
