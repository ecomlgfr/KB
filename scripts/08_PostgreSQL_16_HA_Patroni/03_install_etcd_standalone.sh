#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          03_INSTALL_ETCD_STANDALONE - etcd sur k3s-masters        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

ETCD_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)
ETCD_VERSION="3.5.15"

echo ""
echo "═══ Installation etcd $ETCD_VERSION (standalone) ═══"
echo ""

# Récupérer les IPs privées
ETCD_IPS=()
for node in "${ETCD_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -n "$ip" ] && ETCD_IPS+=("$ip")
done

[ ${#ETCD_IPS[@]} -lt 3 ] && { echo -e "$KO Impossible de trouver 3 IPs pour etcd"; exit 1; }

# Construction cluster string
INITIAL_CLUSTER=""
for i in "${!ETCD_NODES[@]}"; do
    [ -n "$INITIAL_CLUSTER" ] && INITIAL_CLUSTER+=","
    INITIAL_CLUSTER+="${ETCD_NODES[$i]}=http://${ETCD_IPS[$i]}:2380"
done

echo "Cluster: $INITIAL_CLUSTER"
echo ""

# Déployer sur chaque master
for i in "${!ETCD_NODES[@]}"; do
    NODE="${ETCD_NODES[$i]}"
    IP="${ETCD_IPS[$i]}"
    
    echo "→ $NODE ($IP)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash -s "$NODE" "$IP" "$INITIAL_CLUSTER" "$ETCD_VERSION" <<'REMOTE'
set -u
set -o pipefail

NODE_NAME="$1"
NODE_IP="$2"
INITIAL_CLUSTER="$3"
ETCD_VERSION="$4"

mkdir -p /opt/keybuzz/etcd/{data,config}

# Arrêter si existe
docker stop etcd 2>/dev/null || true
docker rm etcd 2>/dev/null || true

# Démarrer etcd
docker run -d \
  --name etcd \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/etcd/data:/etcd-data \
  gcr.io/etcd-development/etcd:v${ETCD_VERSION} \
  etcd \
  --name ${NODE_NAME} \
  --data-dir /etcd-data \
  --listen-client-urls http://${NODE_IP}:2379,http://127.0.0.1:2379 \
  --advertise-client-urls http://${NODE_IP}:2379 \
  --listen-peer-urls http://${NODE_IP}:2380 \
  --initial-advertise-peer-urls http://${NODE_IP}:2380 \
  --initial-cluster ${INITIAL_CLUSTER} \
  --initial-cluster-token etcd-keybuzz \
  --initial-cluster-state new \
  --heartbeat-interval 1000 \
  --election-timeout 5000 \
  --enable-v2=false

sleep 3

if docker ps | grep -q etcd; then
    echo "✓ etcd démarré"
else
    echo "✗ etcd échec"
    exit 1
fi
REMOTE
    
    [ $? -eq 0 ] && echo -e "  $OK" || echo -e "  $KO"
done

echo ""
echo "Attente stabilisation cluster (10s)..."
sleep 10

echo ""
echo -e "$OK Installation etcd terminée"
echo "Vérification : ./04_check_etcd.sh"
