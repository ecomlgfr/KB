#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Correction Automatique - Ingress NGINX NodePorts               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

# Récupérer les NodePorts
HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)
HTTPS_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}'" 2>/dev/null)

echo ""
echo "NodePorts détectés :"
echo "  HTTP  : $HTTP_NODEPORT"
echo "  HTTPS : $HTTPS_NODEPORT"
echo ""
echo "Cette correction va :"
echo "  1. Vérifier kube-proxy sur chaque worker"
echo "  2. Redémarrer kube-proxy si nécessaire"
echo "  3. Vérifier les règles iptables"
echo "  4. Forcer la mise à jour des règles kube-proxy"
echo "  5. Redémarrer le service K3s si nécessaire"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CORRECTION DES WORKERS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    if [ -z "$ip" ]; then
        continue
    fi
    
    echo "→ $worker ($ip)"
    
    # Test rapide si le worker répond déjà
    if timeout 2 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "  $OK Worker déjà fonctionnel (skip)"
        echo ""
        continue
    fi
    
    echo "  ⚠️  Worker ne répond pas, correction en cours..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<EOF
set -u

echo "  [1/5] Vérification kube-proxy..."

# Vérifier si kube-proxy tourne
if ! crictl ps 2>/dev/null | grep -q kube-proxy; then
    echo "    ✗ kube-proxy absent, redémarrage K3s nécessaire"
    systemctl restart k3s-agent
    sleep 10
    echo "    ✓ K3s agent redémarré"
else
    echo "    ✓ kube-proxy présent"
fi

echo "  [2/5] Vérification règles iptables..."

# Vérifier les règles KUBE-NODEPORTS
if ! iptables -t nat -L KUBE-NODEPORTS -n 2>/dev/null | grep -q "$HTTP_NODEPORT"; then
    echo "    ✗ Règles iptables absentes"
    
    # Forcer kube-proxy à recréer les règles
    if crictl ps 2>/dev/null | grep -q kube-proxy; then
        KUBE_PROXY_ID=\$(crictl ps 2>/dev/null | grep kube-proxy | awk '{print \$1}')
        crictl stop \$KUBE_PROXY_ID 2>/dev/null || true
        sleep 5
        echo "    ✓ kube-proxy redémarré"
    fi
else
    echo "    ✓ Règles iptables présentes"
fi

echo "  [3/5] Vérification ports en écoute..."
sleep 5

if ss -tuln | grep -q ":$HTTP_NODEPORT "; then
    echo "    ✓ Port $HTTP_NODEPORT en écoute"
else
    echo "    ✗ Port $HTTP_NODEPORT pas encore en écoute"
    echo "    Attente 10s supplémentaires..."
    sleep 10
fi

echo "  [4/5] Test connexion locale..."

if timeout 3 bash -c "</dev/tcp/127.0.0.1/$HTTP_NODEPORT" 2>/dev/null; then
    echo "    ✓ Connexion locale OK"
else
    echo "    ✗ Connexion locale KO"
    
    # Dernier recours : flush iptables et redémarrer K3s
    echo "    Flush iptables et redémarrage K3s..."
    iptables -t nat -F KUBE-NODEPORTS 2>/dev/null || true
    systemctl restart k3s-agent
    sleep 15
    echo "    ✓ K3s agent redémarré (flush)"
fi

echo "  [5/5] Test final..."

if timeout 3 curl -s -o /dev/null http://127.0.0.1:$HTTP_NODEPORT/healthz --max-time 3 2>/dev/null; then
    echo "    ✓ /healthz accessible"
else
    echo "    ⚠️  /healthz pas encore accessible"
fi
EOF
    
    echo ""
    
    # Test final depuis install-01
    echo -n "  Test final depuis install-01 ... "
    sleep 2
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$WARN Attendre 30s de plus"
    fi
    
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ VÉRIFICATION FINALE ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 10s pour stabilisation..."
sleep 10

echo ""
echo "Test de connectivité sur tous les workers :"
echo ""

SUCCESS=0
FAILED=0

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker ($ip:$HTTP_NODEPORT) ... "
    
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
        ((FAILED++))
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Résultat : $SUCCESS/$((SUCCESS+FAILED)) workers fonctionnels"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ $SUCCESS -ge 3 ]; then
    echo -e "$OK Suffisant pour le Load Balancer (3/5 minimum)"
    echo ""
    echo "Prochaine étape :"
    echo "  1. Configurer le Load Balancer Hetzner"
    echo "  2. Tester les applications"
    echo ""
    exit 0
else
    echo -e "$KO Insuffisant pour le Load Balancer"
    echo ""
    echo "Actions recommandées :"
    echo ""
    echo "Pour les workers qui ne répondent toujours pas :"
    echo ""
    for worker in "${WORKER_NODES[@]}"; do
        ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
        
        if ! timeout 2 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
            echo "  $worker ($ip) :"
            echo "    ssh root@$ip"
            echo "    systemctl status k3s-agent"
            echo "    journalctl -u k3s-agent -n 50"
            echo "    crictl ps | grep kube-proxy"
            echo "    iptables -t nat -L KUBE-NODEPORTS -n"
            echo ""
        fi
    done
    
    exit 1
fi
