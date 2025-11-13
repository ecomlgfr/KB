#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         K3S_HA_INSTALL - Installation K3s Haute Disponibilité      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/k3s_ha_install_$TIMESTAMP.log"

mkdir -p "$LOG_DIR" "$CREDS_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Installation K3s HA - 3 Masters"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# IPs des masters K3s
MASTER1_IP="10.0.0.100"
MASTER2_IP="10.0.0.101"
MASTER3_IP="10.0.0.102"
LB_VIP="10.0.0.10"

echo "Configuration:"
echo "  k3s-master-01: $MASTER1_IP"
echo "  k3s-master-02: $MASTER2_IP"
echo "  k3s-master-03: $MASTER3_IP"
echo "  Load Balancer VIP: $LB_VIP:6443"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS PRÉALABLES
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier la connectivité
for host in k3s-master-01 k3s-master-02 k3s-master-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  Test SSH $host ($IP): "
    if timeout 3 ssh -o StrictHostKeyChecking=no root@"$IP" "echo 1" &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
        exit 1
    fi
done

# Générer le token K3s si absent
if [ ! -f "$CREDS_DIR/k3s.env" ]; then
    echo ""
    echo "  Génération du token K3s..."
    K3S_TOKEN=$(openssl rand -hex 32)
    K3S_AGENT_TOKEN=$(openssl rand -hex 32)
    
    cat > "$CREDS_DIR/k3s.env" <<EOF
#!/bin/bash
# K3s Credentials - GÉNÉRÉ AUTOMATIQUEMENT
# Date: $(date)
export K3S_TOKEN="$K3S_TOKEN"
export K3S_AGENT_TOKEN="$K3S_AGENT_TOKEN"
export K3S_DATASTORE_ENDPOINT="http://$MASTER1_IP:2379,http://$MASTER2_IP:2379,http://$MASTER3_IP:2379"
export K3S_LB_ENDPOINT="https://$LB_VIP:6443"
EOF
    chmod 600 "$CREDS_DIR/k3s.env"
else
    source "$CREDS_DIR/k3s.env"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: NETTOYAGE (si installation existante)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Nettoyage des installations existantes                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in k3s-master-01 k3s-master-02 k3s-master-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Nettoyage $host..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'CLEANUP'
# Arrêter K3s s'il existe
if systemctl is-active k3s &>/dev/null; then
    systemctl stop k3s
    k3s-killall.sh 2>/dev/null || true
fi

