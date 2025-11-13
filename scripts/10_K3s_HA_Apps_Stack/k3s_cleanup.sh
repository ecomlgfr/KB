#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              K3S HA CLUSTER - Nettoyage complet                   ║"
echo "║                    (Désinstallation 3 Masters)                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

# Vérifications préalables
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

MASTER_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)

echo ""
echo "⚠️  ATTENTION : Ce script va SUPPRIMER K3s sur tous les masters"
echo ""
echo "Cela inclut :"
echo "  - Arrêt des services K3s"
echo "  - Suppression des binaires K3s"
echo "  - Nettoyage des données etcd"
echo "  - Suppression des configurations"
echo "  - Nettoyage /var/lib/rancher/k3s"
echo ""
echo "Les règles UFW ne seront PAS touchées"
echo ""

# Récupérer les IPs privées depuis servers.tsv
declare -A MASTER_IPS
for node in "${MASTER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -z "$ip" ]; then
        echo -e "$WARN IP privée introuvable pour $node dans servers.tsv"
        continue
    fi
    MASTER_IPS[$node]=$ip
    echo "  $node : $ip"
done

echo ""
read -p "Continuer le nettoyage ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ NETTOYAGE EN COURS ═══"
echo "═══════════════════════════════════════════════════════════════════"

# Fonction de nettoyage pour un master
clean_master() {
    local node="$1"
    local ip="$2"
    
    echo ""
    echo "→ Nettoyage $node ($ip)"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEAN_SCRIPT'
set -u
set -o pipefail

echo "  [1/6] Arrêt du service K3s..."
systemctl stop k3s 2>/dev/null || true
systemctl stop k3s-agent 2>/dev/null || true

echo "  [2/6] Désactivation du service K3s..."
systemctl disable k3s 2>/dev/null || true
systemctl disable k3s-agent 2>/dev/null || true

echo "  [3/6] Exécution du script de désinstallation K3s..."
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
    echo "     ✓ k3s-uninstall.sh exécuté"
else
    echo "     ⚠ k3s-uninstall.sh non trouvé, nettoyage manuel"
fi

echo "  [4/6] Nettoyage des répertoires K3s..."
rm -rf /var/lib/rancher/k3s 2>/dev/null || true
rm -rf /etc/rancher/k3s 2>/dev/null || true
rm -rf /opt/keybuzz/k3s 2>/dev/null || true
rm -rf /run/k3s 2>/dev/null || true

echo "  [5/6] Nettoyage des binaires K3s..."
rm -f /usr/local/bin/k3s 2>/dev/null || true
rm -f /usr/local/bin/k3s-killall.sh 2>/dev/null || true
rm -f /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true

echo "  [6/6] Nettoyage des services systemd..."
rm -f /etc/systemd/system/k3s.service 2>/dev/null || true
rm -f /etc/systemd/system/k3s.service.env 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/k3s.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

echo "  [✓] Nettoyage terminé"
CLEAN_SCRIPT
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $node nettoyé"
    else
        echo -e "  $WARN $node nettoyage partiel (quelques erreurs)"
    fi
}

# Nettoyer tous les masters
for node in "${MASTER_NODES[@]}"; do
    ip="${MASTER_IPS[$node]}"
    if [ -n "$ip" ]; then
        clean_master "$node" "$ip"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Nettoyage des fichiers locaux (install-01)
echo "→ Nettoyage des fichiers locaux (install-01)"
echo ""

LOG_DIR="/opt/keybuzz-installer/logs"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

if [ -d "$LOG_DIR" ]; then
    echo "  Suppression des logs K3s..."
    rm -f "$LOG_DIR"/k3s_*.log 2>/dev/null || true
fi

if [ -d "$CREDENTIALS_DIR" ]; then
    echo "  Suppression des credentials K3s..."
    rm -f "$CREDENTIALS_DIR/k3s.yaml" 2>/dev/null || true
    rm -f "$CREDENTIALS_DIR/k3s-token.txt" 2>/dev/null || true
    rm -f "$CREDENTIALS_DIR/k3s-cluster-summary.txt" 2>/dev/null || true
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK NETTOYAGE TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Les masters sont prêts pour une nouvelle installation K3s"
echo ""
echo "Pour réinstaller K3s, lancez :"
echo "  ./k3s_ha_install.sh"
echo ""
