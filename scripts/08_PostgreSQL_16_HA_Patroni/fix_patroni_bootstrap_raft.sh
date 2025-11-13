#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       FIX_PATRONI_BOOTSTRAP_RAFT - Diagnostic et Correction        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Charger credentials
source /opt/keybuzz-installer/credentials/postgres.env

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo ""
echo "1. Diagnostic du problème..."
echo ""

# Vérifier db-master-01
MASTER_IP="${NODE_IPS[db-master-01]}"

echo "  Vérification db-master-01..."

# État du container
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" bash <<'DIAG'
echo -n "    Container status: "
if docker ps -a | grep -q patroni; then
    STATUS=$(docker ps -a | grep patroni | awk '{print $(NF-1), $NF}')
    echo "$STATUS"
    
    if ! docker ps | grep -q patroni; then
        echo "    Container arrêté - Logs récents:"
        docker logs patroni --tail 20 2>&1 | grep -E "ERROR|FATAL|Failed" | head -5 | sed 's/^/      /'
    fi
else
    echo "Pas de container"
fi

echo -n "    Volume monté: "
if mountpoint -q /opt/keybuzz/postgres/data; then
    FS_TYPE=$(findmnt -n -o FSTYPE /opt/keybuzz/postgres/data)
    SIZE=$(df -h /opt/keybuzz/postgres/data | tail -1 | awk '{print $2}')
    echo "OUI ($FS_TYPE, $SIZE)"
    
    echo -n "    Permissions: "
    ls -ld /opt/keybuzz/postgres/data | awk '{print $1, $3":"$4}'
    
    echo -n "    Contenu data: "
    COUNT=$(ls -la /opt/keybuzz/postgres/data 2>/dev/null | wc -l)
    echo "$COUNT fichiers"
else
    echo "NON"
fi

echo -n "    Répertoire Raft: "
if [ -d /opt/keybuzz/postgres/raft ]; then
    COUNT=$(ls -la /opt/keybuzz/postgres/raft 2>/dev/null | wc -l)
    echo "OUI ($COUNT fichiers)"
else
    echo "NON"
fi

echo -n "    Port Raft 7000: "
if nc -zv localhost 7000 2>&1 | grep -q succeeded; then
    echo "OUVERT"
else
    echo "FERMÉ"
fi
DIAG

echo ""
echo "2. Configuration firewall pour Raft..."
echo ""

# Ouvrir le port 7000 sur tous les nœuds
for node in "${DB_NODES[@]}"; do
    echo -n "  $node: Port 7000... "
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" \
        "ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni Raft' 2>/dev/null; ufw --force reload >/dev/null 2>&1"
    echo -e "$OK"
done

echo ""
echo "3. Nettoyage complet et réparation..."
echo ""

# Arrêter tous les containers
echo "  Arrêt de tous les containers..."
for node in "${DB_NODES[@]}"; do
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" \
        "docker stop patroni 2>/dev/null; docker rm patroni 2>/dev/null" &
done
wait

# Nettoyer et préparer db-master-01
echo ""
echo "4. Préparation db-master-01 pour bootstrap avec Raft..."

# Construire la liste des partenaires Raft pour master-01
RAFT_PARTNERS="${NODE_IPS[db-slave-01]}:7000,${NODE_IPS[db-slave-02]}:7000"

ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" bash -s "$POSTGRES_PASSWORD" "$RAFT_PARTNERS" <<'FIX_MASTER'
PG_PASSWORD="$1"
RAFT_PARTNERS="$2"

