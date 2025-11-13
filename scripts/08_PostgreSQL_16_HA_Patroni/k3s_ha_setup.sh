#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         K3S_HA_SETUP - Installation K3s Haute Disponibilité        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/k3s_ha_setup_$TIMESTAMP.log"

mkdir -p "$LOG_DIR" "$CREDS_DIR"

echo ""
echo "Installation K3s HA avec etcd intégré"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: ARRÊT ETCD EXTERNE (si présent)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Nettoyage etcd externe                                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Arrêt d'etcd externe sur les masters K3s..."
for i in 0 1 2; do
    host="k3s-master-0$((i+1))"
    ip="10.0.0.10$i"
    echo -n "    $host: "
    ssh -o StrictHostKeyChecking=no root@"$ip" "docker stop etcd 2>/dev/null; docker rm etcd 2>/dev/null" &>/dev/null
    echo -e "$OK"
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: CONFIGURATION FIREWALL
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Configuration firewall pour K3s                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for i in 0 1 2; do
    host="k3s-master-0$((i+1))"
    ip="10.0.0.10$i"
    echo "  Configuration UFW sur $host..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'EOF' 2>/dev/null
    # Ports K3s
    ufw allow 6443/tcp comment 'K3s API' 2>/dev/null
    ufw allow 2379:2380/tcp comment 'etcd' 2>/dev/null
    ufw allow 10250/tcp comment 'Kubelet' 2>/dev/null
    ufw allow 10251/tcp comment 'Scheduler' 2>/dev/null
    ufw allow 10252/tcp comment 'Controller' 2>/dev/null
    ufw allow 10255/tcp comment 'Read-only Kubelet' 2>/dev/null
    ufw allow 8472/udp comment 'Flannel VXLAN' 2>/dev/null
    
    # Autoriser tout le réseau privé
    ufw allow from 10.0.0.0/16 comment 'Private network' 2>/dev/null
    
    # Recharger
    ufw --force reload 2>/dev/null
    
    echo "    ✓ Firewall configuré"
EOF
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: NETTOYAGE K3S EXISTANT
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Nettoyage installations K3s existantes                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for i in 0 1 2; do
    host="k3s-master-0$((i+1))"
    ip="10.0.0.10$i"
    echo -n "  Nettoyage $host: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'EOF' 2>/dev/null
    # Arrêter K3s
    systemctl stop k3s 2>/dev/null
    
    # Désinstaller si existe
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null
    fi
    
    # Nettoyer les données
    rm -rf /var/lib/rancher /etc/rancher
    
    # Tuer les processus zombies
    pkill -9 -f k3s 2>/dev/null
    pkill -9 -f etcd 2>/dev/null
    
    # Libérer les ports
    fuser -k 6443/tcp 2>/dev/null
    fuser -k 2379/tcp 2>/dev/null
    fuser -k 2380/tcp 2>/dev/null
EOF
    
    echo -e "$OK"
done

echo ""
sleep 5

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: INSTALLATION MASTER-01 (avec cluster-init)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Installation k3s-master-01 (leader)                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Installation K3s sur master-01..."

ssh -o StrictHostKeyChecking=no root@"10.0.0.100" bash <<'EOF'
# Installation avec cluster-init (etcd intégré)
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san='10.0.0.10' \
  --tls-san='10.0.0.100' \
  --tls-san='k3s-master-01' \
  --bind-address='0.0.0.0' \
  --advertise-address='10.0.0.100' \
  --node-ip='10.0.0.100' \
  --flannel-iface='enp7s0' \
  --disable='traefik' \
  --disable='servicelb' \
  --write-kubeconfig-mode='644'
EOF

echo "  Attente de stabilisation (30s)..."
sleep 30

# Vérifier que master-01 est prêt
echo -n "  Vérification master-01: "
if ssh -o StrictHostKeyChecking=no root@"10.0.0.100" "kubectl get nodes" &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "    K3s n'a pas démarré correctement sur master-01"
    exit 1
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: RÉCUPÉRATION DU TOKEN
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Récupération du token K3s                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

TOKEN=$(ssh -o StrictHostKeyChecking=no root@"10.0.0.100" "cat /var/lib/rancher/k3s/server/node-token")

if [ -z "$TOKEN" ]; then
    echo -e "  $KO Token non trouvé"
    exit 1
fi

echo "  Token récupéré: ${TOKEN:0:50}..."

# Sauvegarder le token
cat > "$CREDS_DIR/k3s.env" <<EOTOK
#!/bin/bash
# K3s Credentials
export K3S_TOKEN="$TOKEN"
export K3S_API_ENDPOINT="https://10.0.0.10:6443"
export K3S_MASTER1="10.0.0.100"
export K3S_MASTER2="10.0.0.101"
export K3S_MASTER3="10.0.0.102"
EOTOK
chmod 600 "$CREDS_DIR/k3s.env"

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: INSTALLATION MASTER-02
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Installation k3s-master-02                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Installation K3s sur master-02..."

ssh -o StrictHostKeyChecking=no root@"10.0.0.101" bash -s "$TOKEN" <<'EOF'
TOKEN="$1"

