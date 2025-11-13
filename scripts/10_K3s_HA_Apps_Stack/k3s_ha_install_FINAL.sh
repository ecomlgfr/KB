#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              K3S HA MASTERS INSTALL (etcd intégré)                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

BASE_DIR="/opt/keybuzz-installer"
INVENTORY="${BASE_DIR}/inventory/servers.tsv"
CREDS_DIR="${BASE_DIR}/credentials"
LOGS_DIR="${BASE_DIR}/logs"
LOGFILE="${LOGS_DIR}/k3s_ha_install.log"

mkdir -p "$LOGS_DIR" "$CREDS_DIR"

exec > >(tee -a "$LOGFILE") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Début installation K3s HA Masters"

# Vérification servers.tsv
if [[ ! -f "$INVENTORY" ]]; then
    echo -e "$KO servers.tsv introuvable : $INVENTORY"
    exit 1
fi

# Récupération IPs masters
MASTER_01_IP=$(awk -F'\t' '$2=="k3s-master-01"{print $3}' "$INVENTORY")
MASTER_02_IP=$(awk -F'\t' '$2=="k3s-master-02"{print $3}' "$INVENTORY")
MASTER_03_IP=$(awk -F'\t' '$2=="k3s-master-03"{print $3}' "$INVENTORY")

if [[ -z "$MASTER_01_IP" || -z "$MASTER_02_IP" || -z "$MASTER_03_IP" ]]; then
    echo -e "$KO IPs masters introuvables dans servers.tsv"
    exit 1
fi

echo "Masters détectés :"
echo "  - k3s-master-01 : $MASTER_01_IP"
echo "  - k3s-master-02 : $MASTER_02_IP"
echo "  - k3s-master-03 : $MASTER_03_IP"

# LB API K3s
LB_API="10.0.0.5"
echo "LB API K3s : $LB_API:6443"

# Installation master-01 (bootstrap cluster)
echo ""
echo "═══ Installation master-01 (cluster-init) ═══"
ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "bash -s" "$MASTER_01_IP" "$LB_API" <<'EOS'
set -u
set -o pipefail

# CRITIQUE : Récupérer l'IP privée depuis les arguments (passée depuis servers.tsv)
IP_PRIVEE="$1"
LB_API="$2"

SERVICE="k3s"
BASE="/opt/keybuzz/${SERVICE}"
LOGS="${BASE}/logs"
ST="${BASE}/status"
mkdir -p "$LOGS" "$ST"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installation K3s master-01 (bootstrap)"
echo "IP privée utilisée : $IP_PRIVEE"

# Nettoyage si install précédente
if command -v k3s &>/dev/null; then
    echo "K3s déjà présent, nettoyage..."
    /usr/local/bin/k3s-killall.sh 2>/dev/null || true
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════
# UFW : AJOUT RÈGLES UNIQUEMENT (pas de reset/reload)
# CRITIQUE : UFW est déjà configuré (SSH, etc.), on ajoute juste K3s
# ═══════════════════════════════════════════════════════════════

# Fonction pour ajouter une règle UFW de manière idempotente
add_ufw_rule() {
    local RULE="$1"
    local COMMENT="$2"
    
    # Vérifier si la règle existe déjà
    if ! ufw status numbered | grep -q "$COMMENT"; then
        ufw allow $RULE comment "$COMMENT" 2>/dev/null || true
    fi
}

# Ajout règles K3s (seulement si elles n'existent pas)
add_ufw_rule "from 10.0.0.0/16 to any port 6443 proto tcp" "K3s API"
add_ufw_rule "from 10.0.0.0/16 to any port 10250 proto tcp" "K3s kubelet"
add_ufw_rule "from 10.0.0.0/16 to any port 8472 proto udp" "K3s VXLAN"
add_ufw_rule "from 10.0.0.0/16 to any port 51820 proto udp" "K3s Flannel WireGuard"
add_ufw_rule "from 10.0.0.0/16 to any port 2379:2380 proto tcp" "K3s etcd"

# PAS de ufw reload/enable pour éviter de couper SSH
echo "Règles UFW K3s ajoutées (sans interruption)"

