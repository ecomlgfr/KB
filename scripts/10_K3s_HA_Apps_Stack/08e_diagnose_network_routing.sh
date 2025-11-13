#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic Réseau Inter-Workers (Flannel VXLAN)                ║"
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
echo "═══ 1. IP du pod Ingress NGINX ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

INGRESS_POD_IP=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.podIP}'" 2>/dev/null)

INGRESS_NODE=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].spec.nodeName}'" 2>/dev/null)

echo "Pod Ingress NGINX :"
echo "  IP   : $INGRESS_POD_IP"
echo "  Node : $INGRESS_NODE"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test de connectivité depuis chaque worker vers le pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "→ $worker ($ip)"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<EOF
set -u

# Test ping vers le pod
echo -n "  Ping $INGRESS_POD_IP ... "
if ping -c 1 -W 2 $INGRESS_POD_IP >/dev/null 2>&1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test curl HTTP vers le pod
echo -n "  curl http://$INGRESS_POD_IP/healthz ... "
response=\$(timeout 3 curl -s -o /dev/null -w '%{http_code}' http://$INGRESS_POD_IP/healthz 2>/dev/null)
if [ "\$response" = "200" ]; then
    echo -e "$OK (HTTP \$response)"
else
    echo -e "$WARN (HTTP \${response:-timeout})"
fi

# Vérifier l'interface flannel
echo -n "  Interface flannel.1 ... "
if ip link show flannel.1 >/dev/null 2>&1; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Vérifier les routes vers 10.42.0.0/16
echo -n "  Route vers 10.42.0.0/16 ... "
if ip route | grep -q "10.42."; then
    echo -e "$OK"
else
    echo -e "$KO"
fi
EOF
    
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test Service ClusterIP ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

SERVICE_IP=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'" 2>/dev/null)

echo "Service Ingress NGINX :"
echo "  ClusterIP : $SERVICE_IP"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker → curl http://$SERVICE_IP/healthz ... "
    
    response=$(ssh -o StrictHostKeyChecking=no root@"$ip" \
        "timeout 3 curl -s -o /dev/null -w '%{http_code}' http://$SERVICE_IP/healthz 2>/dev/null")
    
    if [ "$response" = "200" ]; then
        echo -e "$OK (HTTP $response)"
    else
        echo -e "$WARN (HTTP ${response:-timeout})"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Routes Flannel sur chaque worker ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "→ $worker ($ip)"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" "ip route | grep '10.42.'" || echo "  Aucune route 10.42.x.x"
    
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC TERMINÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Analyse :"
echo ""
echo "1. Si ping vers le pod KO :"
echo "   → Problème de routage réseau Flannel"
echo "   → Vérifier les interfaces flannel.1"
echo ""
echo "2. Si curl vers ClusterIP KO :"
echo "   → kube-proxy ne route pas correctement"
echo "   → Problème iptables"
echo ""
echo "3. Si tout est OK mais NodePort KO :"
echo "   → Utiliser DaemonSet pour avoir un pod sur chaque worker"
echo "   → ./08d_redeploy_ingress_daemonset.sh"
echo ""
