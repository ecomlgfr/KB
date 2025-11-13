#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              ETCD CLUSTER DEPLOY (DCS for Patroni)                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR"

usage() {
    echo "Usage: $0 --hosts k3s-master-01,k3s-master-02,k3s-master-03"
    exit 1
}

HOSTS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts) HOSTS="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$HOSTS" ]] && usage

IFS=',' read -ra HOST_ARRAY <<< "$HOSTS"
[[ ${#HOST_ARRAY[@]} -ne 3 ]] && { echo -e "$KO Besoin de 3 hosts exactement"; exit 1; }

[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

declare -A HOST_IPS
for host in "${HOST_ARRAY[@]}"; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && { echo -e "$KO IP introuvable pour $host dans servers.tsv"; exit 1; }
    HOST_IPS[$host]="$IP"
    echo "  $host → $IP"
done
echo

INITIAL_CLUSTER=""
for host in "${HOST_ARRAY[@]}"; do
    [[ -n "$INITIAL_CLUSTER" ]] && INITIAL_CLUSTER="${INITIAL_CLUSTER},"
    INITIAL_CLUSTER="${INITIAL_CLUSTER}${host}=http://${HOST_IPS[$host]}:2380"
done

echo "Cluster etcd: $INITIAL_CLUSTER"
echo

deploy_etcd_node() {
    local hostname="$1"
    local ip_privee="${HOST_IPS[$hostname]}"
    local logfile="$LOG_DIR/etcd_${hostname}_${TIMESTAMP}.log"
    
    echo "Déploiement etcd sur $hostname ($ip_privee)..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip_privee" "bash -s" <<EOSSH 2>&1 | tee "$logfile"
set -u
set -o pipefail

BASE="/opt/keybuzz/etcd"
DATA="\${BASE}/data"
CFG="\${BASE}/config"
LOGS="\${BASE}/logs"
ST="\${BASE}/status"

mkdir -p "\$DATA" "\$CFG" "\$LOGS" "\$ST"

if [[ ! -f /opt/keybuzz-installer/inventory/servers.tsv ]]; then
    mkdir -p /opt/keybuzz-installer/inventory
    echo "Copie servers.tsv local..."
fi

if ! mountpoint -q "\$DATA"; then
    echo "Recherche device pour etcd data..."
    DEV=""
    
    # D'abord essayer les devices by-id Hetzner
    for candidate in /dev/disk/by-id/scsi-*; do
        [[ -e "\$candidate" ]] || continue
        [[ "\$candidate" == *"-part"* ]] && continue
        
        real=\$(readlink -f "\$candidate" 2>/dev/null || echo "\$candidate")
        
        # Skip si déjà monté ailleurs
        if mount | grep -q "^\$real "; then
            continue
        fi
        
        # Skip device système (sda si c'est le boot)
        if [[ "\$real" == "/dev/sda" ]]; then
            if mount | grep -q "on / "; then
                continue
            fi
        fi
        
        DEV="\$real"
        break
    done
    
    # Si pas trouvé, chercher dans sd[b-z]/vd[b-z]
    if [[ -z "\$DEV" ]]; then
        for candidate in /dev/sd[b-z] /dev/vd[b-z]; do
            [[ -b "\$candidate" ]] || continue
            
            if mount | grep -q "^\$candidate "; then
                continue
            fi
            
            DEV="\$candidate"
            break
        done
    fi
    
    if [[ -n "\$DEV" ]]; then
        echo "Device trouvé: \$DEV"
        if ! blkid "\$DEV" 2>/dev/null | grep -q ext4; then
            echo "Formatage ext4..."
            mkfs.ext4 -F -m0 -O dir_index,has_journal,extent "\$DEV" >/dev/null 2>&1
        fi
        
        echo "Montage sur \$DATA..."
        mount "\$DEV" "\$DATA" 2>/dev/null || {
            echo "Erreur montage, vérification..."
            # Peut-être déjà monté entre temps
            if mountpoint -q "\$DATA"; then
                echo "Déjà monté finalement"
            else
                echo "ERREUR: Impossible de monter \$DEV"
                exit 1
            fi
        }
        
        UUID=\$(blkid -s UUID -o value "\$DEV")
        
        if ! grep -q " \$DATA " /etc/fstab; then
            echo "UUID=\$UUID \$DATA ext4 defaults,nofail 0 2" >> /etc/fstab
        fi
        
        [[ -d "\$DATA/lost+found" ]] && rm -rf "\$DATA/lost+found"
        echo "Volume etcd monté et configuré"
    else
        echo "Aucun volume libre trouvé, utilisation stockage système"
    fi
else
    echo "Volume déjà monté sur \$DATA"
    [[ -d "\$DATA/lost+found" ]] && rm -rf "\$DATA/lost+found"
fi

cat > "\$CFG/docker-compose.yml" <<COMPOSE
version: '3.8'

services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.13
    container_name: etcd
    restart: unless-stopped
    network_mode: host
    environment:
      ETCD_NAME: $hostname
      ETCD_DATA_DIR: /etcd-data
      ETCD_LISTEN_PEER_URLS: http://$ip_privee:2380
      ETCD_LISTEN_CLIENT_URLS: http://$ip_privee:2379,http://127.0.0.1:2379
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://$ip_privee:2380
      ETCD_ADVERTISE_CLIENT_URLS: http://$ip_privee:2379
      ETCD_INITIAL_CLUSTER: $INITIAL_CLUSTER
      ETCD_INITIAL_CLUSTER_STATE: new
      ETCD_INITIAL_CLUSTER_TOKEN: keybuzz-etcd-cluster
      ETCD_HEARTBEAT_INTERVAL: 100
      ETCD_ELECTION_TIMEOUT: 1000
      ETCD_MAX_SNAPSHOTS: 5
      ETCD_MAX_WALS: 5
      ETCD_AUTO_COMPACTION_RETENTION: 1
      ETCD_QUOTA_BACKEND_BYTES: 8589934592
      ETCDCTL_API: 3
    volumes:
      - /opt/keybuzz/etcd/data:/etcd-data
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
COMPOSE

cd "\$CFG"

if docker compose ps | grep -q etcd; then
    echo "Arrêt etcd existant..."
    docker compose down
fi

echo "Démarrage etcd..."
docker compose up -d

sleep 5

if docker compose ps | grep -q "Up"; then
    echo "etcd démarré"
    
    for i in {1..10}; do
        if docker exec etcd etcdctl endpoint health 2>/dev/null | grep -q "successfully"; then
            echo "etcd healthy"
            echo "OK" > "\$ST/STATE"
            exit 0
        fi
        sleep 2
    done
    
    echo "etcd timeout health check"
    echo "KO" > "\$ST/STATE"
    exit 1
else
    echo "etcd failed to start"
    echo "KO" > "\$ST/STATE"
    exit 1
fi
EOSSH
    
    local status=$?
    echo
    echo "Logs (tail -50) pour $hostname:"
    tail -n 50 "$logfile"
    echo
    
    return $status
}

FAILED=0
for host in "${HOST_ARRAY[@]}"; do
    if ! deploy_etcd_node "$host"; then
        echo -e "$KO Échec sur $host"
        ((FAILED++))
    else
        echo -e "$OK $host configuré"
    fi
done

echo
echo "═══════════════════════════════════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
    echo -e "$OK Cluster etcd déployé (${#HOST_ARRAY[@]} nœuds)"
    
    echo
    echo "Vérification cluster:"
    for host in "${HOST_ARRAY[@]}"; do
        ip="${HOST_IPS[$host]}"
        echo -n "  $host: "
        if ssh -o StrictHostKeyChecking=no root@"$ip" \
            "docker exec etcd etcdctl endpoint health" 2>/dev/null | grep -q "successfully"; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    done
    
    exit 0
else
    echo -e "$KO $FAILED nœuds en échec"
    exit 1
fi
