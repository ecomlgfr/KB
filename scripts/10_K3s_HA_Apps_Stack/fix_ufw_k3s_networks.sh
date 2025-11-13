#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     Configuration UFW pour K3s (autoriser réseaux internes)       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

TSV_FILE="/opt/keybuzz-installer/inventory/servers.tsv"

echo ""
echo "Problème identifié :"
echo "  → UFW bloque les réseaux K8s internes"
echo "  → 10.42.0.0/16 (pods K3s)"
echo "  → 10.43.0.0/16 (services K8s)"
echo ""
echo "Solution :"
echo "  → Autoriser ces plages sur TOUS les nœuds K3s (masters + workers)"
echo ""

read -p "Configurer UFW pour K3s ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Configuration UFW sur les nœuds K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Liste des nœuds K3s (masters + workers)
K3S_NODES=(
    "k3s-master-01"
    "k3s-master-02"
    "k3s-master-03"
    "k3s-worker-01"
    "k3s-worker-02"
    "k3s-worker-03"
    "k3s-worker-04"
    "k3s-worker-05"
)

for node in "${K3S_NODES[@]}"; do
    echo "[$(date '+%F %T')] Configuration $node..."
    
    # Récupérer l'IP du nœud
    NODE_IP=$(awk -F'\t' -v node="$node" '$2==node {print $3}' "$TSV_FILE")
    
    if [ -z "$NODE_IP" ]; then
        echo -e "  $KO IP introuvable pour $node"
        continue
    fi
    
    echo "  IP : $NODE_IP"
    
    # Configurer UFW sur le nœud
    ssh -o StrictHostKeyChecking=no root@"$NODE_IP" bash <<'FIREWALL'
set -u

echo "  → Autorisation des réseaux K8s..."

# Autoriser le réseau des pods (Flannel)
ufw allow from 10.42.0.0/16 comment "K3s Pod Network"

# Autoriser le réseau des services (ClusterIP)
ufw allow from 10.43.0.0/16 comment "K3s Service Network"

# Autoriser le réseau Hetzner privé (déjà fait normalement)
ufw allow from 10.0.0.0/16 comment "Hetzner Private Network"

# Recharger UFW
ufw reload >/dev/null 2>&1

echo "  ✓ UFW configuré"

# Vérifier
echo "  → Règles UFW K8s :"
ufw status | grep -E "10.42|10.43" | head -4

FIREWALL
    
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Configuration UFW terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Réseaux autorisés sur tous les nœuds K3s :"
echo "  ✓ 10.0.0.0/16  (Hetzner privé)"
echo "  ✓ 10.42.0.0/16 (K3s pods)"
echo "  ✓ 10.43.0.0/16 (K3s services)"
echo ""
echo "Prochaines étapes :"
echo "  1. Les pods devraient pouvoir communiquer maintenant"
echo "  2. Redémarrer les pods en erreur :"
echo "     ssh root@10.0.0.100 kubectl rollout restart deployment -n chatwoot"
echo "     ssh root@10.0.0.100 kubectl rollout restart deployment -n superset"
echo "  3. Vérifier après 2 minutes :"
echo "     ssh root@10.0.0.100 kubectl get pods -A"
echo ""

exit 0
