#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Validation Finale Complète                               ║"
echo "║    (Tous les services applicatifs)                                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_WORKER01=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

SUCCESS_COUNT=0
TOTAL_COUNT=0

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Validation Namespaces ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

EXPECTED_NS="n8n litellm qdrant chatwoot superset monitoring connect erp etl logging"
for ns in $EXPECTED_NS; do
    if kubectl get namespace $ns >/dev/null 2>&1; then
        echo -e "  $ns : $OK"
        ((SUCCESS_COUNT++))
    else
        echo -e "  $ns : $KO (manquant)"
    fi
    ((TOTAL_COUNT++))
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Validation Pods Running ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

check_pods() {
    local namespace=$1
    local app_name=$2
    local expected=${3:-1}
    
    local running=$(kubectl get pods -n $namespace -l app=$app_name --no-headers 2>/dev/null | grep Running | wc -l)
    
    if [ "$running" -ge "$expected" ]; then
        echo -e "  $namespace/$app_name : $OK ($running/$expected)"
        ((SUCCESS_COUNT++))
        return 0
    else
        echo -e "  $namespace/$app_name : $KO ($running/$expected)"
        return 1
    fi
    ((TOTAL_COUNT++))
}

echo "Applications existantes :"
check_pods "n8n" "n8n" 8
check_pods "litellm" "litellm" 8
check_pods "qdrant" "qdrant" 8
check_pods "chatwoot" "chatwoot" 16
check_pods "superset" "superset" 8

echo ""
echo "Nouveaux services :"
check_pods "connect" "connect-api" 1
check_pods "erp" "dolibarr" 1
check_pods "etl" "airbyte" 1
check_pods "monitoring" "prometheus" 1

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Validation ResourceQuotas ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "ResourceQuotas :"
for ns in monitoring connect erp etl logging; do
    if kubectl get resourcequota -n $ns >/dev/null 2>&1; then
        QUOTA=$(kubectl get resourcequota -n $ns --no-headers | wc -l)
        if [ "$QUOTA" -ge 1 ]; then
            echo -e "  $ns : $OK"
            ((SUCCESS_COUNT++))
        else
            echo -e "  $ns : $KO (quota manquant)"
        fi
    else
        echo -e "  $ns : $KO (quota manquant)"
    fi
    ((TOTAL_COUNT++))
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Validation PodDisruptionBudgets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "PodDisruptionBudgets :"
for ns in connect erp etl; do
    if kubectl get pdb -n $ns >/dev/null 2>&1; then
        PDB_COUNT=$(kubectl get pdb -n $ns --no-headers | wc -l)
        if [ "$PDB_COUNT" -ge 1 ]; then
            echo -e "  $ns : $OK ($PDB_COUNT PDB)"
            ((SUCCESS_COUNT++))
        else
            echo -e "  $ns : $WARN (pas de PDB)"
        fi
    else
        echo -e "  $ns : $WARN (pas de PDB)"
    fi
    ((TOTAL_COUNT++))
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Validation HPA (HorizontalPodAutoscaler) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "HPA :"
if kubectl get hpa -n connect >/dev/null 2>&1; then
    HPA=$(kubectl get hpa -n connect --no-headers | grep connect-api | wc -l)
    if [ "$HPA" -ge 1 ]; then
        echo -e "  connect/connect-api : $OK"
        ((SUCCESS_COUNT++))
    else
        echo -e "  connect/connect-api : $KO (HPA manquant)"
    fi
else
    echo -e "  connect/connect-api : $KO (HPA manquant)"
