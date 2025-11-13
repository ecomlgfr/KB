#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         05_ETCD_TO_CLUSTER - Migration vers Cluster HA             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

ETCD_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)
ETCD_VERSION="3.5.15"

echo ""
echo "═══ Migration etcd standalone → cluster HA ═══"
echo ""

# Récupérer les IPs privées
declare -A NODE_IPS
for node in "${ETCD_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -z "$ip" ]; then
        echo -e "$KO IP introuvable pour $node"
        exit 1
    fi
    NODE_IPS[$node]=$ip
done

# Vérifier l'état actuel
echo "1. Vérification état actuel..."
echo ""

HEALTHY_NODES=0
for node in "${ETCD_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node ($ip): "
    
    # Vérifier si etcd tourne
    if ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q etcd" 2>/dev/null; then
        # Vérifier la santé
        if ssh -o StrictHostKeyChecking=no root@"$ip" \
            "docker exec etcd etcdctl --endpoints=http://127.0.0.1:2379 endpoint health" 2>/dev/null | grep -q "successfully committed"; then
            echo -e "$OK healthy"
            ((HEALTHY_NODES++))
        else
            echo -e "$WARN running but unhealthy"
        fi
    else
        echo -e "$KO not running"
    fi
done

echo ""
if [ $HEALTHY_NODES -lt 1 ]; then
    echo -e "$KO Aucun nœud etcd sain trouvé"
    echo "Lancez d'abord: ./03_install_etcd_standalone.sh"
    exit 1
fi

# Sauvegarder les données si nécessaire
echo "2. Sauvegarde des données etcd..."
echo ""

BACKUP_NODE=""
for node in "${ETCD_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    if ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q etcd" 2>/dev/null; then
        BACKUP_NODE=$node
        echo "  Sauvegarde depuis $node..."
        
        ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'BACKUP'
mkdir -p /opt/keybuzz/etcd/backup
docker exec etcd etcdctl \
    --endpoints=http://127.0.0.1:2379 \
    snapshot save /etcd-data/snapshot.db 2>/dev/null

if [ -f /opt/keybuzz/etcd/data/snapshot.db ]; then
    cp /opt/keybuzz/etcd/data/snapshot.db /opt/keybuzz/etcd/backup/snapshot-$(date +%Y%m%d-%H%M%S).db
    echo "    ✓ Snapshot créé"
else
    echo "    ⚠ Pas de données à sauvegarder"
fi
BACKUP
        break
    fi
done

echo ""
echo "3. Arrêt des instances standalone..."
echo ""

