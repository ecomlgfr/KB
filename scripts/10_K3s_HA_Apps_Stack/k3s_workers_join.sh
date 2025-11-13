#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              K3S HA CLUSTER - Jonction 5 Workers                  ║"
echo "║                    (Agent mode, volumes /var/lib/containerd)      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

# Vérifications préalables
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
mkdir -p "$LOG_DIR" "$CREDENTIALS_DIR"

WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)
K3S_VERSION="${K3S_VERSION:-v1.28.5+k3s1}"

# Récupérer le token K3s
K3S_TOKEN_FILE="$CREDENTIALS_DIR/k3s-token.txt"
if [ ! -f "$K3S_TOKEN_FILE" ]; then
    echo -e "$KO Token K3s introuvable : $K3S_TOKEN_FILE"
    echo "Lancez d'abord : ./k3s_ha_install.sh"
    exit 1
fi

K3S_TOKEN=$(cat "$K3S_TOKEN_FILE")
if [ -z "$K3S_TOKEN" ]; then
    echo -e "$KO Token K3s vide"
    exit 1
fi

# Récupérer l'IP du master-01 pour la connexion
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable"
    exit 1
fi

# URL du serveur K3s (via master-01 directement pour la jonction)
K3S_SERVER_URL="https://${IP_MASTER01}:6443"

echo ""
echo "═══ Configuration ═══"
echo "  K3s Version   : $K3S_VERSION"
echo "  Server URL    : $K3S_SERVER_URL (master-01 pour jonction)"
echo "  Token         : ${K3S_TOKEN:0:30}..."
echo "  Workers       : ${WORKER_NODES[*]}"
echo ""

# Récupérer les IPs privées depuis servers.tsv
declare -A WORKER_IPS
for node in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -z "$ip" ]; then
        echo -e "$KO IP privée introuvable pour $node dans servers.tsv"
        exit 1
    fi
    WORKER_IPS[$node]=$ip
    echo "  $node : $ip"
done

echo ""
echo "NOTE : Les volumes Hetzner seront montés sur /var/lib/containerd"
echo "       Workers rejoignent via master-01 (non via LBs)"
echo ""
read -p "Continuer la jonction des workers ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Fonction pour joindre un worker
join_worker() {
    local node="$1"
    local ip="$2"
    local log_file="$LOG_DIR/${node}.log"
    
    echo ""
    echo "═══ Installation $node ($ip) ═══"
    echo ""
    echo "  Log : $log_file"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$ip" "$K3S_SERVER_URL" "$K3S_TOKEN" "$K3S_VERSION" <<'REMOTE_WORKER' | tee "$log_file"
set -u
set -o pipefail

IP_PRIVEE="$1"
SERVER_URL="$2"
TOKEN="$3"
K3S_VER="$4"

echo "[$(date '+%F %T')] Début installation K3s worker"
echo "[$(date '+%F %T')] IP privée Hetzner : $IP_PRIVEE"
echo "[$(date '+%F %T')] Server URL : $SERVER_URL"

# Créer les répertoires
mkdir -p /opt/keybuzz/k3s/{status,config,logs}

# Ouvrir les ports K3s dans UFW (SANS reset)
echo "[$(date '+%F %T')] Configuration UFW..."
if command -v ufw &>/dev/null; then
    # Kubelet
    ufw allow from 10.0.0.0/16 to any port 10250 proto tcp comment 'K3s Kubelet' 2>/dev/null || true
    # Flannel VXLAN
    ufw allow from 10.0.0.0/16 to any port 8472 proto udp comment 'K3s Flannel VXLAN' 2>/dev/null || true
    # NodePort range (si nécessaire plus tard)
    # ufw allow from 10.0.0.0/16 to any port 30000:32767 proto tcp comment 'K3s NodePort' 2>/dev/null || true
    echo "[$(date '+%F %T')] UFW : règles K3s ajoutées"
else
    echo "[$(date '+%F %T')] UFW non installé, skip"
fi

# Désactiver swap (requis par K8s)
echo "[$(date '+%F %T')] Désactivation swap..."
swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab 2>/dev/null || true

# Gérer le volume Hetzner pour containerd
echo "[$(date '+%F %T')] Gestion du volume pour /var/lib/containerd..."
CONTAINERD_DIR="/var/lib/containerd"

if ! mountpoint -q "$CONTAINERD_DIR"; then
    echo "[$(date '+%F %T')] Volume non monté, recherche d'un device disponible..."
    
    # Chercher un volume non monté
    DEVICE=""
    for candidate in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
        [ -e "$candidate" ] || continue
        real_dev=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        
        # Vérifier si déjà monté
        if mount | grep -q " $real_dev "; then
            continue
        fi
        
        DEVICE="$real_dev"
        break
    done
    
    if [ -z "$DEVICE" ]; then
        echo "[$(date '+%F %T')] WARN : Aucun volume disponible, utilisation du disque système"
    else
        echo "[$(date '+%F %T')] Device trouvé : $DEVICE"
        
        # Vérifier si déjà formaté en XFS
        if ! blkid "$DEVICE" 2>/dev/null | grep -q "TYPE=\"xfs\""; then
            echo "[$(date '+%F %T')] Formatage en XFS..."
            mkfs.xfs -f "$DEVICE" >/dev/null 2>&1
        fi
        
        # Monter le volume
        mkdir -p "$CONTAINERD_DIR"
        mount "$DEVICE" "$CONTAINERD_DIR"
        
        # Ajouter à fstab par UUID
        UUID=$(blkid -s UUID -o value "$DEVICE")
        if [ -n "$UUID" ]; then
            if ! grep -q "$CONTAINERD_DIR" /etc/fstab; then
                echo "UUID=$UUID $CONTAINERD_DIR xfs defaults,nofail 0 2" >> /etc/fstab
                echo "[$(date '+%F %T')] Volume ajouté à fstab"
            fi
        fi
        
        # Supprimer lost+found (si existe)
        [ -d "$CONTAINERD_DIR/lost+found" ] && rm -rf "$CONTAINERD_DIR/lost+found"
        
        echo "[$(date '+%F %T')] Volume monté sur $CONTAINERD_DIR"
    fi
else
    echo "[$(date '+%F %T')] Volume déjà monté sur $CONTAINERD_DIR"
fi

# Installer K3s en mode agent (worker)
echo "[$(date '+%F %T')] Installation K3s agent..."

curl -sfL https://get.k3s.io | K3S_TOKEN="$TOKEN" INSTALL_K3S_VERSION="$K3S_VER" sh -s - agent \
  --server $SERVER_URL \
  --node-ip $IP_PRIVEE \
  --flannel-iface eth0

# Attendre que K3s agent soit actif
echo "[$(date '+%F %T')] Attente démarrage K3s agent..."
for i in {1..60}; do
    if systemctl is-active --quiet k3s-agent; then
        echo "[$(date '+%F %T')] K3s agent actif"
        break
    fi
    sleep 2
done

if ! systemctl is-active --quiet k3s-agent; then
    echo "[$(date '+%F %T')] ERREUR : K3s agent n'a pas démarré"
    journalctl -u k3s-agent --no-pager -n 50
    echo "KO" > /opt/keybuzz/k3s/status/STATE
    exit 1
fi

echo "OK" > /opt/keybuzz/k3s/status/STATE
echo "[$(date '+%F %T')] Installation worker terminée"
REMOTE_WORKER
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "  $OK $node rejoint le cluster"
        return 0
    else
        echo ""
        echo -e "  $KO Erreur lors de l'installation $node"
        echo ""
        tail -n 50 "$log_file"
        return 1
    fi
}

