#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Fix RADICAL Grafana Deployment                           ║"
echo "║    (Suppression et recréation propre)                             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script fait :"
echo "  1. Scale Deployment Grafana à 0"
echo "  2. Suppression TOUS les ReplicaSets Grafana"
echo "  3. Scale Deployment Grafana à 1"
echo "  4. Attente stabilisation"
echo "  5. Test accès"
echo ""

read -p "Appliquer le fix radical ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Scale Deployment Grafana à 0 ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl scale deployment -n monitoring kube-prometheus-stack-grafana --replicas=0

echo "Attente 10 secondes..."
sleep 10

echo ""
echo "Vérification pods Grafana (doit être vide) :"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
echo ""

echo -e "$OK Deployment scalé à 0"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Suppression TOUS les ReplicaSets Grafana ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Liste des ReplicaSets Grafana :"
kubectl get rs -n monitoring -l app.kubernetes.io/name=grafana
echo ""

echo "Suppression de tous les ReplicaSets Grafana..."
kubectl delete rs -n monitoring -l app.kubernetes.io/name=grafana --all

echo ""
echo "Attente 10 secondes..."
sleep 10

echo -e "$OK Tous les ReplicaSets supprimés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Scale Deployment Grafana à 1 ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl scale deployment -n monitoring kube-prometheus-stack-grafana --replicas=1

echo ""
echo "Attente création du pod (30 secondes)..."
sleep 30

echo ""
echo "État des pods Grafana :"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
echo ""

echo -e "$OK Deployment scalé à 1"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Attente stabilisation complète (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente que Grafana soit complètement prêt..."
sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification finale ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Tous les pods monitoring :"
kubectl get pods -n monitoring
echo ""

# Compter les pods Grafana
GRAFANA_RUNNING=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers | grep Running | wc -l)
GRAFANA_TOTAL=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers | wc -l)

echo "Pods Grafana : $GRAFANA_RUNNING Running / $GRAFANA_TOTAL Total"

if [ "$GRAFANA_RUNNING" -eq 1 ] && [ "$GRAFANA_TOTAL" -eq 1 ]; then
    echo -e "  $OK UN SEUL pod Grafana Running"
else
    echo -e "  $WARN Problème : $GRAFANA_TOTAL pods au lieu d'1"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Test accès Grafana ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Test direct
GRAFANA_SVC=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}')
echo "Service Grafana : $GRAFANA_SVC"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$GRAFANA_SVC --max-time 10 2>/dev/null || echo "000")
echo "Test HTTP direct : $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo -e "  $OK Grafana répond"
else
    echo -e "  $WARN Grafana : code $HTTP_CODE"
fi

echo ""
# Test Ingress
echo "Test via Ingress..."
HTTP_INGRESS=$(curl -s -o /dev/null -w "%{http_code}" http://monitor.keybuzz.io --max-time 10 2>/dev/null || echo "000")
echo "Code HTTP Ingress : $HTTP_INGRESS"

if [ "$HTTP_INGRESS" = "200" ] || [ "$HTTP_INGRESS" = "302" ]; then
    echo -e "  $OK Ingress OK"
elif [ "$HTTP_INGRESS" = "503" ] || [ "$HTTP_INGRESS" = "504" ]; then
    echo -e "  $WARN Timeout Ingress - Redémarrage recommandé"
else
    echo -e "  $WARN Code : $HTTP_INGRESS"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Fix radical terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Résumé :"
echo "  - Deployment Grafana : 1 replica"
echo "  - Pods Grafana : $GRAFANA_RUNNING/$GRAFANA_TOTAL"
echo "  - Service direct : HTTP $HTTP_CODE"
echo "  - Ingress : HTTP $HTTP_INGRESS"
echo ""

if [ "$HTTP_INGRESS" = "503" ] || [ "$HTTP_INGRESS" = "504" ]; then
    echo "⚠️  L'Ingress ne répond pas correctement."
    echo ""
    echo "Solution 1 : Redémarrer l'Ingress controller"
    echo "  kubectl rollout restart daemonset -n ingress-nginx ingress-nginx-controller"
    echo "  sleep 60"
    echo "  curl -I http://monitor.keybuzz.io"
    echo ""
    echo "Solution 2 : Utiliser port-forward"
    echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
    echo "  Ouvrir : http://localhost:3000"
    echo ""
elif [ "$HTTP_INGRESS" = "200" ] || [ "$HTTP_INGRESS" = "302" ]; then
    echo "✅ Grafana est accessible !"
    echo ""
    echo "🔍 Accès Grafana :"
    echo "  URL : http://monitor.keybuzz.io"
    echo "  Username : admin"
    echo "  Password : KeyBuzz2025!"
    echo ""
    echo "Prochaine étape :"
    echo "  ./14_deploy_connect_api.sh"
else
    echo "⚠️  Attendre 2-3 minutes supplémentaires et re-tester :"
    echo "  curl -I http://monitor.keybuzz.io"
fi

echo ""

exit 0
