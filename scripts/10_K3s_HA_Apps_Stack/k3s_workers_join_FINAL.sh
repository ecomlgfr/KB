#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                   K3S WORKERS JOIN (5 workers)                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

BASE_DIR="/opt/keybuzz-installer"
INVENTORY="${BASE_DIR}/inventory/servers.tsv"
CREDS_DIR="${BASE_DIR}/credentials"
LOGS_DIR="${BASE_DIR}/logs"
LOGFILE="${LOGS_DIR}/k3s_workers_join.log"

mkdir -p "$LOGS_DIR"

exec > >(tee -a "$LOGFILE") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Début ajout workers K3s"

# Vérification token
TOKEN_FILE="${CREDS_DIR}/k3s_token.txt"
if [[ ! -f "$TOKEN_FILE" ]]; then
    echo -e "$KO Token K3s introuvable : $TOKEN_FILE"
    echo -e "Exécuter d'abord k3s_ha_install.sh"
    exit 1
fi

K3S_TOKEN=$(cat "$TOKEN_FILE")
LB_API="10.0.0.5"

echo "Token K3s : ${K3S_TOKEN:0:20}..."
echo "API Server : https://$LB_API:6443"

# Liste des workers
WORKERS=("k3s-worker-01" "k3s-worker-02" "k3s-worker-03" "k3s-worker-04" "k3s-worker-05")

for WORKER in "${WORKERS[@]}"; do
    echo ""
    echo "═══ Installation $WORKER ═══"
    
    WORKER_IP=$(awk -F'\t' -v w="$WORKER" '$2==w{print $3}' "$INVENTORY")
    
    if [[ -z "$WORKER_IP" ]]; then
        echo -e "$KO IP introuvable pour $WORKER dans servers.tsv"
        continue
    fi
    
    echo "Worker : $WORKER ($WORKER_IP)"
    
    # CRITIQUE : Passer l'IP privée depuis servers.tsv comme argument
    ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "bash -s" "$WORKER_IP" "$LB_API" "$K3S_TOKEN" <<'EOS'
set -u
set -o pipefail

# CRITIQUE : Récupérer l'IP privée depuis les arguments (passée depuis servers.tsv)
IP_PRIVEE="$1"
LB_API="$2"
K3S_TOKEN="$3"

SERVICE="k3s"
BASE="/opt/keybuzz/${SERVICE}"
LOGS="${BASE}/logs"
ST="${BASE}/status"
mkdir -p "$LOGS" "$ST"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installation worker"
echo "IP privée utilisée : $IP_PRIVEE"

# Nettoyage si install précédente
if command -v k3s-agent &>/dev/null; then
    /usr/local/bin/k3s-killall.sh 2>/dev/null || true
    /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════
# UFW : AJOUT RÈGLES UNIQUEMENT (pas de reset/reload)
# CRITIQUE : UFW est déjà configuré, on ajoute juste les règles K3s workers
# ═══════════════════════════════════════════════════════════════

add_ufw_rule() {
    local RULE="$1"
    local COMMENT="$2"
    
    # Vérifier si la règle existe déjà
    if ! ufw status numbered | grep -q "$COMMENT"; then
        ufw allow $RULE comment "$COMMENT" 2>/dev/null || true
    fi
}

# Workers ont besoin de moins de ports que les masters
add_ufw_rule "from 10.0.0.0/16 to any port 10250 proto tcp" "K3s kubelet"
add_ufw_rule "from 10.0.0.0/16 to any port 8472 proto udp" "K3s VXLAN"
add_ufw_rule "from 10.0.0.0/16 to any port 51820 proto udp" "K3s Flannel WireGuard"

# PAS de ufw reload/enable pour éviter de couper SSH
echo "Règles UFW K3s workers ajoutées (sans interruption)"

# Vérification volume containerd
CONTAINERD_DATA="/var/lib/containerd"
if [[ ! -d "$CONTAINERD_DATA" ]]; then
    mkdir -p "$CONTAINERD_DATA"
fi

# Vérifier si volume monté
if ! mountpoint -q "$CONTAINERD_DATA"; then
    echo "WARN : $CONTAINERD_DATA non monté sur volume dédié"
    # Le volume devrait être déjà monté selon specs (XFS)
    # On continue quand même pour ne pas bloquer
fi

# Vérifier espace disponible
AVAIL=$(df -h "$CONTAINERD_DATA" | awk 'NR==2{print $4}')
echo "Espace disponible containerd : $AVAIL"

# Installation K3s agent
echo "Installation K3s agent (join via ${LB_API}:6443 avec node-ip: $IP_PRIVEE)..."
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - agent \
  --server "https://${LB_API}:6443" \
  --node-ip "$IP_PRIVEE"

echo "Attente démarrage k3s-agent (15s)..."
sleep 15

# Vérification
if ! systemctl is-active --quiet k3s-agent; then
    echo "KO : k3s-agent non démarré"
    systemctl status k3s-agent --no-pager
    journalctl -u k3s-agent -n 30 --no-pager
    echo "KO" > "$ST/STATE"
    exit 1
fi

echo "OK : worker opérationnel (node-ip: $IP_PRIVEE)"
echo "OK" > "$ST/STATE"
EOS

    if [[ $? -eq 0 ]]; then
        echo -e "$OK $WORKER ajouté au cluster"
    else
        echo -e "$KO Échec ajout $WORKER"
    fi
    
    # Attente entre chaque worker
    sleep 10
done

# Validation finale
echo ""
echo "═══ Validation cluster complet ═══"
echo "Attente propagation des nœuds (30s)..."
sleep 30

TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")

echo "Nœuds total : $TOTAL_NODES"
echo "Nœuds Ready : $READY_NODES"

if [[ "$TOTAL_NODES" -ne 8 ]]; then
    echo -e "$KO Cluster incomplet : $TOTAL_NODES/8 nœuds (attendu : 3 masters + 5 workers)"
    kubectl get nodes -o wide
    exit 1
fi

if [[ "$READY_NODES" -lt 8 ]]; then
    echo -e "$KO Certains nœuds ne sont pas Ready : $READY_NODES/8"
    echo "Cela peut prendre quelques minutes, vérifier avec : kubectl get nodes -w"
    kubectl get nodes -o wide
fi

echo -e "$OK Cluster K3s complet : 3 masters + 5 workers"
kubectl get nodes -o wide

# STATE global
mkdir -p /opt/keybuzz/k3s/status
echo "OK" > /opt/keybuzz/k3s/status/STATE

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ajout workers K3s terminé"
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "                      RÉSUMÉ CLUSTER K3S                           "
echo "══════════════════════════════════════════════════════════════════"
echo "Masters : 3 Ready"
echo "Workers : 5 (en cours de Ready si < 5 min depuis install)"
echo "Total   : $READY_NODES/$TOTAL_NODES nœuds Ready"
echo "API     : https://$LB_API:6443"
echo "══════════════════════════════════════════════════════════════════"

# Afficher les 50 dernières lignes du log
echo ""
echo "═══ Dernières lignes du log ═══"
tail -n 50 "$LOGFILE"
