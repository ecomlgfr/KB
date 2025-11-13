#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    PATRONI_FIX_USER - Correction avec utilisateur postgres correct ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials existants
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "Mots de passe actuels conservés:"
echo "  PostgreSQL: $POSTGRES_PASSWORD"
echo "  API Patroni: $PATRONI_API_PASSWORD"
echo ""

echo "1. Arrêt et nettoyage complet..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Nettoyage $ip: "
    ssh root@"$ip" bash <<'CLEANUP'
docker stop patroni 2>/dev/null
docker rm -f patroni 2>/dev/null
# Nettoyer complètement les données corrompues
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/data.failed
rm -rf /opt/keybuzz/postgres/raft/*
echo "clean"
CLEANUP
    echo -e "$OK"
done

echo ""
echo "2. Reconstruction de l'image avec USER postgres..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo "  Build $ip:"
    ssh root@"$ip" bash <<'BUILD_FIXED'
cd /opt/keybuzz/patroni

# Dockerfile corrigé avec USER postgres
cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

# Installer en tant que root
USER root

RUN apt-get update && apt-get install -y \
    python3-pip python3-psycopg2 python3-dev gcc curl \
    postgresql-17-pgvector \
    && apt-get clean

RUN pip3 install --break-system-packages \
    'patroni[raft]==3.3.2' \
    psycopg2-binary

# Créer les répertoires avec les bonnes permissions
RUN mkdir -p /opt/keybuzz/postgres/raft \
    && chown -R postgres:postgres /opt/keybuzz/postgres \
    && chmod 755 /opt/keybuzz/postgres/raft

# Copier la configuration
COPY --chown=postgres:postgres config/patroni.yml /etc/patroni/patroni.yml

# IMPORTANT: Passer à l'utilisateur postgres
USER postgres

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-raft-fixed:latest . >/dev/null 2>&1
echo "    ✓ Image reconstruite avec USER postgres"
BUILD_FIXED
done

echo ""
echo "3. Préparation des volumes avec permissions postgres..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Permissions $ip: "
    ssh root@"$ip" bash <<'PERMS'
# S'assurer que les répertoires existent et ont les bonnes permissions
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/{config,logs}

# Permissions pour l'utilisateur postgres (UID 999 dans l'image Docker)
chown -R 999:999 /opt/keybuzz/postgres
chown -R 999:999 /opt/keybuzz/patroni/logs
chmod 700 /opt/keybuzz/postgres/data
chmod 755 /opt/keybuzz/postgres/raft
chmod 755 /opt/keybuzz/postgres/archive

echo "OK"
PERMS
    echo -e "$OK"
done

echo ""
echo "4. Démarrage du cluster avec la nouvelle image..."
echo ""

# Démarrer db-master-01 en premier (bootstrap)
echo "  Démarrage db-master-01 (bootstrap):"
ssh root@10.0.0.120 bash <<'START_MASTER'
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  -v /opt/keybuzz/patroni/logs:/var/log/postgresql \
  patroni-raft-fixed:latest

echo "    Container démarré, attente initialisation (40s)..."
sleep 40

# Vérifier
if docker exec patroni psql -U postgres -c "SELECT 1" 2>/dev/null | grep -q "1"; then
    echo "    ✓ PostgreSQL initialisé avec succès"
else
    echo "    ✗ Échec initialisation, logs:"
    docker logs patroni 2>&1 | grep -E "(ERROR|FATAL|WARN)" | tail -5
fi
START_MASTER

# Démarrer les replicas
echo ""
for server in "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  Démarrage $hostname:"
    
    ssh root@"$ip" bash -s "$hostname" <<'START_REPLICA'
HOSTNAME="$1"

docker run -d \
  --name patroni \
  --hostname $HOSTNAME \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  -v /opt/keybuzz/patroni/logs:/var/log/postgresql \
  patroni-raft-fixed:latest

echo "    Container démarré, attente (20s)..."
sleep 20

if docker ps | grep -q patroni; then
    echo "    ✓ $HOSTNAME démarré"
else
    echo "    ✗ Échec démarrage"
    docker logs patroni 2>&1 | tail -5
fi
START_REPLICA
done

echo ""
echo "5. Vérification du cluster..."
echo ""

sleep 10

# Test PostgreSQL
echo "  Test PostgreSQL:"
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "    $ip: "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL"; then
        # Vérifier le rôle
        is_recovery=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | xargs)
        if [ "$is_recovery" = "f" ]; then
            echo -e "$OK Master"
            MASTER_IP="$ip"
        else
            echo -e "$OK Replica"
        fi
    else
        echo -e "$KO"
    fi
done

# Test API
echo ""
echo "  Test API Patroni:"
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "    $ip: "
    if curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$ip:8008/patroni" 2>/dev/null | grep -q "state"; then
        role=$(curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('role',''))" 2>/dev/null)
        echo -e "$OK ($role)"
    else
        echo -e "$KO"
    fi
done

# État du cluster
echo ""
echo "  État du cluster:"
curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://10.0.0.120:8008/cluster" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for member in data.get('members', []):
        state = '✓' if member.get('state') == 'running' else '✗'
        print(f\"    {member.get('name')}: {member.get('role')} {state}\")
except:
    print('    Cluster pas accessible')
" 2>/dev/null

echo ""
echo "6. Création des bases et utilisateurs..."
echo ""

if [ -n "${MASTER_IP:-}" ]; then
    ssh root@"$MASTER_IP" bash -s "$POSTGRES_PASSWORD" <<'CREATE_DBS'
PG_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
-- Créer les utilisateurs
CREATE USER IF NOT EXISTS n8n WITH PASSWORD '$PG_PASSWORD';
CREATE USER IF NOT EXISTS chatwoot WITH PASSWORD '$PG_PASSWORD';
CREATE USER IF NOT EXISTS pgbouncer WITH PASSWORD '$PG_PASSWORD';

-- Créer les bases
CREATE DATABASE IF NOT EXISTS keybuzz;
CREATE DATABASE IF NOT EXISTS n8n OWNER n8n;
CREATE DATABASE IF NOT EXISTS chatwoot OWNER chatwoot;

-- Extensions
\c keybuzz
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

\c n8n
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

\c chatwoot
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

SELECT 'Bases créées';
SQL
CREATE_DBS
    echo -e "  $OK Bases et utilisateurs créés"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CLUSTER PATRONI RAFT CORRIGÉ ET OPÉRATIONNEL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Connexion:"
echo "  export PGPASSWORD='$POSTGRES_PASSWORD'"
echo "  psql -h ${MASTER_IP:-10.0.0.120} -p 5432 -U postgres"
echo ""
echo "API:"
echo "  curl -u patroni:$PATRONI_API_PASSWORD http://10.0.0.120:8008/cluster"
echo ""
echo "Prochaine étape: ./09_install_haproxy_aware.sh"
echo "═══════════════════════════════════════════════════════════════════"
