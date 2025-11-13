#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              K3S HA CLUSTER - Installation 3 Masters              ║"
echo "║        (etcd intégré, LB API Hetzner 10.0.0.5 / 10.0.0.6)         ║"
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

MASTER_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)
LB_API_LB1="10.0.0.5"
LB_API_LB2="10.0.0.6"
K3S_VERSION="${K3S_VERSION:-v1.28.5+k3s1}"

echo ""
echo "═══ Configuration ═══"
echo "  LB API (primaire) : $LB_API_LB1 (lb-keybuzz-1)"
echo "  LB API (secondaire) : $LB_API_LB2 (lb-keybuzz-2)"
echo "  K3s Version       : $K3S_VERSION"
echo "  Masters           : ${MASTER_NODES[*]}"
echo ""

# Récupérer les IPs privées depuis servers.tsv
declare -A MASTER_IPS
for node in "${MASTER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -z "$ip" ]; then
        echo -e "$KO IP privée introuvable pour $node dans servers.tsv"
        exit 1
    fi
    MASTER_IPS[$node]=$ip
    echo "  $node : $ip"
done

echo ""
echo "NOTE : Masters 2 et 3 rejoindront via master-01 (${MASTER_IPS[k3s-master-01]})"
echo "       Les 2 LBs seront utilisés pour l'accès kubectl (haute disponibilité)"
echo ""
read -p "Continuer l'installation ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Installation du premier master (cluster-init)
# ═══════════════════════════════════════════════════════════════════════════

MASTER01="${MASTER_NODES[0]}"
IP_MASTER01="${MASTER_IPS[$MASTER01]}"
LOG_FILE="$LOG_DIR/k3s_master01.log"

echo ""
echo "═══ ÉTAPE 1/3 : Installation master-01 ($IP_MASTER01) ═══"
echo ""
echo "  Log : $LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash -s "$IP_MASTER01" "$LB_API_LB1" "$LB_API_LB2" "$K3S_VERSION" <<'REMOTE_MASTER01' | tee "$LOG_FILE"
set -u
set -o pipefail

IP_PRIVEE="$1"
LB1="$2"
LB2="$3"
K3S_VER="$4"

echo "[$(date '+%F %T')] Début installation K3s master-01"
echo "[$(date '+%F %T')] IP privée Hetzner : $IP_PRIVEE"
echo "[$(date '+%F %T')] Load Balancers    : $LB1 / $LB2"

# Créer les répertoires
mkdir -p /opt/keybuzz/k3s/{status,config,logs}

# Ouvrir les ports K3s dans UFW (SANS reset)
echo "[$(date '+%F %T')] Configuration UFW..."
if command -v ufw &>/dev/null; then
    # K3s API server
    ufw allow from 10.0.0.0/16 to any port 6443 proto tcp comment 'K3s API' 2>/dev/null || true
    # Kubelet
    ufw allow from 10.0.0.0/16 to any port 10250 proto tcp comment 'Kubelet' 2>/dev/null || true
    # Flannel VXLAN
    ufw allow from 10.0.0.0/16 to any port 8472 proto udp comment 'Flannel VXLAN' 2>/dev/null || true
    # etcd (master to master)
    ufw allow from 10.0.0.100 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    ufw allow from 10.0.0.101 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    ufw allow from 10.0.0.102 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    echo "[$(date '+%F %T')] UFW : règles K3s ajoutées"
else
    echo "[$(date '+%F %T')] UFW non installé, skip"
fi

# Désactiver swap (requis par K8s)
echo "[$(date '+%F %T')] Désactivation swap..."
swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab 2>/dev/null || true

# Installer K3s master 01 avec --cluster-init (etcd intégré)
echo "[$(date '+%F %T')] Installation K3s (cluster-init)..."

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VER" sh -s - server \
  --cluster-init \
  --write-kubeconfig-mode 644 \
  --tls-san $LB1 \
  --tls-san $LB2 \
  --tls-san $IP_PRIVEE \
  --node-ip $IP_PRIVEE \
  --advertise-address $IP_PRIVEE \
  --flannel-iface eth0 \
  --flannel-backend vxlan \
  --disable traefik \
  --disable servicelb

