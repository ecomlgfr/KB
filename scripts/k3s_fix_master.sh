#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           K3S MASTER FIX & REINSTALL (troubleshooting)             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

# Quel master corriger ?
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <master-hostname>"
    echo "Exemple: $0 k3s-master-02"
    exit 1
fi

MASTER="$1"
BASE_DIR="/opt/keybuzz-installer"
INVENTORY="${BASE_DIR}/inventory/servers.tsv"
CREDS_DIR="${BASE_DIR}/credentials"
TOKEN_FILE="${CREDS_DIR}/k3s_token.txt"

MASTER_IP=$(awk -F'\t' -v m="$MASTER" '$2==m{print $3}' "$INVENTORY")

if [[ -z "$MASTER_IP" ]]; then
    echo -e "$KO Master $MASTER introuvable dans servers.tsv"
    exit 1
fi

echo "Master à corriger : $MASTER ($MASTER_IP)"
echo ""

# Vérifier token
if [[ ! -f "$TOKEN_FILE" ]]; then
    echo -e "$KO Token K3s introuvable : $TOKEN_FILE"
    echo "Exécuter d'abord k3s_ha_install.sh pour bootstrapper master-01"
    exit 1
fi

K3S_TOKEN=$(cat "$TOKEN_FILE")
LB_API="10.0.0.5"

echo "Token K3s : ${K3S_TOKEN:0:30}..."
echo "LB API : $LB_API:6443"
echo ""

# Demander confirmation
read -p "Nettoyer et réinstaller K3s sur $MASTER ? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Annulé"
    exit 0
fi

echo ""
echo "═══ ÉTAPE 1 : Nettoyage K3s sur $MASTER ═══"

ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "bash -s" <<'EOCLEAN'
set -u
set -o pipefail

echo "Arrêt et nettoyage K3s..."

# Arrêt service
systemctl stop k3s 2>/dev/null || true
systemctl disable k3s 2>/dev/null || true

# Kill processus résiduels
killall -9 k3s 2>/dev/null || true
killall -9 containerd-shim 2>/dev/null || true
killall -9 containerd 2>/dev/null || true

# Nettoyage complet
if [[ -f /usr/local/bin/k3s-killall.sh ]]; then
    /usr/local/bin/k3s-killall.sh 2>/dev/null || true
fi

if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
fi

# Nettoyage manuel fichiers
rm -rf /etc/rancher/k3s
rm -rf /var/lib/rancher/k3s
rm -rf /var/lib/kubelet
rm -f /etc/systemd/system/k3s.service
rm -f /etc/systemd/system/k3s.service.env
rm -f /usr/local/bin/k3s*
rm -f /usr/local/bin/kubectl
rm -f /usr/local/bin/crictl

# Reload systemd
systemctl daemon-reload

# Nettoyage réseaux (bridges, etc.)
ip link show | grep -E 'flannel|cni' | awk -F: '{print $2}' | xargs -I {} ip link delete {} 2>/dev/null || true

# IMPORTANT : On ne touche PAS à iptables/UFW
# Les règles UFW existantes restent en place (SSH, etc.)
echo "Nettoyage terminé (UFW préservé)"
EOCLEAN

if [[ $? -eq 0 ]]; then
    echo -e "$OK Nettoyage effectué"
else
    echo -e "$WARN Nettoyage partiel"
fi

sleep 3

# Attendre que master-01 soit complètement prêt
echo ""
echo "═══ ÉTAPE 2 : Vérification master-01 ═══"

MASTER_01_IP=$(awk -F'\t' '$2=="k3s-master-01"{print $3}' "$INVENTORY")

if [[ -n "$MASTER_01_IP" ]]; then
    echo "Vérification accessibilité master-01..."
    
    # Attendre que l'API soit vraiment prête
    MAX_WAIT=60
    WAIT=0
    while [[ $WAIT -lt $MAX_WAIT ]]; do
        if ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "kubectl get nodes" &>/dev/null; then
            echo -e "$OK master-01 opérationnel"
            break
        fi
        echo "Attente master-01 prêt... ($WAIT/$MAX_WAIT s)"
        sleep 5
        WAIT=$((WAIT + 5))
    done
    
    if [[ $WAIT -ge $MAX_WAIT ]]; then
        echo -e "$KO master-01 non prêt après ${MAX_WAIT}s"
        echo "Vérifier master-01 avant de continuer"
        exit 1
    fi
else
    echo -e "$WARN master-01 IP introuvable, on continue quand même..."
fi

sleep 3