# Nettoyer les données
rm -rf /var/lib/rancher/k3s/*
rm -rf /etc/rancher/k3s/*
rm -f /usr/local/bin/k3s*

echo "    ✓ Nettoyé"
CLEANUP
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: INSTALLATION DU PREMIER MASTER (avec etcd intégré)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Installation du premier master K3s                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Installation k3s-master-01 (cluster-init)..."

ssh -o StrictHostKeyChecking=no root@"$MASTER1_IP" bash -s "$K3S_TOKEN" "$LB_VIP" <<'MASTER1_INSTALL'
K3S_TOKEN="$1"
LB_VIP="$2"

# Installer K3s avec cluster-init (etcd intégré)
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --cluster-init \
  --tls-san="$LB_VIP" \
  --tls-san="10.0.0.100" \
  --tls-san="k3s-master-01" \
  --bind-address="0.0.0.0" \
  --advertise-address="10.0.0.100" \
  --node-ip="10.0.0.100" \
  --flannel-iface="eth0" \
  --disable="traefik" \
  --disable="servicelb" \
  --write-kubeconfig-mode="644"

# Attendre que K3s soit prêt
sleep 10

# Vérifier
if kubectl get nodes &>/dev/null; then
    echo "    ✓ K3s master-01 installé"
else
    echo "    ✗ Échec installation"
    exit 1
fi
MASTER1_INSTALL

echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: INSTALLATION DES AUTRES MASTERS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Installation des autres masters K3s                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Master 2
echo "  Installation k3s-master-02..."
ssh -o StrictHostKeyChecking=no root@"$MASTER2_IP" bash -s "$K3S_TOKEN" "$LB_VIP" "$MASTER1_IP" <<'MASTER2_INSTALL'
K3S_TOKEN="$1"
LB_VIP="$2"
MASTER1_IP="$3"

# Joindre le cluster
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --server="https://$MASTER1_IP:6443" \
  --tls-san="$LB_VIP" \
  --tls-san="10.0.0.101" \
  --tls-san="k3s-master-02" \
  --bind-address="0.0.0.0" \
  --advertise-address="10.0.0.101" \
  --node-ip="10.0.0.101" \
  --flannel-iface="eth0" \
  --disable="traefik" \
  --disable="servicelb" \
  --write-kubeconfig-mode="644"

sleep 10

if systemctl is-active k3s &>/dev/null; then
    echo "    ✓ K3s master-02 installé"
else
    echo "    ✗ Échec installation"
fi
MASTER2_INSTALL

echo ""

# Master 3
echo "  Installation k3s-master-03..."
ssh -o StrictHostKeyChecking=no root@"$MASTER3_IP" bash -s "$K3S_TOKEN" "$LB_VIP" "$MASTER1_IP" <<'MASTER3_INSTALL'
K3S_TOKEN="$1"
LB_VIP="$2"
MASTER1_IP="$3"

# Joindre le cluster
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --server="https://$MASTER1_IP:6443" \
  --tls-san="$LB_VIP" \
  --tls-san="10.0.0.102" \
  --tls-san="k3s-master-03" \
  --bind-address="0.0.0.0" \
  --advertise-address="10.0.0.102" \
  --node-ip="10.0.0.102" \
  --flannel-iface="eth0" \
  --disable="traefik" \
  --disable="servicelb" \
  --write-kubeconfig-mode="644"

sleep 10

if systemctl is-active k3s &>/dev/null; then
    echo "    ✓ K3s master-03 installé"
else
    echo "    ✗ Échec installation"
fi
MASTER3_INSTALL

echo ""
sleep 15

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: CONFIGURATION DU LOAD BALANCER HETZNER
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Configuration Load Balancer pour K3s                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Configuration HAProxy pour K3s API (6443)..."

for host in haproxy-01 haproxy-02; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "    $host:"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'HAPROXY_K3S'
BASE="/opt/keybuzz/k3s-lb"
mkdir -p "$BASE/config"

# Arrêter ancien container si présent
docker stop haproxy-k3s 2>/dev/null
docker rm haproxy-k3s 2>/dev/null

# Configuration HAProxy pour K3s API
cat > "$BASE/config/haproxy-k3s.cfg" <<'EOF'
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global
    option tcplog

# K3s API Server
listen k3s_api
    bind *:6443
    mode tcp
    balance roundrobin
    option tcp-check
    server k3s-master-01 10.0.0.100:6443 check inter 2s fall 3 rise 2
    server k3s-master-02 10.0.0.101:6443 check inter 2s fall 3 rise 2
    server k3s-master-03 10.0.0.102:6443 check inter 2s fall 3 rise 2
EOF

# Démarrer HAProxy
docker run -d \
    --name haproxy-k3s \
    --restart unless-stopped \
    --network host \
    -v ${BASE}/config/haproxy-k3s.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
    haproxy:2.9-alpine

# Ouvrir le port dans UFW
ufw allow 6443/tcp comment 'K3s API' 2>/dev/null
ufw --force reload 2>/dev/null

sleep 2

if docker ps | grep -q haproxy-k3s; then
    echo "      ✓ HAProxy K3s configuré"
else
    echo "      ✗ Échec configuration"
fi
HAPROXY_K3S
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: RÉCUPÉRATION KUBECONFIG
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Configuration kubeconfig                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Récupérer le kubeconfig
echo "  Récupération du kubeconfig..."
ssh -o StrictHostKeyChecking=no root@"$MASTER1_IP" "cat /etc/rancher/k3s/k3s.yaml" > "$CREDS_DIR/k3s-kubeconfig.yaml"

# Modifier pour pointer vers le LB
sed -i "s/127.0.0.1:6443/$LB_VIP:6443/g" "$CREDS_DIR/k3s-kubeconfig.yaml"
chmod 600 "$CREDS_DIR/k3s-kubeconfig.yaml"

# Copier localement
cp "$CREDS_DIR/k3s-kubeconfig.yaml" ~/.kube/config 2>/dev/null || mkdir -p ~/.kube && cp "$CREDS_DIR/k3s-kubeconfig.yaml" ~/.kube/config

echo "    ✓ Kubeconfig configuré"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: VÉRIFICATION DU CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Vérification du cluster K3s                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

export KUBECONFIG="$CREDS_DIR/k3s-kubeconfig.yaml"

echo "  État des nœuds:"
kubectl get nodes -o wide || echo "    Erreur kubectl"

echo ""
echo "  Test via Load Balancer ($LB_VIP:6443):"
echo -n "    Connexion API: "
if timeout 3 nc -zv "$LB_VIP" 6443 &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "    kubectl via LB: "
if kubectl --server="https://$LB_VIP:6443" get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════"

# Créer le résumé
cat > "$CREDS_DIR/k3s-summary.txt" <<EOF
K3S HA - INSTALLATION COMPLÈTE
═══════════════════════════════════════════════════════════════════

Date: $(date)

ARCHITECTURE:
  • 3 masters K3s avec etcd intégré
  • Load Balancer sur $LB_VIP:6443
  • 2 HAProxy pour redondance

ENDPOINTS:
  API Server: https://$LB_VIP:6443
  
CREDENTIALS:
  Token: $CREDS_DIR/k3s.env
  Kubeconfig: $CREDS_DIR/k3s-kubeconfig.yaml

ACCÈS:
  export KUBECONFIG=$CREDS_DIR/k3s-kubeconfig.yaml
  kubectl get nodes

CONFIGURATION HETZNER LB:
  Service K3s API:
    • Type: TCP
    • Port source: 6443
    • Port destination: 6443
    • Backends: haproxy-01, haproxy-02

HAUTE DISPONIBILITÉ:
  • Tolérance de panne: 1 master peut tomber
  • etcd en mode cluster intégré
  • Failover automatique via LB
EOF

if kubectl get nodes &>/dev/null; then
    echo -e "$OK K3S HA INSTALLATION COMPLÈTE ET OPÉRATIONNELLE"
    echo ""
    echo "Cluster K3s:"
    kubectl get nodes --no-headers | awk '{print "  • "$1" ("$2")"}'
    echo ""
    echo "Endpoint: https://$LB_VIP:6443"
    echo "Kubeconfig: $CREDS_DIR/k3s-kubeconfig.yaml"
    echo ""
    echo "Pour utiliser kubectl:"
    echo "  export KUBECONFIG=$CREDS_DIR/k3s-kubeconfig.yaml"
    echo "  kubectl get nodes"
else
    echo -e "$KO Installation incomplète"
    echo "Vérifier les logs: $MAIN_LOG"
fi
echo "═══════════════════════════════════════════════════════════════════"