# Attendre que K3s soit prêt
echo "[$(date '+%F %T')] Attente démarrage K3s..."
for i in {1..60}; do
    if systemctl is-active --quiet k3s; then
        echo "[$(date '+%F %T')] K3s actif"
        break
    fi
    sleep 2
done

if ! systemctl is-active --quiet k3s; then
    echo "[$(date '+%F %T')] ERREUR : K3s n'a pas démarré"
    journalctl -u k3s --no-pager -n 50
    echo "KO" > /opt/keybuzz/k3s/status/STATE
    exit 1
fi

# Vérifier que le nœud est Ready
echo "[$(date '+%F %T')] Vérification du nœud..."
for i in {1..60}; do
    if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
        echo "[$(date '+%F %T')] Nœud Ready"
        break
    fi
    sleep 2
done

# Récupérer le token pour les autres masters
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
echo "[$(date '+%F %T')] Token récupéré : ${K3S_TOKEN:0:20}..."

# Sauvegarder le token
echo "$K3S_TOKEN" > /opt/keybuzz/k3s/config/node-token
chmod 600 /opt/keybuzz/k3s/config/node-token

# Sauvegarder le kubeconfig
cp /etc/rancher/k3s/k3s.yaml /opt/keybuzz/k3s/config/k3s.yaml
chmod 600 /opt/keybuzz/k3s/config/k3s.yaml

echo "OK" > /opt/keybuzz/k3s/status/STATE
echo "[$(date '+%F %T')] Installation master-01 terminée"
REMOTE_MASTER01

# Vérifier le résultat
if [ $? -eq 0 ]; then
    echo ""
    echo -e "  $OK Master-01 installé avec succès"
else
    echo ""
    echo -e "  $KO Erreur lors de l'installation master-01"
    echo ""
    tail -n 50 "$LOG_FILE"
    exit 1
fi

# Récupérer le token depuis master-01
echo ""
echo "  Récupération du token K3s..."
K3S_TOKEN=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null)

if [ -z "$K3S_TOKEN" ]; then
    echo -e "$KO Impossible de récupérer le token"
    exit 1
fi

echo "  Token : ${K3S_TOKEN:0:30}..."
echo "$K3S_TOKEN" > "$CREDENTIALS_DIR/k3s-token.txt"
chmod 600 "$CREDENTIALS_DIR/k3s-token.txt"

# Récupérer le kubeconfig
scp -o StrictHostKeyChecking=no root@"$IP_MASTER01":/etc/rancher/k3s/k3s.yaml "$CREDENTIALS_DIR/k3s.yaml" >/dev/null 2>&1
if [ -f "$CREDENTIALS_DIR/k3s.yaml" ]; then
    # Remplacer 127.0.0.1 par le LB primaire (LB1)
    sed -i "s/127.0.0.1:6443/$LB_API_LB1:6443/g" "$CREDENTIALS_DIR/k3s.yaml"
    chmod 600 "$CREDENTIALS_DIR/k3s.yaml"
    echo -e "  $OK kubeconfig récupéré et configuré pour $LB_API_LB1:6443"
fi

sleep 5

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Joindre master-02
# ═══════════════════════════════════════════════════════════════════════════

MASTER02="${MASTER_NODES[1]}"
IP_MASTER02="${MASTER_IPS[$MASTER02]}"
LOG_FILE="$LOG_DIR/k3s_master02.log"

echo ""
echo "═══ ÉTAPE 2/3 : Installation master-02 ($IP_MASTER02) ═══"
echo ""
echo "  Log : $LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER02" bash -s "$IP_MASTER02" "$IP_MASTER01" "$LB_API_LB1" "$LB_API_LB2" "$K3S_TOKEN" "$K3S_VERSION" <<'REMOTE_MASTER02' | tee "$LOG_FILE"
set -u
set -o pipefail

IP_PRIVEE="$1"
IP_MASTER01="$2"
LB1="$3"
LB2="$4"
TOKEN="$5"
K3S_VER="$6"

