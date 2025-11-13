#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║            Logs des pods qui crashent encore                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

MASTER_IP="10.0.0.100"

echo ""
echo "═══ Chatwoot Web - Init container (NOUVEAU pod) ═══"
echo ""

CHATWOOT_WEB=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-web --sort-by=.metadata.creationTimestamp -o name | tail -n1")
echo "Pod : $CHATWOOT_WEB"
echo ""

ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_WEB -c db-migrate 2>&1 | tail -50"

echo ""
echo "═══ Chatwoot Worker qui crash (NOUVEAU pod) ═══"
echo ""

CHATWOOT_WORKER=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-worker -o json | jq -r '.items[] | select(.status.phase==\"Running\" | not) | .metadata.name' | head -n1")

if [ -n "$CHATWOOT_WORKER" ]; then
    echo "Pod : $CHATWOOT_WORKER"
    echo ""
    ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_WORKER 2>&1 | tail -50"
else
    echo "Aucun worker en erreur trouvé (bon signe !)"
fi

echo ""
echo "═══ Superset - Init container (NOUVEAU pod) ═══"
echo ""

SUPERSET_POD=$(ssh root@$MASTER_IP "kubectl get pods -n superset --sort-by=.metadata.creationTimestamp -o name | tail -n1")
echo "Pod : $SUPERSET_POD"
echo ""

ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-db 2>&1 | tail -50"

echo ""
echo "═══ Describe des pods en erreur (events K8s) ═══"
echo ""

echo "→ Chatwoot web :"
ssh root@$MASTER_IP "kubectl describe pod -n chatwoot -l app=chatwoot-web | grep -A 10 Events | head -15"

echo ""
echo "→ Superset :"
ssh root@$MASTER_IP "kubectl describe pod -n superset | grep -A 10 Events | head -15"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "FIN DU DIAGNOSTIC"
echo "═══════════════════════════════════════════════════════════════════"