for node in "${ETCD_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STOP'
docker stop etcd 2>/dev/null || true
docker rm etcd 2>/dev/null || true
# Nettoyer les données pour repartir propre en cluster
rm -rf /opt/keybuzz/etcd/data/*
echo "✓ arrêté et nettoyé"
STOP
done

echo ""
echo "4. Démarrage en mode cluster HA..."
echo ""

# Construction de la chaîne INITIAL_CLUSTER
INITIAL_CLUSTER=""
for node in "${ETCD_NODES[@]}"; do
    [ -n "$INITIAL_CLUSTER" ] && INITIAL_CLUSTER+=","
    INITIAL_CLUSTER+="${node}=http://${NODE_IPS[$node]}:2380"
done

echo "  Configuration cluster: $INITIAL_CLUSTER"
echo ""

# Démarrer tous les nœuds en même temps pour le cluster
for node in "${ETCD_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "  Démarrage $node ($ip)..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$ip" "$INITIAL_CLUSTER" "$ETCD_VERSION" <<'CLUSTER' &
set -u

NODE_NAME="$1"
NODE_IP="$2"
INITIAL_CLUSTER="$3"
ETCD_VERSION="$4"

# Créer les répertoires
mkdir -p /opt/keybuzz/etcd/{data,config,backup}

# Créer le compose file pour le cluster
cat > /opt/keybuzz/etcd/docker-compose.yml <<EOF
version: '3.8'

services:
  etcd:
    image: gcr.io/etcd-development/etcd:v${ETCD_VERSION}
    container_name: etcd
    network_mode: host
    restart: unless-stopped
    volumes:
      - /opt/keybuzz/etcd/data:/etcd-data
    command:
      - etcd
      - --name=${NODE_NAME}
      - --data-dir=/etcd-data
      - --listen-client-urls=http://${NODE_IP}:2379,http://127.0.0.1:2379
      - --advertise-client-urls=http://${NODE_IP}:2379
      - --listen-peer-urls=http://${NODE_IP}:2380
      - --initial-advertise-peer-urls=http://${NODE_IP}:2380
      - --initial-cluster=${INITIAL_CLUSTER}
      - --initial-cluster-token=etcd-keybuzz-cluster
      - --initial-cluster-state=new
      - --heartbeat-interval=100
      - --election-timeout=500
      - --snapshot-count=10000
      - --auto-compaction-retention=1h
      - --enable-v2=false
    environment:
      ETCD_UNSUPPORTED_ARCH: arm64
EOF

# Démarrer avec docker compose
cd /opt/keybuzz/etcd
docker compose up -d

echo "    ✓ $NODE_NAME lancé"
CLUSTER
done

# Attendre que tous les jobs se terminent
wait

echo ""
echo "5. Attente stabilisation cluster (15s)..."
sleep 15

echo ""
echo "6. Vérification du cluster..."
echo ""

CLUSTER_OK=0
for node in "${ETCD_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    # Vérifier que le conteneur tourne
    if ! ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q etcd" 2>/dev/null; then
        echo -e "$KO conteneur arrêté"
        continue
    fi
    
    # Vérifier la santé
    HEALTH=$(ssh -o StrictHostKeyChecking=no root@"$ip" \
        "docker exec etcd etcdctl --endpoints=http://127.0.0.1:2379 endpoint health 2>&1" 2>/dev/null)
    
    if echo "$HEALTH" | grep -q "successfully committed"; then
        echo -e "$OK healthy"
        ((CLUSTER_OK++))
    else
        echo -e "$KO unhealthy"
    fi
done

echo ""
echo "7. État du cluster..."
echo ""

if [ $CLUSTER_OK -ge 2 ]; then
    # Afficher l'état du cluster depuis un nœud fonctionnel
    for node in "${ETCD_NODES[@]}"; do
        ip="${NODE_IPS[$node]}"
        if ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q etcd" 2>/dev/null; then
            echo "  Liste des membres:"
            ssh -o StrictHostKeyChecking=no root@"$ip" \
                "docker exec etcd etcdctl --endpoints=http://127.0.0.1:2379 member list" 2>/dev/null | sed 's/^/    /'
            
            echo ""
            echo "  État des endpoints:"
            for check_node in "${ETCD_NODES[@]}"; do
                check_ip="${NODE_IPS[$check_node]}"
                echo -n "    http://$check_ip:2379: "
                ssh -o StrictHostKeyChecking=no root@"$ip" \
                    "docker exec etcd etcdctl --endpoints=http://$check_ip:2379 endpoint status --write-out=table" 2>/dev/null | grep -q "$check_ip" && echo "OK" || echo "KO"
            done
            break
        fi
    done
    
    echo ""
    echo "8. Test connectivité depuis DB..."
    echo ""
    
    # Test depuis un nœud DB
    DB_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
    if [ -n "$DB_IP" ]; then
        echo "  Test depuis db-master-01:"
        for node in "${ETCD_NODES[@]}"; do
            etcd_ip="${NODE_IPS[$node]}"
            echo -n "    $node ($etcd_ip:2379): "
            if ssh -o StrictHostKeyChecking=no root@"$DB_IP" \
                "curl -s http://$etcd_ip:2379/version" 2>/dev/null | grep -q "etcdserver"; then
                echo -e "$OK accessible"
            else
                echo -e "$KO inaccessible"
            fi
        done
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$OK CLUSTER ETCD HA OPÉRATIONNEL ($CLUSTER_OK/3 nœuds)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Configuration pour Patroni:"
    echo "  etcd3:"
    echo "    hosts:"
    
    for node in "${ETCD_NODES[@]}"; do
        echo "      - ${NODE_IPS[$node]}:2379"
    done
    
    echo ""
    echo "Prochaine étape:"
    echo "  ./06_install_postgres_patroni.sh"
    echo ""
    
    # Sauvegarder la config pour Patroni
    cat > /opt/keybuzz-installer/credentials/etcd_endpoints.txt <<EOF
# etcd endpoints pour Patroni
ETCD_HOSTS="${NODE_IPS[k3s-master-01]}:2379,${NODE_IPS[k3s-master-02]}:2379,${NODE_IPS[k3s-master-03]}:2379"
EOF
    
    exit 0
else
    echo ""
    echo -e "$KO CLUSTER ETCD NON OPÉRATIONNEL"
    echo ""
    echo "Debug:"
    echo "  1. Vérifier les logs:"
    for node in "${ETCD_NODES[@]}"; do
        echo "     ssh root@${NODE_IPS[$node]} 'docker logs etcd'"
    done
    echo ""
    echo "  2. Relancer la migration:"
    echo "     $0"
    echo ""
    exit 1
fi
