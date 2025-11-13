#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         TEST_INIT_POSTGRES - Test d'initialisation manuel          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

echo ""
echo "1. Arrêt du container Patroni existant..."
ssh root@10.0.0.120 'docker stop patroni 2>/dev/null; docker rm patroni 2>/dev/null'

echo ""
echo "2. Test d'initialisation PostgreSQL directe..."
echo ""

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'TEST_INIT'
echo "Nettoyage..."
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*

echo ""
echo "Création des répertoires avec bonnes permissions..."
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft

echo ""
echo "Test 1: Initialisation PostgreSQL simple (sans Patroni)..."
docker run --rm \
  --user 999:999 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  postgres:17 \
  bash -c "initdb -D /var/lib/postgresql/data -U postgres --encoding=UTF8 --data-checksums 2>&1"

echo ""
echo "Vérification des fichiers créés:"
ls -la /opt/keybuzz/postgres/data | head -10

echo ""
echo "Test 2: Démarrage PostgreSQL simple..."
docker run -d \
  --name postgres-test \
  --user 999:999 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=test123 \
  -p 5432:5432 \
  postgres:17

sleep 5

echo ""
echo "État du container PostgreSQL:"
docker ps | grep postgres-test

echo ""
echo "Test de connexion:"
docker exec postgres-test pg_isready -U postgres

echo ""
echo "Arrêt du test PostgreSQL:"
docker stop postgres-test
docker rm postgres-test

echo ""
echo "Nettoyage pour Patroni:"
rm -rf /opt/keybuzz/postgres/data/*
TEST_INIT

echo ""
echo "3. Test Patroni avec configuration ultra-minimale..."
echo ""

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'PATRONI_MIN'
# Config minimale sans Raft pour test
cat > /tmp/patroni-test.yml <<'EOF'
scope: test
name: test-node

restapi:
  listen: 0.0.0.0:8008
  connect_address: 127.0.0.1:8008

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    postgresql:
      use_pg_rewind: false

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 trust

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 127.0.0.1:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin

watchdog:
  mode: off
EOF

echo "Test Patroni en mode foreground (10 secondes)..."
timeout 10 docker run --rm \
  --name patroni-test \
  --user 999:999 \
  --network host \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /tmp/patroni-test.yml:/etc/patroni.yml:ro \
  patroni-fixed:latest \
  patroni /etc/patroni.yml 2>&1 | head -30

echo ""
echo "Analyse du problème..."
PATRONI_MIN

echo ""
echo "4. Vérification des prérequis Raft..."
echo ""

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'CHECK_RAFT'
echo "Test Python et modules:"
docker run --rm patroni-fixed:latest python3 -c "
import sys
print(f'Python: {sys.version}')
try:
    import patroni
    print('Patroni: OK')
except Exception as e:
    print(f'Patroni: {e}')
    
try:
    from patroni.dcs.raft import Raft
    print('Raft DCS: OK')
except Exception as e:
    print(f'Raft DCS: {e}')
    
try:
    import psycopg2
    print('psycopg2: OK')
except Exception as e:
    print(f'psycopg2: {e}')
"

echo ""
echo "Test de création du répertoire Raft avec les bonnes permissions:"
docker run --rm \
  --user 999:999 \
  -v /opt/keybuzz/postgres/raft:/raft \
  patroni-fixed:latest \
  bash -c "touch /raft/test && echo 'Write OK' && rm /raft/test" 2>&1

echo ""
echo "Version de Patroni installée:"
docker run --rm patroni-fixed:latest patroni --version 2>&1
CHECK_RAFT

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "DIAGNOSTIC"
echo "═══════════════════════════════════════════════════════════════════"

echo ""
echo "Si l'initialisation PostgreSQL simple fonctionne mais pas avec Patroni,"
echo "le problème peut être:"
echo ""
echo "1. Raft DCS nécessite tous les nœuds pour former le quorum"
echo "2. Les permissions sur le répertoire Raft"
echo "3. La configuration Raft partner_addrs"
echo ""
echo "Solution suggérée: Démarrer d'abord SANS Raft (avec un DCS dummy),"
echo "puis migrer vers Raft une fois le cluster initialisé."
echo "═══════════════════════════════════════════════════════════════════"
