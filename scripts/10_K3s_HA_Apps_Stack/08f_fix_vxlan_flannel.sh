#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Déblocage VXLAN (Flannel) - Port 8472/UDP                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

K3S_NODES=(
    k3s-master-01 k3s-master-02 k3s-master-03
    k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05
)

echo ""
echo "Problème identifié :"
echo "  → Les workers ne peuvent PAS communiquer via Flannel VXLAN"
echo "  → UFW bloque le port 8472/UDP utilisé par Flannel"
echo ""
echo "Symptômes :"
echo "  → Les pods ne peuvent pas communiquer entre workers"
echo "  → Le ClusterIP service ne fonctionne que localement"
echo "  → Les NodePorts ne fonctionnent que sur le worker hébergeant le pod"
echo ""
echo "Solution :"
echo "  → Autoriser le port 8472/UDP depuis le réseau privé Hetzner (10.0.0.0/16)"
echo "  → Autoriser les réseaux K3s (10.42.0.0/16 et 10.43.0.0/16)"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Déblocage UFW sur tous les nœuds K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for node in "${K3S_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    
    if [ -z "$ip" ]; then
        echo -e "$WARN $node : IP introuvable"
        continue
    fi
    
    echo "→ $node ($ip)"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'EOF'
set -u

# Fonction pour ajouter une règle UFW (idempotente)
add_ufw_rule() {
    local from="$1"
    local proto="$2"
    local port="$3"
    local comment="$4"
    
    # Construire la règle
    local rule="from $from proto $proto to any port $port"
    
    # Vérifier si la règle existe déjà
    if ! ufw status | grep -q "$port/$proto"; then
        ufw allow $rule comment "$comment" >/dev/null 2>&1
        echo "  ✓ Règle ajoutée : $port/$proto depuis $from"
    else
        echo "  ✓ Règle existe déjà : $port/$proto"
    fi
}

echo "  [1/4] Autorisation VXLAN (8472/UDP)..."
add_ufw_rule "10.0.0.0/16" "udp" "8472" "Flannel VXLAN"

echo "  [2/4] Autorisation Pod Network (10.42.0.0/16)..."
if ! ufw status | grep -q "10.42.0.0/16"; then
    ufw allow from 10.42.0.0/16 comment "K3s Pod Network" >/dev/null 2>&1
    echo "  ✓ Règle ajoutée : 10.42.0.0/16"
else
    echo "  ✓ Règle existe déjà : 10.42.0.0/16"
fi

echo "  [3/4] Autorisation Service Network (10.43.0.0/16)..."
if ! ufw status | grep -q "10.43.0.0/16"; then
    ufw allow from 10.43.0.0/16 comment "K3s Service Network" >/dev/null 2>&1
    echo "  ✓ Règle ajoutée : 10.43.0.0/16"
else
    echo "  ✓ Règle existe déjà : 10.43.0.0/16"
fi

echo "  [4/4] Rechargement UFW..."
ufw reload >/dev/null 2>&1
echo "  ✓ UFW rechargé"
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $node corrigé"
    else
        echo -e "  $WARN Erreurs sur $node"
    fi
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Déblocage UFW terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 10s pour que les règles UFW prennent effet..."
sleep 10

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ VÉRIFICATION DE LA CONNECTIVITÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Récupérer l'IP du pod Ingress NGINX
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
INGRESS_POD_IP=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.podIP}'" 2>/dev/null)

echo "Test ping vers le pod Ingress NGINX ($INGRESS_POD_IP) :"
echo ""

WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)
SUCCESS=0
FAILED=0

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker ($ip) ... "
    
    if ssh -o StrictHostKeyChecking=no root@"$ip" \
        "ping -c 1 -W 2 $INGRESS_POD_IP" >/dev/null 2>&1; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
        ((FAILED++))
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Résultat : $SUCCESS/$((SUCCESS+FAILED)) workers peuvent joindre le pod"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ $SUCCESS -ge 4 ]; then
    echo -e "$OK Réseau Flannel VXLAN opérationnel"
    echo ""
    echo "Prochaine étape :"
    echo "  1. Redéployer Ingress NGINX en DaemonSet"
    echo "     ./08d_redeploy_ingress_daemonset.sh"
    echo ""
    echo "  2. Tester les NodePorts sur tous les workers"
    echo "     ./08_fix_ufw_nodeports_urgent.sh"
    echo ""
    exit 0
else
    echo -e "$WARN Réseau Flannel partiellement fonctionnel"
    echo ""
    echo "Actions recommandées :"
    echo ""
    echo "1. Vérifier les règles UFW sur les workers KO :"
    for worker in "${WORKER_NODES[@]}"; do
        ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
        
        if ! ssh -o StrictHostKeyChecking=no root@"$ip" \
            "ping -c 1 -W 2 $INGRESS_POD_IP" >/dev/null 2>&1; then
            echo "   ssh root@$ip 'ufw status | grep -E \"8472|10.42|10.43\"'"
        fi
    done
    echo ""
    echo "2. Si les règles sont OK, vérifier les logs Flannel :"
    echo "   ssh root@<worker-ip> 'journalctl -u k3s-agent | grep flannel | tail -20'"
    echo ""
    exit 1
fi
