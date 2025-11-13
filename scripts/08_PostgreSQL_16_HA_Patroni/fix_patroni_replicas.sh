#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX_PATRONI_REPLICAS - Réparation des Replicas             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
REPLICA_NODES=(db-slave-01 db-slave-02)

# Charger credentials
source /opt/keybuzz-installer/credentials/postgres.env
source /opt/keybuzz-installer/credentials/etcd_endpoints.txt

# Récupérer les IPs
declare -A NODE_IPS
NODE_IPS[db-master-01]=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
NODE_IPS[db-slave-01]=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
NODE_IPS[db-slave-02]=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "1. État actuel du cluster..."
curl -s "http://${NODE_IPS[db-master-01]}:8008/cluster" | jq '.members[] | {name: .name, role: .role, state: .state}'

echo ""
echo "2. Vérification du leader..."
LEADER_STATE=$(curl -s "http://${NODE_IPS[db-master-01]}:8008/patroni" | jq -r '.state')
if [ "$LEADER_STATE" = "running" ]; then
    echo -e "  $OK db-master-01 est leader et opérationnel"
else
    echo -e "  $KO db-master-01 n'est pas opérationnel"
    exit 1
fi

echo ""
echo "3. Réparation des replicas..."

for node in "${REPLICA_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo ""
    echo "  Traitement $node ($ip)..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$ip" "$POSTGRES_PASSWORD" "$ETCD_HOSTS" <<'FIX_REPLICA'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
ETCD_HOSTS="$4"

echo "    Arrêt du container..."
docker stop patroni 2>/dev/null
docker rm patroni 2>/dev/null

echo "    Nettoyage des données..."
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/archive/*

echo "    Correction permissions..."
chown -R 999:999 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/data

echo "    Configuration simplifiée pour replica..."
mkdir -p /opt/keybuzz/patroni/config

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: $NODE_NAME

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008

etcd3:
  hosts: $(echo $ETCD_HOSTS | sed 's/,/, /g')

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

echo "    Rebuild image..."
cd /opt/keybuzz/patroni

cat > Dockerfile <<DOCKERFILE
FROM postgres:17

RUN apt-get update && apt-get install -y python3-pip curl && \
    pip3 install --break-system-packages patroni[etcd3]==3.3.2 psycopg2-binary && \
    apt-get clean

COPY config/patroni.yml /etc/patroni/patroni.yml

EXPOSE 5432 8008

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-pg17:latest . >/dev/null 2>&1

echo "    Démarrage du replica..."
docker run -d \
  --name patroni \
  --hostname $NODE_NAME \
  --network host \
  --restart unless-stopped \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data:rw \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive:rw \
  -v /opt/keybuzz/patroni/config:/etc/patroni:ro \
  --user 999:999 \
  patroni-pg17:latest

echo "    Attente synchronisation (20s)..."
sleep 20

# Vérifier l'état
if docker ps | grep -q patroni; then
    echo "    Container: RUNNING"
    
    # Vérifier l'état via API
    STATE=$(curl -s "http://${NODE_IP}:8008/patroni" 2>/dev/null | jq -r '.state' 2>/dev/null)
    if [ "$STATE" = "running" ] || [ "$STATE" = "streaming" ]; then
        echo "    État: $STATE - OK"
    else
        echo "    État: $STATE - Vérification des logs..."
        docker logs patroni --tail 10 2>&1 | grep -E "ERROR|INFO.*streaming" | tail -5
    fi
else
    echo "    Container: STOPPED"
    echo "    Derniers logs:"
    docker logs patroni --tail 20 2>&1 | grep -E "ERROR|FATAL" | tail -10
fi
FIX_REPLICA
done

echo ""
echo "4. Attente stabilisation finale (15s)..."
sleep 15

echo ""
echo "5. Vérification du cluster..."
echo ""

CLUSTER_STATE=$(curl -s "http://${NODE_IPS[db-master-01]}:8008/cluster")
echo "$CLUSTER_STATE" | jq

# Analyser l'état
LEADER=$(echo "$CLUSTER_STATE" | jq -r '.members[] | select(.role=="leader") | .name')
REPLICAS_OK=$(echo "$CLUSTER_STATE" | jq -r '.members[] | select(.role=="replica" and .state=="running") | .name' | wc -l)
REPLICAS_FAILED=$(echo "$CLUSTER_STATE" | jq -r '.members[] | select(.state=="start failed" or .lag=="unknown") | .name' | wc -l)

echo ""
echo "Résumé:"
echo "  Leader: $LEADER"
echo "  Replicas fonctionnels: $REPLICAS_OK"
echo "  Replicas en échec: $REPLICAS_FAILED"

if [ "$REPLICAS_FAILED" -eq 0 ]; then
    echo ""
    echo -e "$OK CLUSTER PLEINEMENT OPÉRATIONNEL"
    
    # Test de réplication
    echo ""
    echo "6. Test de réplication..."
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[db-master-01]}" \
        "docker exec patroni psql -U postgres -c \"
        CREATE TABLE IF NOT EXISTS test_repl (id serial, ts timestamp default now());
        INSERT INTO test_repl DEFAULT VALUES RETURNING *;
        SELECT * FROM pg_stat_replication;
        \""
else
    echo ""
    echo -e "$KO Certains replicas sont encore en échec"
    echo ""
    echo "Actions suggérées:"
    echo "  1. Vérifier les logs des replicas en échec"
    
    for node in "${REPLICA_NODES[@]}"; do
        STATE=$(echo "$CLUSTER_STATE" | jq -r ".members[] | select(.name==\"$node\") | .state")
        if [ "$STATE" != "running" ] && [ "$STATE" != "streaming" ]; then
            echo "     ssh root@${NODE_IPS[$node]} 'docker logs patroni --tail 30'"
        fi
    done
    
    echo "  2. Essayer un restart forcé:"
    echo "     for node in db-slave-01 db-slave-02; do"
    echo "       ssh root@\${IP} 'docker restart patroni'"
    echo "     done"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