echo "[$(date '+%F %T')] Début installation K3s master-02"
echo "[$(date '+%F %T')] IP privée Hetzner : $IP_PRIVEE"
echo "[$(date '+%F %T')] Connexion via master-01 : $IP_MASTER01:6443"
echo "[$(date '+%F %T')] Load Balancers    : $LB1 / $LB2"

mkdir -p /opt/keybuzz/k3s/{status,config,logs}

# Ouvrir les ports UFW (SANS reset)
echo "[$(date '+%F %T')] Configuration UFW..."
if command -v ufw &>/dev/null; then
    ufw allow from 10.0.0.0/16 to any port 6443 proto tcp comment 'K3s API' 2>/dev/null || true
    ufw allow from 10.0.0.0/16 to any port 10250 proto tcp comment 'Kubelet' 2>/dev/null || true
    ufw allow from 10.0.0.0/16 to any port 8472 proto udp comment 'Flannel VXLAN' 2>/dev/null || true
    ufw allow from 10.0.0.100 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    ufw allow from 10.0.0.101 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    ufw allow from 10.0.0.102 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    echo "[$(date '+%F %T')] UFW : règles K3s ajoutées"
fi

swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab 2>/dev/null || true

# Joindre le cluster via master-01 DIRECTEMENT (pas le LB)
echo "[$(date '+%F %T')] Jonction au cluster K3s..."

curl -sfL https://get.k3s.io | K3S_TOKEN="$TOKEN" INSTALL_K3S_VERSION="$K3S_VER" sh -s - server \
  --server https://$IP_MASTER01:6443 \
  --write-kubeconfig-mode 644 \
  --tls-san $LB1 \
  --tls-san $LB2 \
  --tls-san $IP_PRIVEE \
  --node-ip $IP_PRIVEE \
  --advertise-address $IP_PRIVEE \
  --flannel-iface eth0 \
  --flannel-backend vxlan \
  --disable traefik \
  --disable servicelb

echo "[$(date '+%F %T')] Attente démarrage K3s..."
for i in {1..60}; do
    if systemctl is-active --quiet k3s; then
        echo "[$(date '+%F %T')] K3s actif"
        break
    fi
    sleep 2
done

if ! systemctl is-active --quiet k3s; then
    echo "[$(date '+%F %T')] ERREUR : K3s n'a pas démarré"
    journalctl -u k3s --no-pager -n 50
    echo "KO" > /opt/keybuzz/k3s/status/STATE
    exit 1
fi

# Vérifier que le nœud est Ready
for i in {1..60}; do
    if kubectl get nodes 2>/dev/null | grep -q "Ready.*master"; then
        echo "[$(date '+%F %T')] Nœud Ready"
        break
    fi
    sleep 2
done

echo "OK" > /opt/keybuzz/k3s/status/STATE
echo "[$(date '+%F %T')] Installation master-02 terminée"
REMOTE_MASTER02

if [ $? -eq 0 ]; then
    echo ""
    echo -e "  $OK Master-02 rejoint le cluster"
else
    echo ""
    echo -e "  $KO Erreur lors de l'installation master-02"
    echo ""
    tail -n 50 "$LOG_FILE"
    exit 1
fi

sleep 5

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Joindre master-03
# ═══════════════════════════════════════════════════════════════════════════

MASTER03="${MASTER_NODES[2]}"
IP_MASTER03="${MASTER_IPS[$MASTER03]}"
LOG_FILE="$LOG_DIR/k3s_master03.log"

echo ""
echo "═══ ÉTAPE 3/3 : Installation master-03 ($IP_MASTER03) ═══"
echo ""
echo "  Log : $LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER03" bash -s "$IP_MASTER03" "$IP_MASTER01" "$LB_API_LB1" "$LB_API_LB2" "$K3S_TOKEN" "$K3S_VERSION" <<'REMOTE_MASTER03' | tee "$LOG_FILE"
set -u
set -o pipefail

IP_PRIVEE="$1"
IP_MASTER01="$2"
LB1="$3"
LB2="$4"
TOKEN="$5"
K3S_VER="$6"

