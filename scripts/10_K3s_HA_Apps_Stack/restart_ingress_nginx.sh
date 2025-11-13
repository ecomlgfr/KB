#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Redémarrage Ingress NGINX Controller                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script :"
echo "  1. Redémarre l'Ingress NGINX DaemonSet"
echo "  2. Attend 60 secondes"
echo "  3. Teste l'accès Grafana"
echo ""
echo "⚠️  Cela va couper brièvement l'accès aux Ingress"
echo ""

read -p "Redémarrer l'Ingress NGINX ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Redémarrage Ingress NGINX ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl rollout restart daemonset -n ingress-nginx ingress-nginx-controller

echo ""
echo "Attente redémarrage (60 secondes)..."
sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Vérification pods Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -n ingress-nginx -o wide
echo ""

INGRESS_READY=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers | grep Running | wc -l)
echo "Pods Ingress Running : $INGRESS_READY/8"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test accès Grafana ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test 1 : Service Grafana (direct)"
GRAFANA_SVC=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}')
HTTP_SVC=$(curl -s -o /dev/null -w "%{http_code}" http://$GRAFANA_SVC --max-time 10 2>/dev/null || echo "000")
echo "  Code HTTP : $HTTP_SVC"

if [ "$HTTP_SVC" = "200" ] || [ "$HTTP_SVC" = "302" ]; then
    echo -e "  $OK Service Grafana répond"
else
    echo -e "  $WARN Service Grafana : code $HTTP_SVC"
fi

echo ""
echo "Test 2 : Via Ingress"
HTTP_INGRESS=$(curl -s -o /dev/null -w "%{http_code}" http://monitor.keybuzz.io --max-time 10 2>/dev/null || echo "000")
echo "  Code HTTP : $HTTP_INGRESS"

if [ "$HTTP_INGRESS" = "200" ] || [ "$HTTP_INGRESS" = "302" ]; then
    echo -e "  $OK Ingress OK - Grafana accessible"
elif [ "$HTTP_INGRESS" = "503" ] || [ "$HTTP_INGRESS" = "504" ]; then
    echo -e "  $WARN Encore timeout/unavailable"
else
    echo -e "  $WARN Code inattendu : $HTTP_INGRESS"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Vérification Endpoints ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Endpoints Grafana :"
kubectl get endpoints -n monitoring kube-prometheus-stack-grafana
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Redémarrage Ingress terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$HTTP_INGRESS" = "200" ] || [ "$HTTP_INGRESS" = "302" ]; then
    echo "✅ SUCCÈS - Grafana est accessible !"
    echo ""
    echo "🔍 Accès Grafana :"
    echo "  URL : http://monitor.keybuzz.io"
    echo "  Username : admin"
    echo "  Password : KeyBuzz2025!"
    echo ""
    echo "Prochaine étape :"
    echo "  ./14_deploy_connect_api.sh"
    echo ""
elif [ "$HTTP_SVC" = "200" ] || [ "$HTTP_SVC" = "302" ]; then
    echo "⚠️  Grafana répond mais Ingress timeout"
    echo ""
    echo "Le problème vient de l'Ingress, pas de Grafana."
    echo ""
    echo "Solutions :"
    echo ""
    echo "1. Attendre 2-3 minutes et re-tester :"
    echo "   curl -I http://monitor.keybuzz.io"
    echo ""
    echo "2. Vérifier les logs Ingress :"
    echo "   kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50"
    echo ""
    echo "3. Utiliser port-forward en attendant :"
    echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &"
    echo "   curl http://localhost:3000"
    echo ""
    echo "4. Accepter le monitoring via port-forward et continuer :"
    echo "   ./14_deploy_connect_api.sh"
    echo ""
else
    echo "❌ Grafana ne répond pas"
    echo ""
    echo "Diagnostic :"
    echo "  kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana --tail=50"
    echo ""
fi

echo ""

exit 0
