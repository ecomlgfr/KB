#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      PATRONI_RAFT_SIMPLE - Installation simplifiée avec debug      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Configuration de base
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-KeyBuzz2024Postgres}"

echo ""
echo "1. Arrêt et nettoyage complet..."

# Arrêter tous les containers sur tous les nœuds
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STOP' 2>/dev/null
docker stop patroni 2>/dev/null
docker rm -f patroni 2>/dev/null

# Nettoyer complètement
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /opt/keybuzz/patroni/config/*

# Recréer la structure
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/config

# Permissions PostgreSQL standard
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft
chmod 777 /opt/keybuzz/postgres/archive
STOP
    echo -e "$OK"
done

echo ""
echo "2. Création configuration MINIMALE pour db-master-01..."

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'CONFIG'
cat > /opt/keybuzz/patroni/config/patroni.yml <<'EOF'
scope: postgres-keybuzz
name: db-master-01

restapi:
  listen: 10.0.0.120:8008
  connect_address: 10.0.0.120:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.120:7000

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    postgresql:
      use_pg_rewind: false
      parameters:
        max_connections: 100
        shared_buffers: 256MB
        wal_level: replica
        hot_standby: 'on'
        max_wal_senders: 10
        max_replication_slots: 10

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 trust
    - host replication all 0.0.0.0/0 trust

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.120:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    superuser:
      username: postgres
      password: 'KeyBuzz2024Postgres'
    replication:
      username: replicator
      password: 'KeyBuzz2024Postgres'

watchdog:
  mode: off
EOF

echo "Config créée"
CONFIG

echo ""
echo "3. Construction image Docker SIMPLE..."

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'BUILD'
cd /opt/keybuzz/patroni

# Dockerfile simple sans Alpine
cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

RUN apt-get update && \
    apt-get install -y python3-pip python3-dev gcc && \
    pip3 install --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary && \
    apt-get clean

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

echo "Build de l'image..."
docker build -t patroni-simple:latest . 2>&1 | tail -5
BUILD

echo ""
echo "4. Test de démarrage en mode DEBUG..."

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'START_DEBUG'
echo "Démarrage avec logs verbeux..."

# Démarrer en mode foreground pour voir les erreurs
timeout 10 docker run --rm \
  --name patroni-debug \
  --hostname db-master-01 \
  --network host \
  -e PATRONI_LOG_LEVEL=DEBUG \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-simple:latest 2>&1 | head -50

echo ""
echo "Si pas d'erreur grave, démarrage en background..."
START_DEBUG

echo ""
echo "5. Démarrage réel si test OK..."

read -p "Le test a-t-il montré des erreurs graves? (y/N): " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "Arrêt. Vérifiez les erreurs ci-dessus."
    exit 1
fi

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'START_REAL'
# Arrêter le test
docker stop patroni-debug 2>/dev/null
docker rm patroni-debug 2>/dev/null

# Démarrer pour de vrai
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-simple:latest

echo "Container démarré"
sleep 10

# Vérifier
echo ""
echo "État du container:"
docker ps | grep patroni

echo ""
echo "Logs récents:"
docker logs patroni --tail 20

echo ""
echo "Test API:"
curl -s http://localhost:8008/patroni || echo "API pas encore prête"
START_REAL

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Si le master fonctionne, ajoutez les replicas avec:"
echo ""
echo "Pour db-slave-01:"
echo "  ssh root@10.0.0.121"
echo "  # Créer config avec partner_addrs: ['10.0.0.120:7000']"
echo "  # Démarrer container"
echo ""
echo "Pour db-slave-02:"
echo "  ssh root@10.0.0.122"
echo "  # Créer config avec partner_addrs: ['10.0.0.120:7000']"
echo "  # Démarrer container"
echo "═══════════════════════════════════════════════════════════════════"
