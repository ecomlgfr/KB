#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC RAPIDE - Services K3s KeyBuzz                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m!\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État des namespaces ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ns in n8n litellm qdrant chatwoot superset monitoring connect erp etl; do
    if kubectl get namespace $ns &>/dev/null; then
        PODS=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l)
        RUNNING=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep Running | wc -l)
        echo -e "  $ns : $OK ($RUNNING/$PODS Running)"
    else
        echo -e "  $ns : $KO (namespace manquant)"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Pods en échec ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

FAILED_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v Running | grep -v Completed)

if [ -z "$FAILED_PODS" ]; then
    echo -e "  $OK Aucun pod en échec"
else
    echo "NAMESPACE       POD                                    STATUS"
    echo "----------------------------------------------------------------"
    echo "$FAILED_PODS"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Diagnostic par service ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Connect API
echo "📱 CONNECT API (namespace: connect)"
CONNECT_PODS=$(kubectl get pods -n connect --no-headers 2>/dev/null | wc -l)
if [ "$CONNECT_PODS" -eq 0 ]; then
    echo -e "  $KO Aucun pod (namespace manquant ?)"
else
    CONNECT_STATUS=$(kubectl get pods -n connect --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c)
    echo "  Status: $CONNECT_STATUS"
    
    # Vérifier ImagePullBackOff
    if kubectl get pods -n connect 2>/dev/null | grep -q ImagePullBackOff; then
        echo -e "  $KO Image ghcr.io/keybuzz/connect:1.0.0 manquante"
        echo "      Solution: ./fix_01_connect_api_build_image.sh"
    fi
    
    # Test HTTP
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://connect.keybuzz.io/health --max-time 5 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
        echo -e "  $OK HTTP 200 OK"
    else
        echo -e "  $KO HTTP $HTTP"
    fi
fi
echo ""

# Grafana
echo "📊 GRAFANA (namespace: monitoring)"
GRAFANA_POD=$(kubectl get pods -n monitoring 2>/dev/null | grep grafana | grep -v exporter | head -1 | awk '{print $1}')
if [ -z "$GRAFANA_POD" ]; then
    echo -e "  $KO Aucun pod Grafana"
else
    GRAFANA_STATUS=$(kubectl get pod -n monitoring $GRAFANA_POD --no-headers 2>/dev/null | awk '{print $3}')
    echo "  Pod: $GRAFANA_POD"
    echo "  Status: $GRAFANA_STATUS"
    
    if echo "$GRAFANA_STATUS" | grep -q CrashLoopBackOff; then
        echo -e "  $KO Init container en CrashLoop"
        echo "      Solution: ./fix_02_grafana_simple.sh"
        
        # Voir les logs de l'init container
        INIT_LOGS=$(kubectl logs -n monitoring $GRAFANA_POD -c init-chown-data 2>&1 | tail -3)
        echo "      Logs: $INIT_LOGS"
    fi
    
    # Test HTTP
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://monitor.keybuzz.io --max-time 5 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
        echo -e "  $OK HTTP $HTTP OK"
    else
        echo -e "  $KO HTTP $HTTP"
    fi
fi
echo ""

# Airbyte
echo "🔄 AIRBYTE (namespace: etl)"
AIRBYTE_PODS=$(kubectl get pods -n etl --no-headers 2>/dev/null | wc -l)
if [ "$AIRBYTE_PODS" -eq 0 ]; then
    echo -e "  $KO Aucun pod (namespace manquant ?)"
else
    echo "  Total pods: $AIRBYTE_PODS"
    
    # Vérifier bootloader
    if kubectl get pods -n etl 2>/dev/null | grep -q "bootloader.*Error"; then
        echo -e "  $KO Bootloader en Error"
        echo "      Solution: ./fix_03_airbyte_simple.sh"
        
        # Logs du bootloader
        BOOTLOADER_LOGS=$(kubectl logs -n etl airbyte-airbyte-bootloader 2>&1 | tail -5)
        echo "      Logs: $BOOTLOADER_LOGS"
    fi
    
    # Vérifier webapp
    WEBAPP=$(kubectl get pods -n etl 2>/dev/null | grep webapp | wc -l)
    if [ "$WEBAPP" -eq 0 ]; then
        echo -e "  $WARN Webapp pas déployé (échec Helm ?)"
    else
        echo -e "  $OK Webapp présent"
    fi
    
    # Test HTTP
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://etl.keybuzz.io --max-time 5 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
        echo -e "  $OK HTTP $HTTP OK"
    else
        echo -e "  $KO HTTP $HTTP"
    fi
fi
echo ""

