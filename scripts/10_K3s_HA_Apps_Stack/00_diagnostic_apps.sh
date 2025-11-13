#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic Apps K3S - CrashLoopBackOff                         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ État actuel des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep -v 'ingress'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Logs n8n (dernier pod en erreur) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

N8N_POD=$(kubectl get pods -n n8n -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$N8N_POD" ]; then
    echo "→ Pod : $N8N_POD"
    echo ""
    kubectl logs -n n8n "$N8N_POD" --tail=30 2>&1 | grep -A5 -B5 -iE '(error|fatal|crash|fail|refused|timeout)'
else
    echo "  ✗ Aucun pod n8n trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Logs litellm (dernier pod en erreur) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

LITELLM_POD=$(kubectl get pods -n litellm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$LITELLM_POD" ]; then
    echo "→ Pod : $LITELLM_POD"
    echo ""
    kubectl logs -n litellm "$LITELLM_POD" --tail=30 2>&1 | grep -A5 -B5 -iE '(error|fatal|crash|fail|refused|timeout)'
else
    echo "  ✗ Aucun pod litellm trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Logs chatwoot-web (dernier pod en erreur) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

CHATWOOT_POD=$(kubectl get pods -n chatwoot -l app=chatwoot,component=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$CHATWOOT_POD" ]; then
    echo "→ Pod : $CHATWOOT_POD"
    echo ""
    kubectl logs -n chatwoot "$CHATWOOT_POD" --tail=30 2>&1 | grep -A5 -B5 -iE '(error|fatal|crash|fail|refused|timeout)'
else
    echo "  ✗ Aucun pod chatwoot-web trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Vérification des secrets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Secrets n8n :"
kubectl get secret -n n8n n8n-secrets >/dev/null 2>&1 && echo -e "  $OK n8n-secrets existe" || echo -e "  $KO n8n-secrets manquant"

echo "→ Secrets litellm :"
kubectl get secret -n litellm litellm-secrets >/dev/null 2>&1 && echo -e "  $OK litellm-secrets existe" || echo -e "  $KO litellm-secrets manquant"

echo "→ Secrets chatwoot :"
kubectl get secret -n chatwoot chatwoot-secrets >/dev/null 2>&1 && echo -e "  $OK chatwoot-secrets existe" || echo -e "  $KO chatwoot-secrets manquant"

echo "→ Secrets superset :"
kubectl get secret -n superset superset-secrets >/dev/null 2>&1 && echo -e "  $OK superset-secrets existe" || echo -e "  $WARN superset-secrets manquant (normal si pas déployé)"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Test connectivité PostgreSQL depuis un pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Test depuis pod qdrant (qui fonctionne) :"
QDRANT_POD=$(kubectl get pods -n qdrant -o jsonpath='{.items[0].metadata.name}')
if [ -n "$QDRANT_POD" ]; then
    echo "  • Port 5432 (Patroni direct) :"
    kubectl exec -n qdrant "$QDRANT_POD" -- timeout 3 bash -c "cat < /dev/null > /dev/tcp/10.0.0.10/5432" 2>&1 && \
        echo -e "    $OK Port 5432 accessible" || \
        echo -e "    $KO Port 5432 bloqué"
    
    echo "  • Port 4632 (PgBouncer) :"
    kubectl exec -n qdrant "$QDRANT_POD" -- timeout 3 bash -c "cat < /dev/null > /dev/tcp/10.0.0.10/4632" 2>&1 && \
        echo -e "    $OK Port 4632 accessible" || \
        echo -e "    $KO Port 4632 bloqué"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Test connectivité Redis depuis un pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -n "$QDRANT_POD" ]; then
    echo "  • Port 6379 (Redis) :"
    kubectl exec -n qdrant "$QDRANT_POD" -- timeout 3 bash -c "cat < /dev/null > /dev/tcp/10.0.0.10/6379" 2>&1 && \
        echo -e "    $OK Port 6379 accessible" || \
        echo -e "    $KO Port 6379 bloqué"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Résumé ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods fonctionnels :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep 'Running' | wc -l | awk '{print "  ✓ " $1 " pods Running"}'

echo ""
echo "Pods en erreur :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep -E '(CrashLoopBackOff|Error)' | wc -l | awk '{print "  ✗ " $1 " pods CrashLoopBackOff/Error"}'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Prochaine étape :"
echo "  Analyser les logs ci-dessus et corriger les scripts"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