curl -sfL https://get.k3s.io | K3S_TOKEN="$TOKEN" sh -s - server \
  --server='https://10.0.0.100:6443' \
  --tls-san='10.0.0.10' \
  --tls-san='10.0.0.101' \
  --tls-san='k3s-master-02' \
  --bind-address='0.0.0.0' \
  --advertise-address='10.0.0.101' \
  --node-ip='10.0.0.101' \
  --flannel-iface='enp7s0' \
  --disable='traefik' \
  --disable='servicelb' \
  --write-kubeconfig-mode='644'
EOF

echo "  Attente de synchronisation (20s)..."
sleep 20

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: INSTALLATION MASTER-03
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Installation k3s-master-03                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Installation K3s sur master-03..."

ssh -o StrictHostKeyChecking=no root@"10.0.0.102" bash -s "$TOKEN" <<'EOF'
TOKEN="$1"

curl -sfL https://get.k3s.io | K3S_TOKEN="$TOKEN" sh -s - server \
  --server='https://10.0.0.100:6443' \
  --tls-san='10.0.0.10' \
  --tls-san='10.0.0.102' \
  --tls-san='k3s-master-03' \
  --bind-address='0.0.0.0' \
  --advertise-address='10.0.0.102' \
  --node-ip='10.0.0.102' \
  --flannel-iface='enp7s0' \
  --disable='traefik' \
  --disable='servicelb' \
  --write-kubeconfig-mode='644'
EOF

echo "  Attente de synchronisation (20s)..."
sleep 20

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 7: CONFIGURATION HAPROXY
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 7: Configuration HAProxy pour K3s                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in haproxy-01 haproxy-02; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Configuration $host ($IP)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'HAPROXY'
# Arrêter ancien container si présent
docker stop haproxy-k3s 2>/dev/null
docker rm haproxy-k3s 2>/dev/null

# Créer config HAProxy
mkdir -p /opt/keybuzz/k3s-lb/config

cat > /opt/keybuzz/k3s-lb/config/haproxy.cfg <<'EOF'
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
    balance roundrobin
    option tcp-check
    server k3s-master-01 10.0.0.100:6443 check inter 2s fall 3 rise 2
    server k3s-master-02 10.0.0.101:6443 check inter 2s fall 3 rise 2
    server k3s-master-03 10.0.0.102:6443 check inter 2s fall 3 rise 2

# Stats
stats enable
stats uri /stats
stats refresh 10s
EOF

# Démarrer HAProxy
docker run -d \
    --name haproxy-k3s \
    --restart unless-stopped \
    --network host \
    -v /opt/keybuzz/k3s-lb/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
    haproxy:2.9-alpine

# Ouvrir port
ufw allow 6443/tcp comment 'K3s API via HAProxy' 2>/dev/null
ufw --force reload 2>/dev/null

echo "    ✓ HAProxy configuré"
HAPROXY
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 8: RÉCUPÉRATION KUBECONFIG
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 8: Configuration kubeconfig                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Récupérer le kubeconfig
ssh -o StrictHostKeyChecking=no root@"10.0.0.100" "cat /etc/rancher/k3s/k3s.yaml" > "$CREDS_DIR/k3s-kubeconfig.yaml"

# Modifier pour pointer vers le LB
sed -i "s/127.0.0.1:6443/10.0.0.10:6443/g" "$CREDS_DIR/k3s-kubeconfig.yaml"
chmod 600 "$CREDS_DIR/k3s-kubeconfig.yaml"

# Copier localement
mkdir -p ~/.kube
cp "$CREDS_DIR/k3s-kubeconfig.yaml" ~/.kube/config

echo "  Kubeconfig sauvegardé: $CREDS_DIR/k3s-kubeconfig.yaml"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 9: VÉRIFICATION FINALE
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 9: Vérification du cluster K3s                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

export KUBECONFIG="$CREDS_DIR/k3s-kubeconfig.yaml"

echo "  État des nœuds:"
kubectl get nodes -o wide

echo ""
echo "  Test via Load Balancer (10.0.0.10:6443):"

# Test connexion directe au LB
echo -n "    Connexion TCP: "
if timeout 3 nc -zv 10.0.0.10 6443 &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN (Le LB Hetzner doit avoir le service K3s configuré)"
fi

# Test kubectl via LB
echo -n "    kubectl via LB: "
if kubectl --server="https://10.0.0.10:6443" get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN (Ajouter le service dans le LB Hetzner)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════"

NODES_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

if [ "$NODES_COUNT" -eq 3 ]; then
    echo -e "$OK K3S HA INSTALLATION COMPLÈTE"
    echo ""
    echo "Architecture déployée:"
    echo "  • 3 masters K3s avec etcd intégré (raft)"
    echo "  • HAProxy sur haproxy-01/02 (port 6443)"
    echo "  • Haute disponibilité active"
    echo ""
    echo "Configuration LB Hetzner requise:"
    echo "  Service: TCP 6443 → haproxy-01:6443, haproxy-02:6443"
    echo ""
    echo "Credentials:"
    echo "  Token: $CREDS_DIR/k3s.env"
    echo "  Kubeconfig: $CREDS_DIR/k3s-kubeconfig.yaml"
    echo ""
    echo "Utilisation:"
    echo "  export KUBECONFIG=$CREDS_DIR/k3s-kubeconfig.yaml"
    echo "  kubectl get nodes"
else
    echo -e "$KO Installation incomplète ($NODES_COUNT/3 nœuds)"
    echo "Vérifier les logs: $MAIN_LOG"
fi

echo "═══════════════════════════════════════════════════════════════════"