echo "[$(date '+%F %T')] Début installation K3s master-03"
echo "[$(date '+%F %T')] IP privée Hetzner : $IP_PRIVEE"
echo "[$(date '+%F %T')] Connexion via master-01 : $IP_MASTER01:6443"
echo "[$(date '+%F %T')] Load Balancers    : $LB1 / $LB2"

mkdir -p /opt/keybuzz/k3s/{status,config,logs}

# Ouvrir les ports UFW (SANS reset)
echo "[$(date '+%F %T')] Configuration UFW..."
if command -v ufw &>/dev/null; then
    ufw allow from 10.0.0.0/16 to any port 6443 proto tcp comment 'K3s API' 2>/dev/null || true
    ufw allow from 10.0.0.0/16 to any port 10250 proto tcp comment 'Kubelet' 2>/dev/null || true
    ufw allow from 10.0.0.0/16 to any port 8472 proto udp comment 'Flannel VXLAN' 2>/dev/null || true
    ufw allow from 10.0.0.100 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    ufw allow from 10.0.0.101 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    ufw allow from 10.0.0.102 to any port 2379:2380 proto tcp comment 'etcd' 2>/dev/null || true
    echo "[$(date '+%F %T')] UFW : règles K3s ajoutées"
fi

swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab 2>/dev/null || true

# Joindre le cluster via master-01 DIRECTEMENT (pas le LB)
echo "[$(date '+%F %T')] Jonction au cluster K3s..."

curl -sfL https://get.k3s.io | K3S_TOKEN="$TOKEN" INSTALL_K3S_VERSION="$K3S_VER" sh -s - server \
  --server https://$IP_MASTER01:6443 \
  --write-kubeconfig-mode 644 \
  --tls-san $LB1 \
  --tls-san $LB2 \
  --tls-san $IP_PRIVEE \
  --node-ip $IP_PRIVEE \
  --advertise-address $IP_PRIVEE \
  --flannel-iface eth0 \
  --flannel-backend vxlan \
  --disable traefik \
  --disable servicelb

echo "[$(date '+%F %T')] Attente démarrage K3s..."
for i in {1..60}; do
    if systemctl is-active --quiet k3s; then
        echo "[$(date '+%F %T')] K3s actif"
        break
    fi
    sleep 2
done

if ! systemctl is-active --quiet k3s; then
    echo "[$(date '+%F %T')] ERREUR : K3s n'a pas démarré"
    journalctl -u k3s --no-pager -n 50
    echo "KO" > /opt/keybuzz/k3s/status/STATE
    exit 1
fi

# Vérifier que le nœud est Ready
for i in {1..60}; do
    if kubectl get nodes 2>/dev/null | grep -q "Ready.*master"; then
        echo "[$(date '+%F %T')] Nœud Ready"
        break
    fi
    sleep 2
done

echo "OK" > /opt/keybuzz/k3s/status/STATE
echo "[$(date '+%F %T')] Installation master-03 terminée"
REMOTE_MASTER03

if [ $? -eq 0 ]; then
    echo ""
    echo -e "  $OK Master-03 rejoint le cluster"
else
    echo ""
    echo -e "  $KO Erreur lors de l'installation master-03"
    echo ""
    tail -n 50 "$LOG_FILE"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : Vérification finale du cluster
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ VÉRIFICATION FINALE DU CLUSTER K3S HA ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 10

# Installer kubectl localement si nécessaire
if ! command -v kubectl &>/dev/null; then
    echo "Installation de kubectl..."
    curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
fi

# Configurer KUBECONFIG
export KUBECONFIG="$CREDENTIALS_DIR/k3s.yaml"

echo "État des nœuds :"
echo ""
kubectl get nodes -o wide 2>/dev/null || echo -e "$WARN Impossible de contacter l'API K3s via LB"

# Si le LB ne fonctionne pas, essayer en direct
if ! kubectl get nodes &>/dev/null; then
    echo ""
    echo -e "$WARN Les LBs ne répondent pas, test en direct sur master-01..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes" 2>/dev/null
fi

echo ""

# Vérifier etcd
echo "État etcd (depuis master-01) :"
echo ""
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes -o wide | grep control-plane" 2>/dev/null || true
echo ""

