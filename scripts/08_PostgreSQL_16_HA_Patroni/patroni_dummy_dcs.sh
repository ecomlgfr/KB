#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      PATRONI_DUMMY_DCS - Bootstrap sans Raft puis migration        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-KeyBuzz2024Postgres}"

echo ""
echo "STRATÉGIE: Démarrer avec un DCS 'dummy' pour l'initialisation,"
echo "puis migrer vers Raft une fois le cluster formé."
echo ""

echo "1. Nettoyage complet..."

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEAN' 2>/dev/null
docker stop patroni 2>/dev/null
docker rm -f patroni 2>/dev/null
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/config
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft
CLEAN
    echo -e "$OK"
done

echo ""
echo "2. Installation de Patroni avec support Raft ET dummy..."

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'BUILD_MULTI'
cd /opt/keybuzz/patroni

cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

RUN apt-get update && \
    apt-get install -y python3-pip python3-dev gcc curl && \
    pip3 install --break-system-packages \
        'patroni[raft]>=3.3.0' \
        psycopg2-binary \
        python-dateutil && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Créer structure avec bonnes permissions
RUN mkdir -p /opt/keybuzz/postgres/raft && \
    mkdir -p /var/lib/postgresql/data && \
    mkdir -p /var/run/postgresql && \
    chown -R postgres:postgres /opt/keybuzz/postgres && \
    chown -R postgres:postgres /var/lib/postgresql && \
    chown -R postgres:postgres /var/run/postgresql && \
    chmod 700 /var/lib/postgresql/data && \
    chmod 2775 /var/run/postgresql

USER postgres

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

echo "Build de l'image multi-DCS..."
docker build -t patroni-multi:latest . >/dev/null 2>&1
echo "Image créée"
BUILD_MULTI

echo ""
echo "3. Démarrage avec DCS dummy pour db-master-01..."

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'START_DUMMY'
PG_PASSWORD="$1"

# Config avec dummy DCS (pas de consensus distribué)
cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
name: db-master-01

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.120:8008

# DCS dummy pour l'initialisation
kubernetes:
  bypass_api_service: true
  
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 100
        shared_buffers: 256MB
        wal_level: replica
        hot_standby: 'on'
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB

  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all ::1/128 trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5

  users:
    postgres:
      password: '$PG_PASSWORD'
      options:
        - createrole
        - createdb
    replicator:
      password: '$PG_PASSWORD'  
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.120:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
      password: '$PG_PASSWORD'
  parameters:
    unix_socket_directories: '/var/run/postgresql'

watchdog:
  mode: off
EOF

chown 999:999 /opt/keybuzz/patroni/config/patroni.yml

echo "Démarrage avec DCS dummy..."
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -e PATRONI_KUBERNETES_BYPASS_API_SERVICE=true \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-multi:latest

echo "Attente initialisation (20s)..."
sleep 20

echo ""
echo "Vérification:"
docker ps | grep patroni
echo ""
curl -s http://localhost:8008/patroni | python3 -m json.tool 2>/dev/null || echo "API pas encore prête"
START_DUMMY

echo ""
echo "4. Vérification de l'initialisation..."
sleep 10

STATE=$(curl -s http://10.0.0.120:8008/patroni 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('state','unknown'))" 2>/dev/null || echo "failed")

if [ "$STATE" = "running" ]; then
    echo -e "$OK PostgreSQL initialisé avec succès!"
    echo ""
    echo "5. Test de connexion PostgreSQL..."
    
    ssh root@10.0.0.120 bash <<'TEST_PG'
echo "Version PostgreSQL:"
docker exec patroni psql -U postgres -c "SELECT version();" 2>/dev/null | head -2

echo ""
echo "Création base de test:"
docker exec patroni psql -U postgres -c "CREATE DATABASE test_db;" 2>/dev/null
docker exec patroni psql -U postgres -c "\l" 2>/dev/null | grep test_db
TEST_PG
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$OK SUCCÈS: PostgreSQL fonctionne avec DCS dummy!"
    echo ""
    echo "Prochaines étapes pour activer Raft:"
    echo ""
    echo "1. Arrêter Patroni: docker stop patroni"
    echo "2. Modifier patroni.yml pour remplacer 'kubernetes:' par:"
    echo "   raft:"
    echo "     data_dir: /opt/keybuzz/postgres/raft"
    echo "     self_addr: 10.0.0.120:7000"
    echo "     partner_addrs: []"
    echo "3. Redémarrer: docker start patroni"
    echo "4. Ajouter les replicas avec la config Raft"
    echo "═══════════════════════════════════════════════════════════════════"
else
    echo -e "$KO L'initialisation a échoué même avec dummy DCS"
    echo ""
    echo "Logs d'erreur:"
    ssh root@10.0.0.120 'docker logs patroni --tail 30' 2>&1
fi