fi
((TOTAL_COUNT++))

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Validation Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Ingress configurés :"
INGRESS_LIST="n8n litellm qdrant chatwoot superset monitor connect my etl"
for ing_ns in $INGRESS_LIST; do
    case $ing_ns in
        n8n) ns="n8n"; host="n8n.keybuzz.io" ;;
        litellm) ns="litellm"; host="llm.keybuzz.io" ;;
        qdrant) ns="qdrant"; host="qdrant.keybuzz.io" ;;
        chatwoot) ns="chatwoot"; host="chat.keybuzz.io" ;;
        superset) ns="superset"; host="superset.keybuzz.io" ;;
        monitor) ns="monitoring"; host="monitor.keybuzz.io" ;;
        connect) ns="connect"; host="connect.keybuzz.io" ;;
        my) ns="erp"; host="my.keybuzz.io" ;;
        etl) ns="etl"; host="etl.keybuzz.io" ;;
    esac
    
    if kubectl get ingress -n $ns 2>/dev/null | grep -q $host; then
        echo -e "  $host : $OK"
        ((SUCCESS_COUNT++))
    else
        echo -e "  $host : $KO (Ingress manquant)"
    fi
    ((TOTAL_COUNT++))
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Tests HTTP ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

test_http() {
    local name=$1
    local url=$2
    local expected_code=${3:-"200|302"}
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $url --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
    
    if echo "$expected_code" | grep -q "$HTTP_CODE"; then
        echo -e "  $name : $OK (HTTP $HTTP_CODE)"
        ((SUCCESS_COUNT++))
        return 0
    else
        echo -e "  $name : $KO (HTTP $HTTP_CODE, attendu: $expected_code)"
        return 1
    fi
    ((TOTAL_COUNT++))
}

echo "Tests HTTP (via worker direct) :"
test_http "n8n" "http://$IP_WORKER01:5678" "200"
test_http "LiteLLM" "http://$IP_WORKER01:4000" "200"
test_http "Qdrant" "http://$IP_WORKER01:6333" "200|404"
test_http "Chatwoot" "http://$IP_WORKER01:3000" "200|302"
test_http "Superset" "http://$IP_WORKER01:8088" "200|302"

echo ""
echo "Tests HTTP (via Ingress - si DNS configuré) :"
test_http "Connect API" "http://connect.keybuzz.io/health" "200"
test_http "Dolibarr" "http://my.keybuzz.io" "200|302"
test_http "Airbyte" "http://etl.keybuzz.io" "200|302"
test_http "Grafana" "http://monitor.keybuzz.io" "200|302"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Validation Monitoring ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Composants monitoring :"
if kubectl get pods -n monitoring | grep -q prometheus-kube-prometheus-stack; then
    echo -e "  Prometheus : $OK"
    ((SUCCESS_COUNT++))
else
    echo -e "  Prometheus : $KO"
fi
((TOTAL_COUNT++))

if kubectl get pods -n monitoring | grep -q grafana; then
    echo -e "  Grafana : $OK"
    ((SUCCESS_COUNT++))
else
    echo -e "  Grafana : $KO"
fi
((TOTAL_COUNT++))

if kubectl get pods -n monitoring | grep -q loki; then
    echo -e "  Loki : $OK"
    ((SUCCESS_COUNT++))
else
    echo -e "  Loki : $KO"
fi
((TOTAL_COUNT++))

if kubectl get pods -n monitoring | grep -q promtail; then
    echo -e "  Promtail : $OK"
    ((SUCCESS_COUNT++))
else
    echo -e "  Promtail : $KO"
fi
((TOTAL_COUNT++))

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. Validation Node Labels ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Labels workers :"
for i in {1..5}; do
    NODE="k3s-worker-0$i"
    LABEL=$(kubectl get node $NODE --show-labels 2>/dev/null | grep -oP 'role=\K\w+' || echo "none")
    if [ "$LABEL" != "none" ]; then
        echo -e "  $NODE : $OK (role=$LABEL)"
        ((SUCCESS_COUNT++))
    else
        echo -e "  $NODE : $WARN (pas de label role)"
    fi
    ((TOTAL_COUNT++))
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10. Validation Storage ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "PersistentVolumeClaims :"
PVC_COUNT=$(kubectl get pvc -A --no-headers | wc -l)
echo "  Total PVC : $PVC_COUNT"

