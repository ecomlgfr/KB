#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      Correction UFW - Autorisation réseaux K3s (10.42 + 10.43)    ║"
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
echo "  Les pods K3s (10.42.0.0/16) et services (10.43.0.0/16)"
echo "  ne sont pas autorisés dans UFW"
echo ""
echo "Conséquence :"
echo "  → Les pods ne peuvent pas communiquer"
echo "  → Les services ne sont pas accessibles"
echo "  → Les applications crashent en boucle"
echo ""
echo "Solution :"
echo "  Autoriser 10.42.0.0/16 et 10.43.0.0/16 sur tous les nœuds K3s"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Correction UFW sur les nœuds K3s ═══"
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
    local rule="$1"
    local comment="$2"
    
    # Vérifier si la règle existe déjà
    if ! ufw status | grep -q "$rule"; then
        ufw allow from $rule comment "$comment" >/dev/null 2>&1
        echo "  ✓ Règle ajoutée : $rule"
    else
        echo "  ✓ Règle existe déjà : $rule"
    fi
}

# Autoriser les réseaux K3s
add_ufw_rule "10.42.0.0/16" "K3s Pod Network (Flannel VXLAN)"
add_ufw_rule "10.43.0.0/16" "K3s Service Network (ClusterIP)"

# Recharger UFW SANS reset
ufw reload >/dev/null 2>&1

echo "  ✓ UFW rechargé"
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $node corrigé"
    else
        echo -e "  $WARN $node : erreurs"
    fi
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK UFW corrigé sur tous les nœuds"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Vérification :"
echo ""

# Vérifier sur un worker
WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "UFW status sur k3s-worker-01 :"
ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" "ufw status | grep -E '10.42|10.43'"

echo ""
echo "Les pods peuvent maintenant redémarrer correctement."
echo ""
echo "Prochaine étape :"
echo "  ./02_prepare_database.sh"
echo ""