# Compter les masters Ready (depuis master-01 car LBs peuvent ne pas être configurés)
READY_COUNT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes 2>/dev/null" | grep -c "Ready.*control-plane" || echo "0")

if [ "$READY_COUNT" -eq 3 ]; then
    echo -e "$OK Les 3 masters sont Ready"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$OK CLUSTER K3S HA OPÉRATIONNEL"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Configuration :"
    echo "  - Masters    : ${MASTER_IPS[k3s-master-01]}, ${MASTER_IPS[k3s-master-02]}, ${MASTER_IPS[k3s-master-03]}"
    echo "  - Kubeconfig : $CREDENTIALS_DIR/k3s.yaml"
    echo "  - Token      : $CREDENTIALS_DIR/k3s-token.txt"
    echo ""
    echo "⚠️  IMPORTANT : Configurez les Load Balancers Hetzner (API K3s) :"
    echo ""
    echo "  lb-keybuzz-1 (primaire) :"
    echo "     IP       : $LB_API_LB1"
    echo "     Backends : ${MASTER_IPS[k3s-master-01]}:6443, ${MASTER_IPS[k3s-master-02]}:6443, ${MASTER_IPS[k3s-master-03]}:6443"
    echo "     Protocol : TCP"
    echo "     Health   : TCP 6443"
    echo ""
    echo "  lb-keybuzz-2 (secondaire) :"
    echo "     IP       : $LB_API_LB2"
    echo "     Backends : ${MASTER_IPS[k3s-master-01]}:6443, ${MASTER_IPS[k3s-master-02]}:6443, ${MASTER_IPS[k3s-master-03]}:6443"
    echo "     Protocol : TCP"
    echo "     Health   : TCP 6443"
    echo ""
    echo "Commandes utiles :"
    echo "  # Via master-01 directement"
    echo "  ssh root@$IP_MASTER01 kubectl get nodes"
    echo ""
    echo "  # Via LB primaire (après config Hetzner)"
    echo "  export KUBECONFIG=$CREDENTIALS_DIR/k3s.yaml"
    echo "  kubectl get nodes"
    echo ""
    echo "  # Via LB secondaire (test)"
    echo "  sed -i 's/$LB_API_LB1/$LB_API_LB2/g' $CREDENTIALS_DIR/k3s.yaml"
    echo "  kubectl get nodes"
    echo ""
    echo "Prochaine étape :"
    echo "  ./k3s_workers_join.sh"
    echo ""
    
    # Créer un résumé
    cat > "$CREDENTIALS_DIR/k3s-cluster-summary.txt" <<SUMMARY
K3S HA Cluster - Installation réussie
======================================
Date : $(date)

Masters :
  - k3s-master-01 : ${MASTER_IPS[k3s-master-01]}
  - k3s-master-02 : ${MASTER_IPS[k3s-master-02]}
  - k3s-master-03 : ${MASTER_IPS[k3s-master-03]}

Load Balancers API K3s (haute disponibilité) :
  - lb-keybuzz-1 (primaire)   : https://$LB_API_LB1:6443
  - lb-keybuzz-2 (secondaire) : https://$LB_API_LB2:6443

⚠️  À FAIRE : Configurer les 2 Load Balancers Hetzner avec ces backends

Configuration :
  - etcd intégré (3 nœuds)
  - Flannel VXLAN
  - Traefik désactivé
  - ServiceLB désactivé
  - Certificats TLS incluant les 2 LBs + IPs privées des masters

Fichiers :
  - Kubeconfig : $CREDENTIALS_DIR/k3s.yaml (pointe vers LB1 par défaut)
  - Token      : $CREDENTIALS_DIR/k3s-token.txt

État : OPÉRATIONNEL (masters uniquement)
SUMMARY
    
    exit 0
else
    echo -e "$KO Seulement $READY_COUNT/3 masters Ready"
    echo ""
    echo "Debug :"
    echo "  ssh root@$IP_MASTER01 'kubectl get nodes'"
    echo "  ssh root@$IP_MASTER01 'journalctl -u k3s -n 100'"
    echo ""
    exit 1
fi
