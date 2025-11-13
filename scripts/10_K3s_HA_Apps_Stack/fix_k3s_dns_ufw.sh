#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Correction DNS / UFW                                      ║"
echo "║    Autoriser DNS (port 53) pour les pods K3s                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

echo ""
echo "Correction DNS K3s - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: DIAGNOSTIC
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Diagnostic DNS                                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Test DNS depuis install-01 (host) :"
if nslookup pypi.org >/dev/null 2>&1; then
    echo -e "  ✓ Host peut résoudre les DNS externes : $OK"
else
    echo -e "  ✗ Host ne peut PAS résoudre : $KO"
    exit 1
fi

echo ""
echo "Test DNS depuis un pod K3s :"
echo "  (Test en cours...)"
TEST_RESULT=$(kubectl run test-dns --image=busybox --restart=Never --rm -i --quiet -- nslookup pypi.org 2>&1 || true)
if echo "$TEST_RESULT" | grep -q "Address:"; then
    echo -e "  ✓ Pods peuvent résoudre : $OK"
    echo -e "  $WARN DNS fonctionne déjà, aucune correction nécessaire"
    exit 0
else
    echo -e "  ✗ Pods ne peuvent PAS résoudre : $KO"
    echo "  Erreur : connection timed out (UFW bloque probablement)"
fi

echo ""
echo "Problème identifié :"
echo "  → UFW bloque les requêtes DNS (port 53) des pods K3s"
echo "  → Les pods ne peuvent pas atteindre CoreDNS (10.43.0.10:53)"
echo ""

read -p "Corriger les règles UFW pour autoriser DNS ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: CORRECTION UFW SUR TOUS LES NŒUDS K3S
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Correction UFW sur tous les nœuds K3s                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Récupérer tous les nœuds K3s
NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')

echo "Nœuds K3s détectés :"
for NODE_IP in $NODES; do
    NODE_NAME=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[] | select(.address==\"$NODE_IP\")) | .metadata.name")
    echo "  → $NODE_NAME ($NODE_IP)"
done

echo ""
echo "Application des règles UFW sur chaque nœud..."
echo ""

for NODE_IP in $NODES; do
    NODE_NAME=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[] | select(.address==\"$NODE_IP\")) | .metadata.name")
    
    echo "[$NODE_NAME] Configuration UFW..."
    
    ssh -o StrictHostKeyChecking=no root@"$NODE_IP" bash <<'EOF'
set -u
set -o pipefail

echo "  → Autorisation DNS pour réseau pods (10.42.0.0/16)"
ufw allow from 10.42.0.0/16 to any port 53 proto udp comment 'K3s Pods DNS UDP' 2>/dev/null || true
ufw allow from 10.42.0.0/16 to any port 53 proto tcp comment 'K3s Pods DNS TCP' 2>/dev/null || true

echo "  → Autorisation DNS pour réseau services (10.43.0.0/16)"
ufw allow from 10.43.0.0/16 to any port 53 proto udp comment 'K3s Services DNS UDP' 2>/dev/null || true
ufw allow from 10.43.0.0/16 to any port 53 proto tcp comment 'K3s Services DNS TCP' 2>/dev/null || true

echo "  → Reload UFW"
ufw reload 2>/dev/null || true

echo "  ✓ UFW configuré"
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $NODE_NAME configuré"
    else
        echo -e "  $KO Erreur sur $NODE_NAME"
    fi
    
    echo ""
done

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: REDÉMARRAGE COREDNS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Redémarrage CoreDNS                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Redémarrage de CoreDNS..."
kubectl rollout restart deployment/coredns -n kube-system

echo "Attente du redémarrage (30s)..."
sleep 30

kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=60s

echo -e "$OK CoreDNS redémarré"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: TESTS DE VALIDATION
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Tests de validation                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Test 1 : Résolution DNS interne (kubernetes.default)..."
TEST1=$(kubectl run test-dns-internal --image=busybox --restart=Never --rm -i --quiet -- nslookup kubernetes.default 2>&1 || true)
if echo "$TEST1" | grep -q "Address:"; then
    echo -e "  $OK DNS interne fonctionne"
else
    echo -e "  $KO DNS interne ne fonctionne PAS"
    echo "  $TEST1"
fi

echo ""
echo "Test 2 : Résolution DNS externe (pypi.org)..."
TEST2=$(kubectl run test-dns-external --image=busybox --restart=Never --rm -i --quiet -- nslookup pypi.org 2>&1 || true)
if echo "$TEST2" | grep -q "Address:"; then
    echo -e "  $OK DNS externe fonctionne"
else
    echo -e "  $KO DNS externe ne fonctionne PAS"
    echo "  $TEST2"
fi

echo ""
echo "Test 3 : Accès HTTP externe (test pip)..."
TEST3=$(kubectl run test-http --image=python:3.10-slim --restart=Never --rm -i --quiet -- python -c "import urllib.request; urllib.request.urlopen('https://pypi.org').read(); print('OK')" 2>&1 || true)
if echo "$TEST3" | grep -q "OK"; then
    echo -e "  $OK Accès HTTP externe fonctionne"
else
    echo -e "  $WARN Accès HTTP peut nécessiter plus de temps"
fi

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ RÉSUMÉ                                                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Règles UFW ajoutées sur tous les nœuds K3s :"
echo "  ✓ Port 53 UDP/TCP pour 10.42.0.0/16 (pods)"
echo "  ✓ Port 53 UDP/TCP pour 10.43.0.0/16 (services)"
echo ""

echo "Vérification finale :"
FINAL_TEST=$(kubectl run test-dns-final --image=busybox --restart=Never --rm -i --quiet -- nslookup pypi.org 2>&1 || true)
if echo "$FINAL_TEST" | grep -q "Address:"; then
    echo -e "$OK DNS K3S FONCTIONNE !"
    echo ""
    echo "Vous pouvez maintenant :"
    echo "  1. Redéployer Superset : ./13_deploy_superset_FIXED.sh"
    echo "  2. Vérifier Chatwoot : kubectl logs -n chatwoot chatwoot-web-xxx --tail=100"
    echo ""
else
    echo -e "$KO DNS ne fonctionne toujours pas"
    echo ""
    echo "Actions supplémentaires nécessaires :"
    echo "  1. Vérifier UFW status : ufw status"
    echo "  2. Vérifier les logs CoreDNS : kubectl logs -n kube-system -l k8s-app=kube-dns"
    echo "  3. Vérifier /etc/resolv.conf sur les nœuds"
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════════"
echo ""
