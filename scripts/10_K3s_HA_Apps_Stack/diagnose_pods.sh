#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              Diagnostic rapide des pods en erreur                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

MASTER_IP="10.0.0.100"

echo ""
echo "═══ n8n - Logs des pods en erreur ═══"
echo ""
ssh root@$MASTER_IP "kubectl logs -n n8n -l app=n8n --tail=30 --prefix=false" | head -30

echo ""
echo "═══ Chatwoot - Logs init container (db-migrate) ═══"
echo ""
POD=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-web -o name | head -n1")
ssh root@$MASTER_IP "kubectl logs -n chatwoot $POD -c db-migrate --tail=30" 2>&1 | head -30

echo ""
echo "═══ Superset - Logs init container (init-db) ═══"
echo ""
POD=$(ssh root@$MASTER_IP "kubectl get pods -n superset -l app=superset -o name | head -n1")
ssh root@$MASTER_IP "kubectl logs -n superset $POD -c init-db --tail=30" 2>&1 | head -30

echo ""
echo "═══ LiteLLM - Logs du pod en erreur ═══"
echo ""
POD=$(ssh root@$MASTER_IP "kubectl get pods -n litellm -l app=litellm -o json | jq -r '.items[] | select(.status.phase==\"Running\" | not) | .metadata.name' | head -n1")
if [ -n "$POD" ]; then
    ssh root@$MASTER_IP "kubectl logs -n litellm $POD --tail=30" 2>&1 | head -30
else
    echo "Aucun pod LiteLLM en erreur trouvé"
fi

echo ""
echo "═══ Vérification des secrets K8s ═══"
echo ""

echo "→ n8n secret :"
ssh root@$MASTER_IP "kubectl get secret n8n-config -n n8n -o jsonpath='{.data.DB_POSTGRESDB_HOST}' 2>&1 | base64 -d 2>/dev/null && echo ''"

echo "→ chatwoot secret :"
ssh root@$MASTER_IP "kubectl get secret chatwoot-config -n chatwoot -o jsonpath='{.data.POSTGRES_HOST}' 2>&1 | base64 -d 2>/dev/null && echo ''"

echo "→ superset secret :"
ssh root@$MASTER_IP "kubectl get secret superset-config -n superset -o jsonpath='{.data.DATABASE_HOST}' 2>&1 | base64 -d 2>/dev/null && echo ''"

echo ""
echo "═══ Test de connexion PostgreSQL depuis un worker ═══"
echo ""

WORKER_IP="10.0.0.110"
echo "Test depuis k3s-worker-01 ($WORKER_IP)..."
ssh root@$WORKER_IP "nc -zv 10.0.0.10 5432 2>&1" | grep -E "succeeded|failed"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "FIN DU DIAGNOSTIC"
echo "═══════════════════════════════════════════════════════════════════"
