#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC COMPLET - Dolibarr Networking                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'

POD=$(kubectl get pod -n erp -l app=dolibarr -o name | head -1)
POD_NAME=$(basename $POD)

echo ""
echo "Pod : $POD_NAME"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État du pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pod -n erp $POD_NAME -o wide

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Service et Endpoints ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Service dolibarr :"
kubectl get svc -n erp dolibarr
echo ""

echo "Endpoints dolibarr :"
kubectl get endpoints -n erp dolibarr
echo ""

ENDPOINTS=$(kubectl get endpoints -n erp dolibarr -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
if [ -z "$ENDPOINTS" ]; then
    echo -e "$KO PAS D'ENDPOINTS - Le Service ne route pas vers le pod"
    echo ""
    echo "Raisons possibles :"
    echo "  1. Le pod n'est pas Ready"
    echo "  2. Les labels du Service ne matchent pas le pod"
    echo "  3. Les probes échouent"
    echo ""
    echo "Vérification labels :"
    echo "  Service selector :"
    kubectl get svc -n erp dolibarr -o jsonpath='{.spec.selector}' && echo ""
    echo "  Pod labels :"
    kubectl get pod -n erp $POD_NAME -o jsonpath='{.metadata.labels}' && echo ""
else
    echo -e "$OK Endpoints OK : $ENDPOINTS"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test HTTP depuis le pod lui-même ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test depuis le pod Dolibarr lui-même :"
kubectl exec -n erp $POD_NAME -- curl -I http://localhost:80 --max-time 5 2>&1 | head -10

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test HTTP depuis un autre pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

SVC_IP=$(kubectl get svc -n erp dolibarr -o jsonpath='{.spec.clusterIP}')
echo "Service ClusterIP : $SVC_IP"
echo ""

echo "Test depuis un pod temporaire :"
kubectl run test-dolibarr-http --image=curlimages/curl --restart=Never -n erp --rm -i -- \
  curl -I http://$SVC_IP:80 --max-time 10 2>&1 | head -15

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl describe ingress -n erp dolibarr-ingress | grep -A 20 "Rules:"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Test via Ingress depuis install-01 ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "curl -v http://my.keybuzz.io (30s timeout) :"
curl -v http://my.keybuzz.io --max-time 30 2>&1 | head -30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Logs Apache du pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl logs -n erp $POD_NAME --tail=20

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSUMÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -z "$ENDPOINTS" ]; then
    echo -e "$KO PROBLÈME : Pas d'Endpoints"
    echo "   Le Service ne peut pas router vers le pod"
    echo "   Le pod n'est probablement pas Ready"
else
    echo -e "$OK Endpoints OK"
fi

echo ""
echo "Test à faire manuellement :"
echo "  1. Depuis le nœud worker :"
echo "     NODE_IP=\$(kubectl get pod -n erp $POD_NAME -o jsonpath='{.status.hostIP}')"
echo "     POD_IP=\$(kubectl get pod -n erp $POD_NAME -o jsonpath='{.status.podIP}')"
echo "     ssh root@\$NODE_IP 'curl -I http://'\$POD_IP':80'"
echo ""
echo "  2. Port-forward direct :"
echo "     kubectl port-forward -n erp $POD_NAME 8090:80 &"
echo "     curl http://localhost:8090"
echo ""

exit 0
