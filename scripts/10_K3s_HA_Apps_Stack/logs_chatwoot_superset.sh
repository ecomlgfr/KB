#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        Logs détaillés Chatwoot et Superset (init containers)      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

MASTER_IP="10.0.0.100"

echo ""
echo "═══ Chatwoot - Init container db-migrate ═══"
echo ""

# Prendre le pod le plus récent
CHATWOOT_POD=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-web --sort-by=.metadata.creationTimestamp -o name | tail -n1")

echo "Pod : $CHATWOOT_POD"
echo ""

ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_POD -c db-migrate --tail=50 2>&1"

echo ""
echo "═══ Chatwoot - Worker (main container) ═══"
echo ""

WORKER_POD=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-worker --sort-by=.metadata.creationTimestamp -o name | tail -n1")

echo "Pod : $WORKER_POD"
echo ""

ssh root@$MASTER_IP "kubectl logs -n chatwoot $WORKER_POD --tail=50 2>&1"

echo ""
echo "═══ Superset - Init container init-db ═══"
echo ""

SUPERSET_POD=$(ssh root@$MASTER_IP "kubectl get pods -n superset --sort-by=.metadata.creationTimestamp -o name | tail -n1")

echo "Pod : $SUPERSET_POD"
echo ""

ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-db --tail=50 2>&1"

echo ""
echo "═══ Vérification de la connexion Redis ═══"
echo ""

echo "Test depuis k3s-worker-01 :"
ssh root@10.0.0.110 "nc -zv 10.0.0.10 6379 2>&1"

echo ""
echo "═══ Vérification des variables d'environnement Chatwoot ═══"
echo ""

ssh root@$MASTER_IP bash <<'CHECK_ENV'
POD=$(kubectl get pods -n chatwoot -l app=chatwoot-web -o name | tail -n1)

echo "Variables POSTGRES_* :"
kubectl exec -n chatwoot $POD -c db-migrate -- env 2>/dev/null | grep POSTGRES || echo "Container pas encore démarré"

echo ""
echo "Variables REDIS_* :"
kubectl exec -n chatwoot $POD -c db-migrate -- env 2>/dev/null | grep REDIS || echo "Container pas encore démarré"
CHECK_ENV

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "FIN DU DIAGNOSTIC"
echo "═══════════════════════════════════════════════════════════════════"
