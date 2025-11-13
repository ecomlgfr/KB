#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Nettoyage Final Monitoring                               ║"
echo "║    (Suppression pod Grafana en erreur + Stabilisation)            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script corrige :"
echo "  1. Suppression du pod Grafana en CrashLoopBackOff"
echo "  2. Vérification que le pod Grafana Running est OK"
echo "  3. Suppression de Loki (déploiement échoué)"
echo "  4. Test accès Grafana"
echo ""

read -p "Nettoyer et stabiliser le monitoring ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Suppression du pod Grafana en erreur ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Identifier le pod en CrashLoopBackOff
CRASH_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers | grep -E 'CrashLoop|Init:CrashLoop' | awk '{print $1}' | head -1)

if [ -n "$CRASH_POD" ]; then
    echo "Pod en erreur trouvé : $CRASH_POD"
    echo "Suppression forcée du pod..."
    kubectl delete pod -n monitoring $CRASH_POD --force --grace-period=0
    echo -e "$OK Pod en erreur supprimé"
else
    echo "Aucun pod Grafana en erreur trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Suppression du ReplicaSet orphelin ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Supprimer le ReplicaSet qui crée le pod en erreur
CRASH_RS=$(kubectl get rs -n monitoring -l app.kubernetes.io/name=grafana --no-headers | grep -E '648b4bdbdf' | awk '{print $1}')

if [ -n "$CRASH_RS" ]; then
    echo "ReplicaSet orphelin trouvé : $CRASH_RS"
    echo "Suppression du ReplicaSet..."
    kubectl delete rs -n monitoring $CRASH_RS
    echo -e "$OK ReplicaSet supprimé"
else
    echo "Aucun ReplicaSet orphelin trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Suppression ConfigMap Loki (inutile) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete configmap -n monitoring grafana-datasource-loki 2>/dev/null || echo "ConfigMap déjà absent"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Attente stabilisation (30s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification état des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods monitoring :"
kubectl get pods -n monitoring -o wide
echo ""

# Compter les pods Grafana
GRAFANA_RUNNING=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers | grep Running | wc -l)
GRAFANA_CRASH=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers | grep -E 'CrashLoop|Error' | wc -l)

echo "Pods Grafana Running : $GRAFANA_RUNNING"
echo "Pods Grafana en erreur : $GRAFANA_CRASH"
echo ""

if [ "$GRAFANA_RUNNING" -eq 1 ] && [ "$GRAFANA_CRASH" -eq 0 ]; then
    echo -e "  $OK État Grafana : OK (1 pod Running)"
else
    echo -e "  $WARN État Grafana : $GRAFANA_RUNNING Running, $GRAFANA_CRASH en erreur"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Test accès Grafana (direct) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

GRAFANA_SVC=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}')
echo "Service Grafana : $GRAFANA_SVC"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$GRAFANA_SVC --max-time 10 2>/dev/null || echo "000")
echo "Test HTTP direct : $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo -e "  $OK Grafana répond correctement"
else
    echo -e "  $WARN Grafana ne répond pas encore (code $HTTP_CODE)"
    echo "  Attente supplémentaire recommandée"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Vérification Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get ingress -n monitoring
echo ""

# Vérifier les endpoints
echo "Endpoints Grafana :"
kubectl get endpoints -n monitoring kube-prometheus-stack-grafana
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Test via Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test HTTP via Ingress..."
HTTP_INGRESS=$(curl -s -o /dev/null -w "%{http_code}" http://monitor.keybuzz.io --max-time 10 2>/dev/null || echo "000")
echo "Code HTTP : $HTTP_INGRESS"

if [ "$HTTP_INGRESS" = "200" ] || [ "$HTTP_INGRESS" = "302" ]; then
    echo -e "  $OK Accès Ingress OK"
elif [ "$HTTP_INGRESS" = "503" ] || [ "$HTTP_INGRESS" = "504" ]; then
    echo -e "  $WARN Ingress timeout/unavailable - Attendre 1-2 minutes"
else
    echo -e "  $WARN Code inattendu : $HTTP_INGRESS"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. Logs Grafana (dernières 20 lignes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers | grep Running | awk '{print $1}' | head -1)

if [ -n "$GRAFANA_POD" ]; then
    echo "Pod Grafana : $GRAFANA_POD"
    echo "Logs :"
    kubectl logs -n monitoring $GRAFANA_POD -c grafana --tail=20 2>/dev/null || echo "Pas de logs disponibles"
else
    echo "Aucun pod Grafana Running trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Nettoyage terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 État final :"
echo "  Prometheus : $(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers | grep Running | wc -l)/1 Running"
echo "  Alertmanager : $(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers | grep Running | wc -l)/1 Running"
echo "  Grafana : $GRAFANA_RUNNING/1 Running"
echo ""
echo "🔍 Accès Grafana :"
echo "  URL : http://monitor.keybuzz.io"
echo "  Username : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "⚠️  Si erreur 503/504 persiste :"
echo "  1. Attendre 2-3 minutes (Grafana initialisation)"
echo "  2. Vérifier les logs : kubectl logs -n monitoring $GRAFANA_POD -c grafana"
echo "  3. Redémarrer l'Ingress controller :"
echo "     kubectl rollout restart ds -n ingress-nginx ingress-nginx-controller"
echo ""
echo "📝 Note : Loki n'a pas été déployé (erreur de config)"
echo "   Vous avez uniquement Prometheus comme datasource."
echo "   C'est suffisant pour le monitoring K3s de base."
echo ""
echo "Prochaine étape :"
echo "  ./14_deploy_connect_api.sh"
echo ""

exit 0
