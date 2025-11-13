#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              K3S MASTER DIAGNOSTIC (troubleshooting)               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

# Quel master diagnostiquer ?
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <master-hostname>"
    echo "Exemple: $0 k3s-master-02"
    exit 1
fi

MASTER="$1"
BASE_DIR="/opt/keybuzz-installer"
INVENTORY="${BASE_DIR}/inventory/servers.tsv"
CREDS_DIR="${BASE_DIR}/credentials"

MASTER_IP=$(awk -F'\t' -v m="$MASTER" '$2==m{print $3}' "$INVENTORY")

if [[ -z "$MASTER_IP" ]]; then
    echo "Erreur: Master $MASTER introuvable dans servers.tsv"
    exit 1
fi

echo "Master à diagnostiquer : $MASTER ($MASTER_IP)"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# 1. CONNECTIVITÉ & RÉSEAU
# ═══════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════════════"
echo "1. CONNECTIVITÉ & RÉSEAU"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

printf "%-60s" "SSH accessible"
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$MASTER_IP" 'echo ok' &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

printf "%-60s" "Connectivité vers LB API (10.0.0.5:6443)"
if ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "timeout 3 bash -c '</dev/tcp/10.0.0.5/6443'" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO - CRITIQUE"
fi

printf "%-60s" "Connectivité vers LB API (10.0.0.6:6443)"
if ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "timeout 3 bash -c '</dev/tcp/10.0.0.6/6443'" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN"
fi

printf "%-60s" "Résolution DNS (8.8.8.8)"
if ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "ping -c 1 -W 2 8.8.8.8" &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# ═══════════════════════════════════════════════════════════════════════
# 2. ÉTAT K3S
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "2. ÉTAT K3S SUR $MASTER"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Service K3s status:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "systemctl status k3s.service --no-pager" || true

echo ""
echo "Dernières lignes logs K3s (50 lignes):"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "journalctl -u k3s -n 50 --no-pager" || true

# ═══════════════════════════════════════════════════════════════════════
# 3. PORTS & FIREWALL
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "3. PORTS & FIREWALL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Ports en écoute:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "ss -tlnp | grep -E '6443|2379|2380|10250'" || echo "Aucun port K3s en écoute"

echo ""
echo "Règles UFW actives:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "ufw status | grep -E '6443|2379|2380|10250'" || echo "Aucune règle K3s"

# ═══════════════════════════════════════════════════════════════════════
# 4. PROCESSUS K3S
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "4. PROCESSUS K3S"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Processus k3s en cours:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "ps aux | grep k3s | grep -v grep" || echo "Aucun processus k3s"

# ═══════════════════════════════════════════════════════════════════════
# 5. FICHIERS DE CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "5. FICHIERS DE CONFIGURATION"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Variables d'environnement K3s:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "cat /etc/systemd/system/k3s.service.env" 2>/dev/null || echo "Fichier non trouvé"

echo ""
echo "Service unit K3s:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "systemctl cat k3s.service" 2>/dev/null || echo "Service non trouvé"

# ═══════════════════════════════════════════════════════════════════════
# 6. TOKEN VALIDATION
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "6. TOKEN K3S"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [[ -f "${CREDS_DIR}/k3s_token.txt" ]]; then
    TOKEN=$(cat "${CREDS_DIR}/k3s_token.txt")
    echo "Token présent localement : ${TOKEN:0:30}..."
    
    # Vérifier si le token est présent sur le nœud
    REMOTE_TOKEN=$(ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "cat /etc/systemd/system/k3s.service.env | grep K3S_TOKEN" 2>/dev/null || echo "")
    
    if [[ -n "$REMOTE_TOKEN" ]]; then
        echo "Token configuré sur $MASTER"
    else
        echo "⚠️  Token NON configuré sur $MASTER"
    fi
else
    echo "❌ Token local introuvable dans ${CREDS_DIR}/k3s_token.txt"
fi

# ═══════════════════════════════════════════════════════════════════════
# 7. ÉTAT CLUSTER (depuis master-01)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "7. ÉTAT CLUSTER (depuis master-01)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

MASTER_01_IP=$(awk -F'\t' '$2=="k3s-master-01"{print $3}' "$INVENTORY")

if [[ -n "$MASTER_01_IP" ]]; then
    echo "Nœuds dans le cluster:"
    ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "kubectl get nodes -o wide" 2>/dev/null || echo "Impossible de lister les nœuds"
    
    echo ""
    echo "État etcd:"
    ssh -o StrictHostKeyChecking=no root@"$MASTER_01_IP" "kubectl get endpoints -n kube-system" 2>/dev/null | grep etcd || echo "Endpoints etcd introuvables"
fi

# ═══════════════════════════════════════════════════════════════════════
# 8. RESSOURCES SYSTÈME
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "8. RESSOURCES SYSTÈME"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Mémoire disponible:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "free -h"

echo ""
echo "Espace disque:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "df -h /"

echo ""
echo "Load average:"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "uptime"

# ═══════════════════════════════════════════════════════════════════════
# 9. RECOMMANDATIONS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "                         RECOMMANDATIONS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Actions suggérées selon les erreurs détectées :"
echo ""
echo "1. Si K3s refuse de démarrer :"
echo "   ./k3s_fix_master.sh $MASTER"
echo ""
echo "2. Si problème de connectivité LB API :"
echo "   - Vérifier configuration Load Balancer Hetzner"
echo "   - Vérifier que master-01 est bien accessible sur 6443"
echo ""
echo "3. Si problème de token :"
echo "   - Régénérer token depuis master-01"
echo "   - Relancer installation avec nouveau token"
echo ""
echo "4. Si problème de ports déjà utilisés :"
echo "   ./k3s_cleanup_master.sh $MASTER"
echo "   Puis relancer installation"
echo ""
echo "5. Logs détaillés en temps réel :"
echo "   ssh root@$MASTER_IP 'journalctl -u k3s -f'"
echo ""

echo "Diagnostic terminé pour $MASTER"
