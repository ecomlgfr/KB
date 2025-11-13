#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       PATRONI_RAFT_FIXED - Correction du problème utilisateur      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-KeyBuzz2024Postgres}"

echo ""
echo "1. Arrêt et nettoyage complet sur tous les nœuds..."

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEAN' 2>/dev/null
# Arrêter containers
docker stop patroni 2>/dev/null
docker rm -f patroni 2>/dev/null

# Nettoyer complètement  
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /var/lib/postgresql/data/*

# Recréer structure
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/config
mkdir -p /var/lib/postgresql

# IMPORTANT: Permissions correctes AVANT le démarrage
chown -R 999:999 /opt/keybuzz/postgres
chown -R 999:999 /var/lib/postgresql
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft
chmod 755 /opt/keybuzz/postgres/archive
CLEAN
    echo -e "$OK"
done

echo ""
echo "2. Création des configurations Patroni..."

# Configuration db-master-01
echo "  db-master-01..."
ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'MASTER_CONFIG'
cat > /opt/keybuzz/patroni/config/patroni.yml <<'EOF'
scope: postgres-keybuzz
name: db-master-01

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.120:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.120:7000
  partner_addrs:
    - 10.0.0.121:7000
    - 10.0.0.122:7000

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
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
  bin_dir: /usr/lib/postgresql/17/bin
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

chown 999:999 /opt/keybuzz/patroni/config/patroni.yml
MASTER_CONFIG

# Configuration db-slave-01
echo "  db-slave-01..."
ssh -o StrictHostKeyChecking=no root@10.0.0.121 bash <<'SLAVE1_CONFIG'
cat > /opt/keybuzz/patroni/config/patroni.yml <<'EOF'
scope: postgres-keybuzz
name: db-slave-01

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.121:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.121:7000
  partner_addrs:
    - 10.0.0.120:7000
    - 10.0.0.122:7000

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.121:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin
  authentication:
    superuser:
      username: postgres
      password: 'KeyBuzz2024Postgres'
    replication:
      username: replicator
      password: 'KeyBuzz2024Postgres'
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

chown 999:999 /opt/keybuzz/patroni/config/patroni.yml
SLAVE1_CONFIG

# Configuration db-slave-02
echo "  db-slave-02..."
ssh -o StrictHostKeyChecking=no root@10.0.0.122 bash <<'SLAVE2_CONFIG'
cat > /opt/keybuzz/patroni/config/patroni.yml <<'EOF'
scope: postgres-keybuzz
name: db-slave-02

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.122:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.122:7000
  partner_addrs:
    - 10.0.0.120:7000
    - 10.0.0.121:7000

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.122:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/17/bin
  authentication:
    superuser:
      username: postgres
      password: 'KeyBuzz2024Postgres'
    replication:
      username: replicator
      password: 'KeyBuzz2024Postgres'
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

chown 999:999 /opt/keybuzz/patroni/config/patroni.yml
SLAVE2_CONFIG

echo ""
echo "3. Construction image Docker avec USER postgres..."

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Build sur $ip... "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'BUILD' >/dev/null 2>&1
cd /opt/keybuzz/patroni

cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

# Installer Patroni
RUN apt-get update && \
    apt-get install -y python3-pip python3-dev gcc curl && \
    pip3 install --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary \
        python-dateutil && \
    apt-get remove -y gcc && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Créer les répertoires avec les bonnes permissions
RUN mkdir -p /opt/keybuzz/postgres/raft && \
    mkdir -p /var/lib/postgresql/data && \
    chown -R postgres:postgres /opt/keybuzz/postgres && \
    chown -R postgres:postgres /var/lib/postgresql && \
    chmod 700 /var/lib/postgresql/data

# IMPORTANT: Passer en utilisateur postgres
USER postgres

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-fixed:latest .
BUILD
    echo -e "$OK"
done

echo ""
echo "4. Démarrage du cluster..."

# Démarrer db-master-01 en premier
echo "  Démarrage db-master-01 (bootstrap)..."
ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'START_MASTER'
# S'assurer des permissions une dernière fois
chown -R 999:999 /opt/keybuzz/postgres
chown -R 999:999 /var/lib/postgresql

# Démarrer le container avec l'utilisateur postgres (UID 999)
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  --user 999:999 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-fixed:latest
START_MASTER

echo "  Attente initialisation (30s)..."
sleep 30

# Vérifier le master
echo -n "  Vérification master: "
if curl -s http://10.0.0.120:8008/patroni 2>/dev/null | grep -q '"state":"running"'; then
    echo -e "$OK"
    
    # Démarrer les slaves
    echo ""
    echo "  Démarrage des replicas..."
    
    for node_ip in 10.0.0.121 10.0.0.122; do
        echo -n "    $node_ip: "
        
        ssh -o StrictHostKeyChecking=no root@"$node_ip" bash <<'START_SLAVE'
# Permissions
chown -R 999:999 /opt/keybuzz/postgres
chown -R 999:999 /var/lib/postgresql

# Démarrer
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  --user 999:999 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-fixed:latest
START_SLAVE
        echo -e "$OK"
        sleep 10
    done
else
    echo -e "$KO"
    echo "  Erreurs du master:"
    ssh root@10.0.0.120 'docker logs patroni --tail 20 2>&1 | grep -E "ERROR|error|Failed"'
fi

echo ""
echo "5. Attente stabilisation (20s)..."
sleep 20

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VÉRIFICATION FINALE"
echo "═══════════════════════════════════════════════════════════════════"

# État de chaque nœud
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo ""
    echo "Nœud $ip:"
    
    # Container
    echo -n "  Container: "
    if ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q patroni" 2>/dev/null; then
        echo -e "$OK"
        
        # API Patroni
        echo -n "  API Patroni: "
        STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('state','?')}/{d.get('role','?')}\")" 2>/dev/null || echo "KO")
        if [[ "$STATE" == *"running"* ]] || [[ "$STATE" == *"streaming"* ]]; then
            echo -e "$OK ($STATE)"
        else
            echo "$STATE"
        fi
        
        # PostgreSQL
        echo -n "  PostgreSQL: "
        if ssh -o StrictHostKeyChecking=no root@"$ip" \
            "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting"; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    else
        echo -e "$KO"
        echo "  Logs:"
        ssh -o StrictHostKeyChecking=no root@"$ip" "docker logs patroni --tail 5 2>&1" 2>/dev/null | sed 's/^/    /'
    fi
done

echo ""
echo "Cluster Status:"
curl -s http://10.0.0.120:8008/cluster 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  Non accessible"

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Test final
if curl -s http://10.0.0.120:8008/cluster 2>/dev/null | grep -q '"role":"leader"'; then
    echo -e "$OK CLUSTER PATRONI RAFT OPÉRATIONNEL !"
    echo ""
    echo "Test de connexion PostgreSQL:"
    ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT version()'" 2>/dev/null | head -1
    echo ""
    echo "Accès:"
    echo "  psql -h 10.0.0.120 -U postgres"
    echo "  Password: $POSTGRES_PASSWORD"
else
    echo -e "$KO Cluster non complètement opérationnel"
    echo ""
    echo "Debug:"
    echo "  ssh root@10.0.0.120 'docker logs patroni --tail 50'"
fi

echo "═══════════════════════════════════════════════════════════════════"