# Nettoyer complètement les données
echo "  Nettoyage données..."
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /opt/keybuzz/postgres/archive/*

# Créer le répertoire Raft
mkdir -p /opt/keybuzz/postgres/raft

# Vérifier/corriger les permissions
echo "  Correction permissions..."
chown -R 999:999 /opt/keybuzz/postgres/data
chown -R 999:999 /opt/keybuzz/postgres/raft
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft

# Recréer la configuration Patroni avec Raft
echo "  Nouvelle configuration Raft..."
cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: db-master-01

restapi:
  listen: 10.0.0.120:8008
  connect_address: 10.0.0.120:8008
  authentication:
    username: patroni
    password: '$PG_PASSWORD'

# DCS Raft intégré
raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: 10.0.0.120:7000
  partner_addrs:
$(echo "$RAFT_PARTNERS" | tr ',' '\n' | sed 's/^/    - /')

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
        max_wal_senders: 10
        hot_standby: 'on'
        wal_log_hints: 'on'
        archive_mode: 'on'
        archive_command: 'test ! -f /opt/keybuzz/postgres/archive/%f && cp %p /opt/keybuzz/postgres/archive/%f'

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5
    - host all postgres 10.0.0.0/16 md5

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
  listen: '*:5432'
  connect_address: 10.0.0.120:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
      password: '$PG_PASSWORD'
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

# Rebuild l'image avec Raft
cd /opt/keybuzz/patroni

cat > Dockerfile <<DOCKERFILE
FROM postgres:17

RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-dev \
    gcc \
    python3-psycopg2 \
    curl \
    && pip3 install --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary \
        python-dateutil \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY config/patroni.yml /etc/patroni/patroni.yml

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

echo "  Build image Docker..."
docker build -t patroni-pg17-raft:latest . >/dev/null 2>&1
FIX_MASTER

echo ""
echo "5. Démarrage db-master-01 avec Raft..."

ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" bash <<'START_NEW'
# Démarrer avec logging détaillé
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data:rw \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft:rw \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive:rw \
  -v /opt/keybuzz/patroni/config:/etc/patroni:ro \
  patroni-pg17-raft:latest

echo "  Attente bootstrap Raft (30s)..."
sleep 30

# Vérifier le status
echo ""
echo "  État après démarrage:"
if docker ps | grep -q patroni; then
    echo "    Container: RUNNING"
    
    # Test PostgreSQL
    if docker exec patroni psql -U postgres -c 'SELECT 1' &>/dev/null; then
        echo "    PostgreSQL: OK"
    else
        echo "    PostgreSQL: KO"
        echo "    Derniers logs:"
        docker logs patroni --tail 20 2>&1 | grep -E "ERROR|FATAL|Failed|INFO.*initialized" | tail -10
    fi
    
    # Test port Raft
    if nc -zv localhost 7000 2>&1 | grep -q succeeded; then
        echo "    Port Raft 7000: OK"
    else
        echo "    Port Raft 7000: KO"
    fi
else
    echo "    Container: STOPPED"
    echo "    Raison:"
    docker logs patroni --tail 30 2>&1 | grep -E "ERROR|FATAL|Failed" | tail -10
fi
START_NEW

echo ""
echo "6. Vérification API Patroni..."

# Tester l'API Patroni
if curl -s "http://$MASTER_IP:8008/patroni" >/dev/null 2>&1; then
    STATE=$(curl -s "http://$MASTER_IP:8008/patroni" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"Role: {d.get('role','?')}, State: {d.get('state','?')}\")" 2>/dev/null)
    echo -e "  $OK Patroni API répond: $STATE"
    
    # Si OK, démarrer les replicas
    if [[ "$STATE" == *"master"* ]] || [[ "$STATE" == *"leader"* ]] || [[ "$STATE" == *"running"* ]]; then
        echo ""
        echo "7. Démarrage des replicas avec Raft..."
        
        for node in db-slave-01 db-slave-02; do
            echo "  Configuration $node..."
            
            NODE_IP="${NODE_IPS[$node]}"
            
            # Construire la liste des partenaires pour ce nœud
            PARTNERS=""
            for other in "${DB_NODES[@]}"; do
                if [ "$other" != "$node" ]; then
                    [ -n "$PARTNERS" ] && PARTNERS="$PARTNERS,"
                    PARTNERS="${PARTNERS}${NODE_IPS[$other]}:7000"
                fi
            done
            
            ssh -o StrictHostKeyChecking=no root@"$NODE_IP" bash -s "$node" "$NODE_IP" "$POSTGRES_PASSWORD" "$PARTNERS" <<'START_REPLICA'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
RAFT_PARTNERS="$4"

# Nettoyer
docker stop patroni 2>/dev/null
docker rm patroni 2>/dev/null
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*

# Créer le répertoire Raft
mkdir -p /opt/keybuzz/postgres/raft
chown 999:999 /opt/keybuzz/postgres/raft

# Configuration Patroni avec Raft
cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: $NODE_NAME

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008
  authentication:
    username: patroni
    password: '$PG_PASSWORD'

# DCS Raft
raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${NODE_IP}:7000
  partner_addrs:
$(echo "$RAFT_PARTNERS" | tr ',' '\n' | sed 's/^/    - /')

postgresql:
  listen: '*:5432'
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
      password: '$PG_PASSWORD'
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

# Build image si nécessaire
cd /opt/keybuzz/patroni
if ! docker images | grep -q "patroni-pg17-raft"; then
    cat > Dockerfile <<DOCKERFILE
FROM postgres:17

RUN apt-get update && apt-get install -y \
    python3-pip curl \
    && pip3 install --break-system-packages patroni[raft]==3.3.2 psycopg2-binary \
    && apt-get clean

COPY config/patroni.yml /etc/patroni/patroni.yml

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE
    docker build -t patroni-pg17-raft:latest . >/dev/null 2>&1
fi

# Démarrer
docker run -d \
  --name patroni \
  --hostname $NODE_NAME \
  --network host \
  --restart unless-stopped \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-pg17-raft:latest

sleep 10
START_REPLICA
        done
        
        echo "  Attente stabilisation (15s)..."
        sleep 15
    fi
else
    echo -e "  $KO Patroni API ne répond pas"
    echo ""
    echo "Actions suggérées:"
    echo "  1. Vérifier les logs: ssh root@$MASTER_IP 'docker logs patroni --tail 50'"
    echo "  2. Vérifier le port Raft: ssh root@$MASTER_IP 'nc -zv localhost 7000'"
    echo "  3. Relancer avec clean complet: ./clean_patroni_cluster.sh"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAT FINAL DU CLUSTER PATRONI RAFT:"
echo "═══════════════════════════════════════════════════════════════════"

# Vérifier l'état du cluster
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo ""
    echo "$node ($ip):"
    
    # API Patroni
    echo -n "  API Patroni: "
    if STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"state={d.get('state','?')}, role={d.get('role','?')}\")" 2>/dev/null); then
        echo -e "$OK $STATE"
    else
        echo -e "$KO"
    fi
    
    # Port Raft
    echo -n "  Port Raft: "
    if ssh -o StrictHostKeyChecking=no root@"$ip" "nc -zv localhost 7000 2>&1 | grep -q succeeded"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
curl -s "http://$MASTER_IP:8008/cluster" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Cluster non accessible"

# Log final
MAIN_LOG="$LOG_DIR/fix_patroni_bootstrap_raft_$TIMESTAMP.log"
echo "" | tee -a "$MAIN_LOG"
echo "Log: $MAIN_LOG" | tee -a "$MAIN_LOG"
echo "═══════════════════════════════════════════════════════════════════"