# Installation K3s master
echo "Installation K3s avec cluster-init..."
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --write-kubeconfig-mode 644 \
  --tls-san "$LB_API" \
  --tls-san "$IP_PRIVEE" \
  --node-ip "$IP_PRIVEE" \
  --flannel-backend vxlan \
  --disable traefik \
  --disable servicelb

# Attente démarrage
echo "Attente démarrage K3s (15s)..."
sleep 15

# Vérification
if ! systemctl is-active --quiet k3s; then
    echo "KO : K3s non démarré"
    journalctl -u k3s -n 30 --no-pager
    echo "KO" > "$ST/STATE"
    exit 1
fi

# Export token
TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
echo "$TOKEN" > /tmp/k3s_token.txt
chmod 600 /tmp/k3s_token.txt

# Test kubectl
if ! /usr/local/bin/kubectl get nodes 2>/dev/null; then
    echo "KO : kubectl get nodes échoue"
    echo "KO" > "$ST/STATE"
    exit 1
fi

echo "OK : master-01 opérationnel (node-ip: $IP_PRIVEE)"
/usr/local/bin/kubectl get nodes
echo "OK" > "$ST/STATE"
EOS

if [[ $? -ne 0 ]]; then
    echo -e "$KO Échec installation master-01"
    exit 1
fi

echo -e "$OK master-01 installé"

# Récupération token
K3S_TOKEN=$(ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "cat /tmp/k3s_token.txt")
if [[ -z "$K3S_TOKEN" ]]; then
    echo -e "$KO Token K3s non récupéré"
    exit 1
fi

echo "Token K3s récupéré : ${K3S_TOKEN:0:20}..."
echo "$K3S_TOKEN" > "${CREDS_DIR}/k3s_token.txt"
chmod 600 "${CREDS_DIR}/k3s_token.txt"

# Attente stabilisation master-01 (CRITIQUE)
echo ""
echo "Attente stabilisation master-01 (60s)..."
sleep 60

# Installation master-02
echo ""
echo "═══ Installation master-02 ═══"
ssh -o StrictHostKeyChecking=no root@"$MASTER_02_IP" "bash -s" "$MASTER_02_IP" "$LB_API" "$K3S_TOKEN" <<'EOS'
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installation K3s master-02"
echo "IP privée utilisée : $IP_PRIVEE"

# Nettoyage si install précédente
if command -v k3s &>/dev/null; then
    /usr/local/bin/k3s-killall.sh 2>/dev/null || true
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════
# UFW : AJOUT RÈGLES UNIQUEMENT
# ═══════════════════════════════════════════════════════════════

add_ufw_rule() {
    local RULE="$1"
    local COMMENT="$2"
    if ! ufw status numbered | grep -q "$COMMENT"; then
        ufw allow $RULE comment "$COMMENT" 2>/dev/null || true
    fi
}

add_ufw_rule "from 10.0.0.0/16 to any port 6443 proto tcp" "K3s API"
add_ufw_rule "from 10.0.0.0/16 to any port 10250 proto tcp" "K3s kubelet"
add_ufw_rule "from 10.0.0.0/16 to any port 8472 proto udp" "K3s VXLAN"
add_ufw_rule "from 10.0.0.0/16 to any port 51820 proto udp" "K3s Flannel WireGuard"
add_ufw_rule "from 10.0.0.0/16 to any port 2379:2380 proto tcp" "K3s etcd"

echo "Règles UFW K3s ajoutées (sans interruption)"

# Installation
echo "Installation K3s (join via LB ${LB_API}:6443)..."
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --server "https://${LB_API}:6443" \
  --node-ip "$IP_PRIVEE" \
  --flannel-backend vxlan \
  --disable traefik \
  --disable servicelb

echo "Attente démarrage K3s (30s)..."
sleep 30

if ! systemctl is-active --quiet k3s; then
    echo "KO : K3s non démarré"
    journalctl -u k3s -n 30 --no-pager
    echo "KO" > "$ST/STATE"
    exit 1
fi

echo "OK : master-02 opérationnel (node-ip: $IP_PRIVEE)"
echo "OK" > "$ST/STATE"
EOS

if [[ $? -ne 0 ]]; then
    echo -e "$KO Échec installation master-02"
    exit 1
fi

echo -e "$OK master-02 installé"