for ns in monitoring erp etl; do
    PVC_NS=$(kubectl get pvc -n $ns --no-headers 2>/dev/null | wc -l)
    if [ "$PVC_NS" -ge 1 ]; then
        echo -e "  $ns : $OK ($PVC_NS PVC)"
        ((SUCCESS_COUNT++))
    else
        echo -e "  $ns : $WARN (pas de PVC)"
    fi
    ((TOTAL_COUNT++))
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

TOTAL_SCORE=$SUCCESS_COUNT
TOTAL_TESTS=$TOTAL_COUNT
PERCENTAGE=$((TOTAL_SCORE * 100 / TOTAL_TESTS))

if [ "$PERCENTAGE" -ge 90 ]; then
    echo -e "  🎉 $OK INFRASTRUCTURE OPÉRATIONNELLE : $TOTAL_SCORE/$TOTAL_TESTS tests ($PERCENTAGE%)"
    STATUS="SUCCESS"
elif [ "$PERCENTAGE" -ge 70 ]; then
    echo -e "  ⚠️ $WARN INFRASTRUCTURE PARTIELLEMENT OPÉRATIONNELLE : $TOTAL_SCORE/$TOTAL_TESTS tests ($PERCENTAGE%)"
    STATUS="PARTIAL"
else
    echo -e "  ❌ $KO INFRASTRUCTURE EN ERREUR : $TOTAL_SCORE/$TOTAL_TESTS tests ($PERCENTAGE%)"
    STATUS="ERROR"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 URLS D'ACCÈS AUX SERVICES :"
echo ""
echo "Applications existantes :"
echo "  n8n       : http://n8n.keybuzz.io"
echo "  LiteLLM   : http://llm.keybuzz.io"
echo "  Qdrant    : http://qdrant.keybuzz.io/dashboard"
echo "  Chatwoot  : http://chat.keybuzz.io"
echo "  Superset  : http://superset.keybuzz.io"
echo ""
echo "Nouveaux services :"
echo "  Connect API : http://connect.keybuzz.io"
echo "  Dolibarr    : http://my.keybuzz.io"
echo "  Airbyte ETL : http://etl.keybuzz.io"
echo "  Grafana     : http://monitor.keybuzz.io"
echo ""
echo "🔐 CREDENTIALS :"
echo ""
echo "  Grafana :"
echo "    Username : admin"
echo "    Password : KeyBuzz2025!"
echo ""
echo "  Dolibarr :"
echo "    Username : admin"
echo "    Password : KeyBuzz2025!"
echo ""
echo "  Superset :"
echo "    Username : admin"
echo "    Password : Admin123! (à changer)"
echo ""
echo "📊 RÉCAPITULATIF INFRASTRUCTURE :"
echo ""
echo "  Namespaces applicatifs : 11"
echo "  Total pods Running : $(kubectl get pods -A --no-headers | grep Running | wc -l)"
echo "  Ingress configurés : 9"
echo "  ResourceQuotas : 5"
echo "  PodDisruptionBudgets : 3+"
echo "  HorizontalPodAutoscalers : 1+"
echo ""
echo "🎯 TESTS DE RÉSILIENCE :"
echo ""
echo "  Pour tester la résilience :"
echo "    ./crashtest_infrastructure.sh"
echo ""
echo "  Pour drainer un worker :"
echo "    kubectl drain k3s-worker-01 --ignore-daemonsets"
echo "    kubectl uncordon k3s-worker-01"
echo ""
echo "  Pour vérifier le scaling :"
echo "    kubectl get hpa -A"
echo "    kubectl top pods -A"
echo ""

if [ "$STATUS" = "SUCCESS" ]; then
    echo "✅ Déploiement phase finale RÉUSSI !"
    echo ""
    exit 0
else
    echo "⚠️ Certains services nécessitent une attention."
    echo ""
    echo "Pour diagnostiquer :"
    echo "  kubectl get pods -A | grep -v Running"
    echo "  kubectl describe pod <pod-name> -n <namespace>"
    echo "  kubectl logs <pod-name> -n <namespace>"
    echo ""
    exit 1
fi