# Compteurs
SUCCESS_COUNT=0
FAILED_COUNT=0

# Joindre tous les workers
for node in "${WORKER_NODES[@]}"; do
    ip="${WORKER_IPS[$node]}"
    
    if join_worker "$node" "$ip"; then
        ((SUCCESS_COUNT++))
    else
        ((FAILED_COUNT++))
    fi
    
    # Pause entre chaque worker
    sleep 3
done

# ═══════════════════════════════════════════════════════════════════════════
# Vérification finale
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ VÉRIFICATION FINALE DU CLUSTER K3S HA ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 10

# Utiliser kubectl depuis master-01
echo "État des nœuds (depuis master-01) :"
echo ""
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes -o wide" 2>/dev/null || echo -e "$WARN Impossible de contacter K3s"
echo ""

# Compter les nœuds
TOTAL_NODES=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes --no-headers 2>/dev/null | wc -l" || echo "0")
READY_NODES=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes --no-headers 2>/dev/null | grep -c Ready" || echo "0")

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Résumé de la jonction :"
echo "  - Workers installés : $SUCCESS_COUNT/$((SUCCESS_COUNT + FAILED_COUNT))"
echo "  - Nœuds dans le cluster : $TOTAL_NODES (attendu : 8)"
echo "  - Nœuds Ready : $READY_NODES"
echo ""

if [ "$SUCCESS_COUNT" -eq 5 ] && [ "$READY_NODES" -ge 8 ]; then
    echo -e "$OK CLUSTER K3S HA COMPLET"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Configuration finale :"
    echo "  - 3 Masters (control-plane + etcd)"
    echo "  - 5 Workers (agents)"
    echo "  - Total : 8 nœuds Ready"
    echo ""
    echo "Commandes utiles :"
    echo "  ssh root@$IP_MASTER01 kubectl get nodes"
    echo "  ssh root@$IP_MASTER01 kubectl get pods -A"
    echo ""
    echo "Prochaine étape :"
    echo "  ./k3s_bootstrap_addons.sh"
    echo ""
    
    # Mettre à jour le résumé
    cat >> "$CREDENTIALS_DIR/k3s-cluster-summary.txt" <<SUMMARY

Workers ajoutés :
  - k3s-worker-01 : ${WORKER_IPS[k3s-worker-01]}
  - k3s-worker-02 : ${WORKER_IPS[k3s-worker-02]}
  - k3s-worker-03 : ${WORKER_IPS[k3s-worker-03]}
  - k3s-worker-04 : ${WORKER_IPS[k3s-worker-04]}
  - k3s-worker-05 : ${WORKER_IPS[k3s-worker-05]}

Total : 8 nœuds (3 masters + 5 workers)
État : COMPLET ET OPÉRATIONNEL
SUMMARY
    
    exit 0
elif [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "$WARN Certains workers n'ont pas pu rejoindre le cluster"
    echo ""
    echo "Vérifiez les logs :"
    for node in "${WORKER_NODES[@]}"; do
        echo "  tail -n 50 $LOG_DIR/${node}.log"
    done
    echo ""
    exit 1
else
    echo -e "$WARN Attendre que les nœuds deviennent Ready..."
    echo ""
    echo "Vérification dans 30 secondes :"
    echo "  ssh root@$IP_MASTER01 kubectl get nodes"
    echo ""
    exit 0
fi
