#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   Redémarrage Apps K3S après correction permissions               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script redémarre tous les DaemonSets pour appliquer les corrections"
echo ""

read -p "Redémarrer les apps ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Redémarrage des DaemonSets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Redémarrage n8n..."
kubectl rollout restart daemonset -n n8n n8n 2>/dev/null && echo -e "  $OK n8n redémarré" || echo -e "  $WARN n8n non trouvé"

echo "→ Redémarrage litellm..."
kubectl rollout restart daemonset -n litellm litellm 2>/dev/null && echo -e "  $OK litellm redémarré" || echo -e "  $WARN litellm non trouvé"

echo "→ Redémarrage chatwoot-web..."
kubectl rollout restart daemonset -n chatwoot chatwoot-web 2>/dev/null && echo -e "  $OK chatwoot-web redémarré" || echo -e "  $WARN chatwoot-web non trouvé"

echo "→ Redémarrage chatwoot-worker..."
kubectl rollout restart daemonset -n chatwoot chatwoot-worker 2>/dev/null && echo -e "  $OK chatwoot-worker redémarré" || echo -e "  $WARN chatwoot-worker non trouvé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Attente démarrage (120s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for i in {1..12}; do
    echo -n "."
    sleep 10
    
    if [ $((i % 6)) -eq 0 ]; then
        echo ""
        echo "État à $((i*10))s :"
        kubectl get pods -A | grep -E '(n8n|litellm|chatwoot)' | grep -v 'ingress' | awk '{print "  " $1 "/" $2 ": " $4}'
        echo ""
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ État final ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -v 'ingress'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Résumé ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

RUNNING=$(kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep 'Running' | wc -l)
CRASH=$(kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -E '(CrashLoopBackOff|Error)' | wc -l)

echo "  ✓ $RUNNING pods Running"
echo "  ✗ $CRASH pods CrashLoopBackOff/Error"

echo ""

if [ $CRASH -eq 0 ]; then
    echo -e "$OK Tous les pods sont fonctionnels !"
    echo ""
    echo "Applications accessibles :"
    echo "  • http://n8n.keybuzz.io"
    echo "  • http://llm.keybuzz.io"
    echo "  • http://qdrant.keybuzz.io"
    echo "  • http://chat.keybuzz.io"
else
    echo -e "$WARN Certains pods ont encore des problèmes"
    echo ""
    echo "Pour investiguer :"
    echo "  kubectl logs -n n8n <pod-name>"
    echo "  kubectl logs -n litellm <pod-name>"
    echo "  kubectl logs -n chatwoot <pod-name>"
fi

echo ""
