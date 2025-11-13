#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              Logs Chatwoot & Superset (pods en crash)             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

MASTER_IP="10.0.0.100"

echo ""
echo "═══ Chatwoot Web - Init container db-migrate ═══"
echo ""

CHATWOOT_WEB=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-web -o name | head -n1")

if [ -n "$CHATWOOT_WEB" ]; then
    echo "Pod : $CHATWOOT_WEB"
    echo ""
    ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_WEB -c db-migrate 2>&1 | tail -100"
else
    echo "Aucun pod Chatwoot Web trouvé"
fi

echo ""
echo "═══ Chatwoot Worker ═══"
echo ""

CHATWOOT_WORKER=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-worker -o name | head -n1")

if [ -n "$CHATWOOT_WORKER" ]; then
    echo "Pod : $CHATWOOT_WORKER"
    echo ""
    ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_WORKER 2>&1 | tail -100"
else
    echo "Aucun pod Chatwoot Worker trouvé"
fi

echo ""
echo "═══ Superset - Init container init-db ═══"
echo ""

SUPERSET_POD=$(ssh root@$MASTER_IP "kubectl get pods -n superset -o name | head -n1")

if [ -n "$SUPERSET_POD" ]; then
    echo "Pod : $SUPERSET_POD"
    echo ""
    ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-db 2>&1 | tail -100"
else
    echo "Aucun pod Superset trouvé"
fi

echo ""
echo "═══ Vérification connectivité réseau depuis un pod ═══"
echo ""

echo "Test depuis un pod n8n (qui fonctionne) :"
N8N_POD=$(ssh root@$MASTER_IP "kubectl get pods -n n8n -o name | head -n1")

if [ -n "$N8N_POD" ]; then
    echo ""
    echo "→ Résolution DNS chatwoot-config secret :"
    ssh root@$MASTER_IP "kubectl exec -n n8n $N8N_POD -- nslookup chatwoot-config.chatwoot.svc.cluster.local 2>&1 || echo 'DNS failed'"
    
    echo ""
    echo "→ Test connectivité PostgreSQL (10.0.0.10:5432) :"
    ssh root@$MASTER_IP "kubectl exec -n n8n $N8N_POD -- nc -zv 10.0.0.10 5432 2>&1 | head -5"
    
    echo ""
    echo "→ Test connectivité Redis (10.0.0.10:6379) :"
    ssh root@$MASTER_IP "kubectl exec -n n8n $N8N_POD -- nc -zv 10.0.0.10 6379 2>&1 | head -5"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "FIN DES LOGS"
echo "═══════════════════════════════════════════════════════════════════"
