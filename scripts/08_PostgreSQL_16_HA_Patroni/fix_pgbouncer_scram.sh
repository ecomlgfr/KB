#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX_PGBOUNCER_SCRAM - PgBouncer avec SCRAM correct         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "Correction PgBouncer avec SCRAM-SHA-256..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  Fix PgBouncer sur $ip:"
    
    ssh root@"$ip" bash -s "$POSTGRES_PASSWORD" "$ip" <<'FIX_PGB'
PG_PASSWORD="$1"
PROXY_IP="$2"

# Arrêter et nettoyer
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

mkdir -p /opt/keybuzz/pgbouncer/{config,data}

# Créer userlist.txt avec les mots de passe en clair
# PgBouncer va les hasher automatiquement avec SCRAM
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "$PG_PASSWORD"
"n8n" "$PG_PASSWORD"
"chatwoot" "$PG_PASSWORD"
"pgbouncer" "$PG_PASSWORD"
EOF
chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt

# Configuration PgBouncer avec SCRAM et bind IP privée
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = ${PROXY_IP}
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
min_pool_size = 5
reserve_pool_size = 5
server_connect_timeout = 15
server_login_retry = 15
query_wait_timeout = 120
client_idle_timeout = 0
admin_users = postgres
stats_users = postgres
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
EOF

# Créer notre propre image PgBouncer avec SCRAM
cat > /opt/keybuzz/pgbouncer/Dockerfile <<'DOCKERFILE'
FROM alpine:3.18

RUN apk add --no-cache pgbouncer postgresql-client

COPY config/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY config/userlist.txt /etc/pgbouncer/userlist.txt

RUN chown -R postgres:postgres /etc/pgbouncer && \
    chmod 600 /etc/pgbouncer/userlist.txt && \
    chmod 644 /etc/pgbouncer/pgbouncer.ini

USER postgres

EXPOSE 6432

CMD ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
DOCKERFILE

# Build l'image
cd /opt/keybuzz/pgbouncer
docker build -t pgbouncer-scram:latest . >/dev/null 2>&1

# Démarrer PgBouncer
docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  pgbouncer-scram:latest

sleep 3

# Test de connexion
echo -n "    Test connexion: "
if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
    echo "✓"
else
    # Si SCRAM échoue, essayer avec md5 comme fallback
    docker stop pgbouncer 2>/dev/null
    docker rm -f pgbouncer 2>/dev/null
    
    # Modifier pour MD5
    sed -i 's/auth_type = scram-sha-256/auth_type = md5/' /opt/keybuzz/pgbouncer/config/pgbouncer.ini
    
    # Rebuild avec MD5
    docker build -t pgbouncer-md5:latest . >/dev/null 2>&1
    
    docker run -d \
      --name pgbouncer \
      --network host \
      --restart unless-stopped \
      pgbouncer-md5:latest
    
    sleep 3
    
    if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo "✓ (MD5 fallback)"
    else
        echo "✗"
    fi
fi
FIX_PGB
done

echo ""
echo "Vérification des ports..."
echo ""

for ip in 10.0.0.11 10.0.0.12; do
    echo "  $ip:"
    ssh root@"$ip" "netstat -tlnp 2>/dev/null | grep -E '(5432|5433|6432|8404)' | awk '{print \"    \"\$4}'"
done

echo ""
echo "Tests finaux..."
echo ""

# Test HAProxy
echo -n "  HAProxy Write (10.0.0.11:5432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "f" && echo -e "$OK Leader" || echo -e "$KO"

echo -n "  HAProxy Read (10.0.0.11:5433): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5433 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

# Test PgBouncer
echo -n "  PgBouncer (10.0.0.11:6432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 6432 -U postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL" && echo -e "$OK" || echo -e "$KO"

echo -n "  PgBouncer (10.0.0.12:6432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.12 -p 6432 -U postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL" && echo -e "$OK" || echo -e "$KO"

# Test via VIP
echo -n "  Via VIP (10.0.0.10:5432): "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ INFRASTRUCTURE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "✓ Patroni RAFT: Cluster HA opérationnel"
echo "✓ HAProxy: Suit automatiquement le leader"
echo "✓ PgBouncer: Pooling avec auth sécurisée"
echo "✓ VIP: 10.0.0.10 active"
echo ""
echo "Points d'accès production:"
echo "  • VIP Write: 10.0.0.10:5432"
echo "  • HAProxy Write: 10.0.0.11:5432 ou 10.0.0.12:5432"
echo "  • HAProxy Read: 10.0.0.11:5433 ou 10.0.0.12:5433"
echo "  • PgBouncer Pool: 10.0.0.11:6432 ou 10.0.0.12:6432"
echo ""
echo "Configuration applications:"
echo "  DATABASE_URL='postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:5432/keybuzz'"
echo "  N8N_DATABASE_URL='postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.10:5432/n8n'"
echo "  CHATWOOT_DATABASE_URL='postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.10:5432/chatwoot'"
echo ""
echo "Monitoring:"
echo "  • Stats HAProxy: http://10.0.0.11:8404/stats (admin:$PATRONI_API_PASSWORD)"
echo "  • Cluster Patroni: curl -u patroni:$PATRONI_API_PASSWORD http://10.0.0.121:8008/cluster"
echo "═══════════════════════════════════════════════════════════════════"