# Réinstallation
echo ""
echo "═══ ÉTAPE 3 : Réinstallation K3s sur $MASTER ═══"

ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "bash -s" <<EOREINSTALL
set -u
set -o pipefail

IP_PRIVEE="\$(hostname -I | awk '{print \$1}')"
LB_API="$LB_API"
K3S_TOKEN="$K3S_TOKEN"

echo "IP privée détectée : \$IP_PRIVEE"
echo "Installation K3s master (join via \$LB_API:6443)..."

# ═══════════════════════════════════════════════════════════════
# UFW : AJOUT RÈGLES UNIQUEMENT (pas de reset)
# Les règles SSH existantes sont préservées
# ═══════════════════════════════════════════════════════════════

add_ufw_rule() {
    local RULE="\$1"
    local COMMENT="\$2"
    
    # Vérifier si la règle existe déjà
    if ! ufw status numbered | grep -q "\$COMMENT"; then
        ufw allow \$RULE comment "\$COMMENT" 2>/dev/null || true
        echo "Règle ajoutée : \$COMMENT"
    else
        echo "Règle existante : \$COMMENT"
    fi
}

# Ajout règles K3s masters
add_ufw_rule "from 10.0.0.0/16 to any port 6443 proto tcp" "K3s API"
add_ufw_rule "from 10.0.0.0/16 to any port 10250 proto tcp" "K3s kubelet"
add_ufw_rule "from 10.0.0.0/16 to any port 8472 proto udp" "K3s VXLAN"
add_ufw_rule "from 10.0.0.0/16 to any port 51820 proto udp" "K3s Flannel WireGuard"
add_ufw_rule "from 10.0.0.0/16 to any port 2379:2380 proto tcp" "K3s etcd"

echo "Configuration UFW mise à jour (sans interruption)"

# Installation K3s
curl -sfL https://get.k3s.io | K3S_TOKEN="\$K3S_TOKEN" sh -s - server \\
  --server "https://\${LB_API}:6443" \\
  --node-ip "\$IP_PRIVEE" \\
  --flannel-backend vxlan \\
  --disable traefik \\
  --disable servicelb

# Attente démarrage
echo "Attente démarrage K3s (30s)..."
sleep 30

# Vérification
if systemctl is-active --quiet k3s; then
    echo "OK : K3s démarré"
    
    # Test kubectl local (peut échouer si pas encore dans le cluster, c'est OK)
    /usr/local/bin/kubectl get nodes 2>/dev/null || echo "kubectl local pas encore fonctionnel (normal)"
    
    exit 0
else
    echo "KO : K3s non démarré"
    systemctl status k3s --no-pager
    journalctl -u k3s -n 50 --no-pager
    exit 1
fi
EOREINSTALL

INSTALL_EXIT=$?

echo ""

if [[ $INSTALL_EXIT -eq 0 ]]; then
    echo -e "$OK Installation réussie sur $MASTER"
    
    # Vérification depuis master-01
    echo ""
    echo "═══ ÉTAPE 4 : Vérification depuis master-01 ═══"
    
    sleep 10  # Laisser le temps au nœud de rejoindre
    
    if [[ -n "$MASTER_01_IP" ]]; then
        echo "Nœuds dans le cluster :"
        ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "kubectl get nodes -o wide"
        
        NODES_COUNT=$(ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "kubectl get nodes --no-headers | wc -l")
        echo ""
        echo "Nombre de nœuds : $NODES_COUNT"
        
        if [[ "$NODES_COUNT" -ge 2 ]]; then
            echo -e "$OK $MASTER a rejoint le cluster"
        else
            echo -e "$WARN $MASTER peut ne pas avoir rejoint le cluster immédiatement"
            echo "Attendre 1-2 minutes et vérifier : kubectl get nodes"
        fi
    fi
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║                    ✓ FIX TERMINÉ AVEC SUCCÈS                      ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Prochaines étapes :"
    echo "  - Vérifier : kubectl get nodes"
    echo "  - Si $MASTER n'apparaît pas : attendre 2 min et revérifier"
    echo "  - Continuer avec : ./k3s_ha_install.sh (si d'autres masters restent)"
    echo ""
    
else
    echo -e "$KO Échec réinstallation sur $MASTER"
    echo ""
    echo "Actions de dépannage :"
    echo "  1. Diagnostic détaillé : ./k3s_diagnose_master.sh $MASTER"
    echo "  2. Vérifier logs : ssh root@$MASTER_IP 'journalctl -u k3s -f'"
    echo "  3. Vérifier connectivité LB API : timeout 3 bash -c '</dev/tcp/$LB_API/6443'"
    echo ""
    exit 1
fi
