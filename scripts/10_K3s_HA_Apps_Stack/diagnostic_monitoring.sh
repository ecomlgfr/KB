#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic Monitoring Stack                                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "1. État des pods"
echo "═══════════════════════════════════════════════════════════════════"
kubectl get pods -n monitoring -o wide

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "2. Pods en erreur - détails"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
CRASH_PODS=$(kubectl get pods -n monitoring --no-headers | grep -E 'CrashLoop|Error|Pending' | awk '{print $1}')

if [ -n "$CRASH_PODS" ]; then
    for pod in $CRASH_PODS; do
        echo "▶ Pod : $pod"
        kubectl describe pod -n monitoring $pod | grep -A 20 "Events:"
        echo ""
        echo "Logs du pod :"
        kubectl logs -n monitoring $pod --tail=50 2>&1 || echo "  Impossible de récupérer les logs"
        echo ""
        echo "────────────────────────────────────────────────────────────"
    done
else
    echo "Aucun pod en erreur"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "3. PVC Status"
echo "═══════════════════════════════════════════════════════════════════"
kubectl get pvc -n monitoring
echo ""

PVC_PENDING=$(kubectl get pvc -n monitoring --no-headers | grep Pending | awk '{print $1}')
if [ -n "$PVC_PENDING" ]; then
    echo "▶ PVC en Pending - détails :"
    for pvc in $PVC_PENDING; do
        echo "  PVC: $pvc"
        kubectl describe pvc -n monitoring $pvc | grep -A 10 "Events:"
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "4. Services et Endpoints"
echo "═══════════════════════════════════════════════════════════════════"
kubectl get svc -n monitoring
echo ""
kubectl get endpoints -n monitoring | grep grafana

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "5. Ingress Status"
echo "═══════════════════════════════════════════════════════════════════"
kubectl get ingress -n monitoring
echo ""
kubectl describe ingress -n monitoring | grep -A 10 "Events:"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "6. Test direct Grafana Service"
echo "═══════════════════════════════════════════════════════════════════"
GRAFANA_SVC=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -n "$GRAFANA_SVC" ]; then
    echo "Grafana ClusterIP : $GRAFANA_SVC"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$GRAFANA_SVC 2>/dev/null || echo "000")
    echo "Test HTTP direct : $HTTP_CODE"
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        echo -e "  Status : $OK"
        echo "  → Le service Grafana fonctionne"
        echo "  → Le problème vient probablement de l'Ingress"
    else
        echo -e "  Status : $KO"
        echo "  → Le service Grafana ne répond pas"
        echo "  → Vérifiez les logs du pod Grafana"
    fi
else
    echo -e "Service Grafana introuvable : $KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "7. Helm releases status"
echo "═══════════════════════════════════════════════════════════════════"
helm list -n monitoring

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "8. Stockage disponible sur les nœuds"
echo "═══════════════════════════════════════════════════════════════════"
kubectl get nodes -o custom-columns=NAME:.metadata.name,STORAGE:.status.allocatable.storage

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

TOTAL_PODS=$(kubectl get pods -n monitoring --no-headers | wc -l)
RUNNING_PODS=$(kubectl get pods -n monitoring --no-headers | grep Running | wc -l)
CRASH_COUNT=$(kubectl get pods -n monitoring --no-headers | grep -E 'CrashLoop|Error' | wc -l)
PENDING_PVC=$(kubectl get pvc -n monitoring --no-headers | grep Pending | wc -l)

echo "Pods : $RUNNING_PODS/$TOTAL_PODS Running"
echo "Pods en erreur : $CRASH_COUNT"
echo "PVC Pending : $PENDING_PVC"
echo ""

if [ "$CRASH_COUNT" -gt 0 ] || [ "$PENDING_PVC" -gt 0 ]; then
    echo -e "Status : $KO"
    echo ""
    echo "Actions recommandées :"
    if [ "$PENDING_PVC" -gt 0 ]; then
        echo "  1. PVC en Pending → Exécuter ./13_fix_monitoring_stack.sh"
        echo "     Le script supprimera les PVC problématiques et reconfigurera"
    fi
    if [ "$CRASH_COUNT" -gt 0 ]; then
        echo "  2. Pods en crash → Consulter les logs ci-dessus"
        echo "     kubectl logs -n monitoring <pod-name> --previous"
    fi
else
    echo -e "Status : $OK"
    echo "Tous les pods sont Running"
fi

echo ""
