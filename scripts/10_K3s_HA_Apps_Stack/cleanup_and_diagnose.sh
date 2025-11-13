#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         Nettoyage et diagnostic des nouveaux pods                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

MASTER_IP="10.0.0.100"

echo ""
echo "═══ 1. Suppression des ANCIENS pods en erreur ═══"
echo ""

ssh root@$MASTER_IP bash <<'CLEANUP'
set -u

# Supprimer tous les anciens replicasets pour forcer un redémarrage propre
echo "Suppression des anciens replicasets n8n..."
kubectl delete rs -n n8n $(kubectl get rs -n n8n -o name | grep -v "$(kubectl get deployment n8n -n n8n -o jsonpath='{.spec.selector.matchLabels.app}')" | head -n 2) --ignore-not-found

echo "Suppression des anciens replicasets chatwoot..."
kubectl delete rs -n chatwoot $(kubectl get rs -n chatwoot -o name | head -n 4) --ignore-not-found 2>/dev/null || true

echo "Suppression des anciens replicasets superset..."
kubectl delete rs -n superset $(kubectl get rs -n superset -o name | head -n 2) --ignore-not-found 2>/dev/null || true

echo ""
echo "Suppression forcée des pods en Error/CrashLoop..."
kubectl delete pods -n n8n --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
kubectl delete pods -n chatwoot --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
kubectl delete pods -n superset --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true

echo "✓ Nettoyage terminé"
CLEANUP

echo ""
echo "═══ 2. Attente de la création des nouveaux pods (15s) ═══"
sleep 15

echo ""
echo "═══ 3. État actuel ═══"
echo ""
ssh root@$MASTER_IP "kubectl get pods -n n8n -n chatwoot -n litellm -n superset"

echo ""
echo "═══ 4. Logs des NOUVEAUX pods ═══"
echo ""

echo "→ n8n (nouveau pod) :"
N8N_POD=$(ssh root@$MASTER_IP "kubectl get pods -n n8n --sort-by=.metadata.creationTimestamp -o name | tail -n1")
ssh root@$MASTER_IP "kubectl logs -n n8n $N8N_POD --tail=30 2>&1" | tail -30

echo ""
echo "→ Chatwoot web (nouveau pod - init container) :"
CHATWOOT_POD=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-web --sort-by=.metadata.creationTimestamp -o name | tail -n1")
ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_POD -c db-migrate --tail=30 2>&1" | tail -30

echo ""
echo "→ Chatwoot worker (nouveau pod) :"
WORKER_POD=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-worker --sort-by=.metadata.creationTimestamp -o name | tail -n1")
ssh root@$MASTER_IP "kubectl logs -n chatwoot $WORKER_POD --tail=30 2>&1" | tail -30

echo ""
echo "→ Superset (nouveau pod - init container) :"
SUPERSET_POD=$(ssh root@$MASTER_IP "kubectl get pods -n superset --sort-by=.metadata.creationTimestamp -o name | tail -n1")
ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-db --tail=30 2>&1" | tail -30

echo ""
echo "═══ 5. Vérification des secrets actuels ═══"
echo ""

echo "→ n8n DATABASE config :"
ssh root@$MASTER_IP "kubectl get secret n8n-config -n n8n -o json | jq -r '.data | to_entries[] | select(.key | startswith(\"DB_\")) | \"\\(.key)=\\(.value)\"' | head -n 5 | while read line; do key=\${line%%=*}; val=\${line#*=}; echo \"\$key=\$(echo \$val | base64 -d)\"; done"

echo ""
echo "→ chatwoot DATABASE config :"
ssh root@$MASTER_IP "kubectl get secret chatwoot-config -n chatwoot -o json | jq -r '.data | to_entries[] | select(.key | startswith(\"POSTGRES_\")) | \"\\(.key)=\\(.value)\"' | while read line; do key=\${line%%=*}; val=\${line#*=}; echo \"\$key=\$(echo \$val | base64 -d)\"; done"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "FIN DU DIAGNOSTIC"
echo "═══════════════════════════════════════════════════════════════════"