# Dolibarr
echo "💼 DOLIBARR (namespace: erp)"
DOLIBARR_PODS=$(kubectl get pods -n erp --no-headers 2>/dev/null | grep Running | wc -l)
DOLIBARR_TOTAL=$(kubectl get pods -n erp --no-headers 2>/dev/null | wc -l)
if [ "$DOLIBARR_TOTAL" -eq 0 ]; then
    echo -e "  $KO Aucun pod (namespace manquant ?)"
else
    echo "  Pods: $DOLIBARR_PODS/$DOLIBARR_TOTAL Running"
    
    # Test HTTP
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://my.keybuzz.io --max-time 10 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
        echo -e "  $OK HTTP $HTTP OK"
    elif [ "$HTTP" = "504" ]; then
        echo -e "  $KO HTTP 504 Gateway Timeout"
        echo "      Causes possibles:"
        echo "        - Initialisation DB lente"
        echo "        - Timeouts Ingress trop courts"
        echo "        - Connexion PgBouncer problématique"
        echo "      Solution: ./fix_04_dolibarr_timeout.sh"
    else
        echo -e "  $KO HTTP $HTTP"
    fi
    
    # Vérifier readiness
    READY=$(kubectl get pods -n erp --no-headers 2>/dev/null | awk '{print $2}')
    echo "  Ready: $READY"
fi
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ing in n8n.keybuzz.io llm.keybuzz.io qdrant.keybuzz.io chat.keybuzz.io \
           superset.keybuzz.io monitor.keybuzz.io connect.keybuzz.io \
           my.keybuzz.io etl.keybuzz.io; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://$ing --max-time 5 2>/dev/null || echo "000")
    
    if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
        echo -e "  $ing : $OK (HTTP $HTTP)"
    elif [ "$HTTP" = "503" ]; then
        echo -e "  $ing : $KO (HTTP 503 - Service Unavailable)"
    elif [ "$HTTP" = "504" ]; then
        echo -e "  $ing : $KO (HTTP 504 - Gateway Timeout)"
    else
        echo -e "  $ing : $WARN (HTTP $HTTP)"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Ressources ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ResourceQuotas
echo "ResourceQuotas :"
QUOTAS=$(kubectl get resourcequota -A --no-headers 2>/dev/null | wc -l)
echo "  Total: $QUOTAS"

# PodDisruptionBudgets
echo "PodDisruptionBudgets :"
PDB=$(kubectl get pdb -A --no-headers 2>/dev/null | wc -l)
echo "  Total: $PDB"

# HPA
echo "HorizontalPodAutoscalers :"
HPA=$(kubectl get hpa -A --no-headers 2>/dev/null | wc -l)
echo "  Total: $HPA"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. RECOMMANDATIONS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ISSUES=0

# Vérifier Connect API
if kubectl get pods -n connect 2>/dev/null | grep -q ImagePullBackOff; then
    echo -e "$KO Connect API : ImagePullBackOff"
    echo "   Exécuter: ./fix_01_connect_api_build_image.sh"
    ((ISSUES++))
fi

# Vérifier Grafana
if kubectl get pods -n monitoring 2>/dev/null | grep grafana | grep -q CrashLoopBackOff; then
    echo -e "$KO Grafana : CrashLoopBackOff"
    echo "   Exécuter: ./fix_02_grafana_simple.sh"
    ((ISSUES++))
fi

# Vérifier Airbyte
if kubectl get pods -n etl 2>/dev/null | grep -q "bootloader.*Error"; then
    echo -e "$KO Airbyte : Bootloader Error"
    echo "   Exécuter: ./fix_03_airbyte_simple.sh"
    ((ISSUES++))
fi

# Vérifier Dolibarr
HTTP_DOLI=$(curl -s -o /dev/null -w "%{http_code}" http://my.keybuzz.io --max-time 5 2>/dev/null || echo "000")
if [ "$HTTP_DOLI" = "504" ]; then
    echo -e "$KO Dolibarr : 504 Gateway Timeout"
    echo "   Exécuter: ./fix_04_dolibarr_timeout.sh"
    ((ISSUES++))
fi

if [ $ISSUES -eq 0 ]; then
    echo -e "$OK Aucun problème détecté !"
else
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "SOLUTION RAPIDE (tous les fixes en une fois) :"
    echo "  ./fix_00_all_in_one.sh"
    echo "═══════════════════════════════════════════════════════════════════"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "COMMANDES UTILES :"
echo "  kubectl get pods -A | grep -v Running"
echo "  kubectl describe pod -n <namespace> <pod-name>"
echo "  kubectl logs -n <namespace> <pod-name>"
echo "  kubectl logs -n <namespace> <pod-name> --previous"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

exit 0
