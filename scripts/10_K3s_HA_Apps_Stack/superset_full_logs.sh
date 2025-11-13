#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           Logs détaillés Superset (dernière investigation)        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

MASTER_IP="10.0.0.100"

echo ""
echo "═══ Récupération du pod Superset le plus récent ═══"
echo ""

SUPERSET_POD=$(ssh root@$MASTER_IP "kubectl get pods -n superset -o json | jq -r '.items[] | select(.metadata.name | contains(\"7795fbd7dd\")) | .metadata.name' | head -n1")

if [ -z "$SUPERSET_POD" ]; then
    echo "Aucun pod Superset trouvé"
    exit 1
fi

echo "Pod : $SUPERSET_POD"
echo ""

echo "═══ État du pod ═══"
echo ""
ssh root@$MASTER_IP "kubectl get pod $SUPERSET_POD -n superset -o wide"

echo ""
echo "═══ Describe pod (événements) ═══"
echo ""
ssh root@$MASTER_IP "kubectl describe pod $SUPERSET_POD -n superset | grep -A 30 Events"

echo ""
echo "═══ Logs init-db ═══"
echo ""
ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-db 2>&1 | tail -100"

echo ""
echo "═══ Logs init-admin ═══"
echo ""
ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-admin 2>&1 | tail -100"

echo ""
echo "═══ Logs container principal (CRITIQUE) ═══"
echo ""
ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c superset 2>&1 | tail -150"

echo ""
echo "═══ Status des containers ═══"
echo ""
ssh root@$MASTER_IP "kubectl get pod $SUPERSET_POD -n superset -o jsonpath='{.status.containerStatuses}' | jq ."

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "FIN DES LOGS"
echo "═══════════════════════════════════════════════════════════════════"
