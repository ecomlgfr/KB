#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       Correction UFW - Déblocage NodePorts (URGENT)               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)
HTTP_NODEPORT=31695
HTTPS_NODEPORT=32720

echo ""
echo "Problème : Les ports NodePort sont bloqués par UFW"
echo ""
echo "Ports à ouvrir :"
echo "  - HTTP  : $HTTP_NODEPORT"
echo "  - HTTPS : $HTTPS_NODEPORT"
echo ""
echo "Workers affectés : 5"
echo ""

read -p "Débloquer maintenant ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Déblocage UFW sur les workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    if [ -z "$ip" ]; then
        continue
    fi
    
    echo "→ $worker ($ip)"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<EOF
set -u

# Fonction pour ajouter une règle UFW (idempotente)
add_ufw_rule() {
    local port="\$1"
    local comment="\$2"
    
    if ! ufw status | grep -q "\$port"; then
        ufw allow \$port/tcp comment "\$comment" >/dev/null 2>&1
        echo "  ✓ Port \$port ouvert"
    else
        echo "  ✓ Port \$port déjà ouvert"
    fi
}

# Ouvrir les NodePorts
add_ufw_rule "$HTTP_NODEPORT" "Ingress NGINX HTTP NodePort"
add_ufw_rule "$HTTPS_NODEPORT" "Ingress NGINX HTTPS NodePort"

# Recharger UFW SANS interruption
ufw reload >/dev/null 2>&1
echo "  ✓ UFW rechargé"
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $worker corrigé"
    else
        echo -e "  $KO Erreur sur $worker"
    fi
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Déblocage UFW terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test rapide depuis k3s-worker-01 :"
WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker ($ip) ... "
    
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "Prochaine étape :"
echo "  1. Attendre 30 secondes"
echo "  2. Vérifier le Load Balancer Hetzner (targets deviennent Healthy)"
echo "  3. Tester : curl http://n8n.keybuzz.io"
echo ""