# Attente stabilisation master-02
echo "Attente stabilisation master-02 (30s)..."
sleep 30

# Installation master-03
echo ""
echo "═══ Installation master-03 ═══"
ssh -o StrictHostKeyChecking=no root@"$MASTER_03_IP" "bash -s" "$MASTER_03_IP" "$LB_API" "$K3S_TOKEN" <<'EOS'
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installation K3s master-03"
echo "IP privée utilisée : $IP_PRIVEE"

# Nettoyage si install précédente
if command -v k3s &>/dev/null; then
    /usr/local/bin/k3s-killall.sh 2>/dev/null || true
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════
# UFW : AJOUT RÈGLES UNIQUEMENT
# ═══════════════════════════════════════════════════════════════

add_ufw_rule() {
    local RULE="$1"
    local COMMENT="$2"
    if ! ufw status numbered | grep -q "$COMMENT"; then
        ufw allow $RULE comment "$COMMENT" 2>/dev/null || true
    fi
}

add_ufw_rule "from 10.0.0.0/16 to any port 6443 proto tcp" "K3s API"
add_ufw_rule "from 10.0.0.0/16 to any port 10250 proto tcp" "K3s kubelet"
add_ufw_rule "from 10.0.0.0/16 to any port 8472 proto udp" "K3s VXLAN"
add_ufw_rule "from 10.0.0.0/16 to any port 51820 proto udp" "K3s Flannel WireGuard"
add_ufw_rule "from 10.0.0.0/16 to any port 2379:2380 proto tcp" "K3s etcd"

echo "Règles UFW K3s ajoutées (sans interruption)"

# Installation
echo "Installation K3s (join via LB ${LB_API}:6443)..."
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --server "https://${LB_API}:6443" \
  --node-ip "$IP_PRIVEE" \
  --flannel-backend vxlan \
  --disable traefik \
  --disable servicelb

echo "Attente démarrage K3s (30s)..."
sleep 30

if ! systemctl is-active --quiet k3s; then
    echo "KO : K3s non démarré"
    journalctl -u k3s -n 30 --no-pager
    echo "KO" > "$ST/STATE"
    exit 1
fi

echo "OK : master-03 opérationnel (node-ip: $IP_PRIVEE)"
echo "OK" > "$ST/STATE"
EOS

if [[ $? -ne 0 ]]; then
    echo -e "$KO Échec installation master-03"
    exit 1
fi

echo -e "$OK master-03 installé"

# Récupération kubeconfig
echo ""
echo "═══ Récupération kubeconfig ═══"
ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "cat /etc/rancher/k3s/k3s.yaml" > /tmp/k3s_kubeconfig.yaml
sed -i "s/127.0.0.1/$LB_API/g" /tmp/k3s_kubeconfig.yaml

mkdir -p ~/.kube
cp /tmp/k3s_kubeconfig.yaml ~/.kube/config
chmod 600 ~/.kube/config

# Test kubectl local
echo ""
echo "═══ Validation cluster ═══"
if ! command -v kubectl &>/dev/null; then
    echo "Installation kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
fi

sleep 10

NODES_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [[ "$NODES_COUNT" -ne 3 ]]; then
    echo -e "$KO Cluster incomplet : $NODES_COUNT/3 masters"
    kubectl get nodes -o wide
    exit 1
fi

echo -e "$OK Cluster K3s HA opérationnel (3 masters)"
kubectl get nodes -o wide

# STATE global
mkdir -p /opt/keybuzz/k3s/status
echo "OK" > /opt/keybuzz/k3s/status/STATE

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installation K3s HA Masters terminée"
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "                      RÉSUMÉ INSTALLATION                          "
echo "══════════════════════════════════════════════════════════════════"
echo "Masters K3s : 3/3 Ready"
echo "IPs privées : $MASTER_01_IP, $MASTER_02_IP, $MASTER_03_IP"
echo "API Endpoint : https://$LB_API:6443"
echo "Kubeconfig : ~/.kube/config"
echo "Token : ${CREDS_DIR}/k3s_token.txt"
echo "══════════════════════════════════════════════════════════════════"

# Afficher les 50 dernières lignes du log
echo ""
echo "═══ Dernières lignes du log ═══"
tail -n 50 "$LOGFILE"
