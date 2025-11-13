#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX_PATRONI_BOOTSTRAP - Diagnostic et Correction           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)

# Charger credentials
source /opt/keybuzz-installer/credentials/postgres.env
source /opt/keybuzz-installer/credentials/etcd_endpoints.txt

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

echo -n "    etcd accessible: "
if curl -s http://10.0.0.100:2379/version >/dev/null 2>&1; then
    echo "OUI"
else
    echo "NON"
fi
DIAG

echo ""
echo "2. Nettoyage complet et réparation..."
echo ""

# Arrêter tous les containers
echo "  Arrêt de tous les containers..."
for node in "${DB_NODES[@]}"; do
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" \
        "docker stop patroni 2>/dev/null; docker rm patroni 2>/dev/null" &
done
wait

# Nettoyer etcd
echo "  Nettoyage etcd..."
ssh -o StrictHostKeyChecking=no root@10.0.0.100 \
    "docker exec etcd etcdctl --endpoints=http://127.0.0.1:2379 del /service/postgres-keybuzz --prefix" 2>/dev/null

# Nettoyer et préparer db-master-01
echo ""
echo "3. Préparation db-master-01 pour bootstrap..."

ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" bash -s "$POSTGRES_PASSWORD" "$ETCD_HOSTS" <<'FIX_MASTER'
PG_PASSWORD="$1"
ETCD_HOSTS="$2"

# Nettoyer complètement les données
echo "  Nettoyage données..."
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/archive/*

# Vérifier/corriger les permissions
echo "  Correction permissions..."
chown -R 999:999 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/data

# Recréer la configuration Patroni SIMPLIFIÉE
echo "  Nouvelle configuration simplifiée..."
cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: db-master-01

restapi:
  listen: 10.0.0.120:8008
  connect_address: 10.0.0.120:8008

etcd3:
  hosts: $(echo $ETCD_HOSTS | sed 's/,/, /g')

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 100
        shared_buffers: 256MB
        wal_level: replica
        max_wal_senders: 10
        hot_standby: 'on'

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5

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

watchdog:
  mode: off
EOF

# Rebuild l'image avec config simple
cd /opt/keybuzz/patroni
docker build -t patroni-pg17:latest . >/dev/null 2>&1
FIX_MASTER

echo ""
echo "4. Démarrage db-master-01 avec nouveau container..."

ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" bash <<'START_NEW'
# Démarrer avec logging détaillé
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -e PATRONI_LOG_LEVEL=DEBUG \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data:rw \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive:rw \
  -v /opt/keybuzz/patroni/config:/etc/patroni:ro \
  --user 999:999 \
  patroni-pg17:latest

echo "  Attente bootstrap (30s)..."
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
else
    echo "    Container: STOPPED"
    echo "    Raison:"
    docker logs patroni --tail 30 2>&1 | grep -E "ERROR|FATAL|Failed" | tail -10
fi
START_NEW

echo ""
echo "5. Vérification finale..."

# Tester l'API Patroni
if curl -s "http://$MASTER_IP:8008/patroni" >/dev/null 2>&1; then
    STATE=$(curl -s "http://$MASTER_IP:8008/patroni" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"Role: {d.get('role','?')}, State: {d.get('state','?')}\")" 2>/dev/null)
    echo -e "  $OK Patroni API répond: $STATE"
    
    # Si OK, démarrer les replicas
    if [[ "$STATE" == *"master"* ]] || [[ "$STATE" == *"leader"* ]]; then
        echo ""
        echo "6. Démarrage des replicas..."
        
        for node in db-slave-01 db-slave-02; do
            echo "  Démarrage $node..."
            ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" bash <<'START_REPLICA'
# Nettoyer
docker stop patroni 2>/dev/null
docker rm patroni 2>/dev/null
rm -rf /opt/keybuzz/postgres/data/*

# Démarrer
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-pg17:latest

sleep 5
START_REPLICA
        done
    fi
else
    echo -e "  $KO Patroni API ne répond pas"
    echo ""
    echo "Actions suggérées:"
    echo "  1. Vérifier les logs: ssh root@$MASTER_IP 'docker logs patroni --tail 50'"
    echo "  2. Vérifier etcd: ssh root@10.0.0.100 'docker exec etcd etcdctl member list'"
    echo "  3. Relancer avec clean complet: ./clean_patroni_cluster.sh"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
curl -s -u patroni:$POSTGRES_PASSWORD "http://$MASTER_IP:8008/cluster" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Cluster non accessible"
echo "═══════════════════════════════════════════════════════════════════"
