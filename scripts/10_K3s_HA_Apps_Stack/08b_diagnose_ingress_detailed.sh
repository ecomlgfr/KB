#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic Approfondi - Ingress NGINX NodePorts                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État du déploiement Ingress NGINX ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Pods Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pods -n ingress-nginx -o wide"

echo ""
echo "→ Service Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller"

echo ""
echo "→ NodePorts détectés :"
HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)
HTTPS_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}'" 2>/dev/null)

echo "  HTTP  : $HTTP_NODEPORT"
echo "  HTTPS : $HTTPS_NODEPORT"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test des ports depuis chaque worker (interne) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    if [ -z "$ip" ]; then
        continue
    fi
    
    echo "→ $worker ($ip)"
    
    # Test depuis le worker lui-même
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<EOF
set -u

# Test si le port écoute localement
echo -n "  Écoute localhost:$HTTP_NODEPORT ... "
if ss -tuln | grep -q ":$HTTP_NODEPORT "; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test connexion locale
echo -n "  Connexion localhost:$HTTP_NODEPORT ... "
if timeout 3 bash -c "</dev/tcp/127.0.0.1/$HTTP_NODEPORT" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test curl /healthz
echo -n "  curl /healthz ... "
response=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$HTTP_NODEPORT/healthz --max-time 3 2>/dev/null)
if [ "\$response" = "200" ]; then
    echo -e "$OK (HTTP \$response)"
else
    echo -e "$WARN (HTTP \${response:-timeout})"
fi

# Vérifier iptables
echo -n "  Règles iptables ... "
if iptables -t nat -L -n | grep -q "$HTTP_NODEPORT"; then
    echo -e "$OK"
else
    echo -e "$WARN (pas de règle KUBE-NODEPORTS)"
fi

# Vérifier les processus qui écoutent sur le port
echo "  Processus écoutant :"
ss -tlnp | grep ":$HTTP_NODEPORT " || echo "    (aucun)"
EOF
    
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test de connectivité inter-workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tester depuis worker-02 (celui qui fonctionne) vers les autres
WORKER02_IP=$(awk -F'\t' '$2=="k3s-worker-02" {print $3}' "$SERVERS_TSV")

echo "Test depuis k3s-worker-02 ($WORKER02_IP) vers les autres workers :"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    [ "$worker" = "k3s-worker-02" ] && continue
    
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  → $worker ($ip:$HTTP_NODEPORT) ... "
    
    if ssh -o StrictHostKeyChecking=no root@"$WORKER02_IP" \
        "timeout 3 bash -c '</dev/tcp/$ip/$HTTP_NODEPORT'" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Vérification kube-proxy ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ État kube-proxy sur les workers :"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "$worker ... "
    
    # Vérifier si kube-proxy tourne
    ssh -o StrictHostKeyChecking=no root@"$ip" \
        "crictl ps 2>/dev/null | grep kube-proxy" &>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "$OK kube-proxy running"
    else
        echo -e "$KO kube-proxy absent"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification CNI / Réseau K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Configuration réseau K3s :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'EOF'
echo "Pod Network (Flannel) :"
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' | tr ' ' '\n'

echo ""
echo "Service Network :"
kubectl cluster-info dump | grep -E "service-cluster-ip-range" | head -n1
EOF

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Logs Ingress NGINX Controller ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Dernières lignes des logs Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=20"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC TERMINÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Analyse des résultats :"
echo ""
echo "1. Si 'Écoute localhost' KO sur un worker :"
echo "   → kube-proxy n'a pas créé les règles iptables"
echo "   → Redémarrer kube-proxy sur ce worker"
echo ""
echo "2. Si 'Écoute localhost' OK mais 'Connexion localhost' KO :"
echo "   → Problème de bind réseau ou pod Ingress absent"
echo "   → Vérifier que les pods Ingress tournent sur tous les workers"
echo ""
echo "3. Si test inter-workers KO :"
echo "   → Problème de routage réseau ou UFW"
echo "   → Vérifier UFW et routes"
echo ""
echo "4. Si kube-proxy absent :"
echo "   → Problème critique K3s"
echo "   → Redémarrer K3s sur le worker concerné"
echo ""
