#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC POD PENDING - Dolibarr                              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État du pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -n erp -l app=dolibarr -o wide

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Events du pod (RAISON DU PENDING) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

POD=$(kubectl get pod -n erp -l app=dolibarr -o name | head -1)
if [ -n "$POD" ]; then
    echo "Events du pod (30 derniers) :"
    kubectl describe $POD -n erp | grep -A 30 "Events:"
else
    echo "Aucun pod trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. État du PVC dolibarr-documents ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pvc -n erp dolibarr-documents -o wide

echo ""
echo "Détails du PVC :"
kubectl describe pvc -n erp dolibarr-documents | grep -E "Status|Volume|Used By"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Nodes avec label role=apps ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Nodes avec role=apps :"
kubectl get nodes -l role=apps --no-headers
NODES_APPS=$(kubectl get nodes -l role=apps --no-headers | wc -l)
echo "Total : $NODES_APPS nodes"

echo ""
echo "Détails des nodes role=apps :"
kubectl describe nodes -l role=apps | grep -E "Name:|Taints:|Allocatable:|Allocated resources:"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Resources disponibles sur workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl top nodes -l role=apps 2>/dev/null || echo "Metrics non disponibles"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ SOLUTION ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Vérifier le problème le plus courant : PVC attaché
USED_BY=$(kubectl get pvc -n erp dolibarr-documents -o jsonpath='{.status.phase}')
echo "PVC Status : $USED_BY"

if [ "$USED_BY" = "Bound" ]; then
    echo -e "$OK PVC Bound - OK"
    echo ""
    echo "Problème probable : PVC déjà attaché à un ancien pod"
    echo ""
    echo "SOLUTION 1 : Supprimer tous les pods Dolibarr"
    echo "  kubectl delete pods -n erp -l app=dolibarr --grace-period=0 --force"
    echo "  sleep 30"
    echo "  kubectl get pods -n erp -l app=dolibarr"
    echo ""
    echo "SOLUTION 2 : Si SOLUTION 1 échoue, supprimer le PVC et recréer"
    echo "  kubectl delete pvc -n erp dolibarr-documents"
    echo "  kubectl delete deployment -n erp dolibarr"
    echo "  # Attendre 30s"
    echo "  # Relancer ./fix_dolibarr_simple.sh"
else
    echo -e "$KO PVC pas Bound"
fi

echo ""
echo "SOLUTION 3 : Enlever le volume (temporaire pour debug)"
echo "  kubectl edit deployment -n erp dolibarr"
echo "  # Commenter les sections volumes et volumeMounts"
echo "  # Sauvegarder et sortir"
echo ""

exit 0
