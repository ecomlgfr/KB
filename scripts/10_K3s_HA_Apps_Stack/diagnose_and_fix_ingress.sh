#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Script: diagnose_and_fix_ingress.sh
# Description: Diagnostic approfondi et correction des timeouts Ingress
# Date: 2025-11-17
###############################################################################

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Auto-détection kubeconfig
KUBECONFIG_LOCATIONS=(
    "${KUBECONFIG:-}"
    "/opt/keybuzz-installer/credentials/k3s.yaml"
    "/etc/rancher/k3s/k3s.yaml"
    "$HOME/.kube/config"
)

for kubeconfig_path in "${KUBECONFIG_LOCATIONS[@]}"; do
    if [ -n "$kubeconfig_path" ] && [ -f "$kubeconfig_path" ]; then
        if KUBECONFIG="$kubeconfig_path" kubectl version --client &>/dev/null; then
            export KUBECONFIG="$kubeconfig_path"
            break
        fi
    fi
done

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         DIAGNOSTIC APPROFONDI - INGRESS & SERVICES                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# 1. DIAGNOSTIC DES PODS
###############################################################################
log "${INFO} === PHASE 1: ÉTAT DES PODS ==="

log "${INFO} ERPNext socketio:"
kubectl get pods -n erpnext -l component=socketio -o wide

log "${INFO} Logs socketio (dernières 10 lignes):"
kubectl logs -n erpnext -l component=socketio --tail=10 2>&1 || echo "Pod en crash"

log "${INFO} Grafana:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o wide

log "${INFO} Connect API:"
kubectl get pods -n connect -l app=connect-api -o wide 2>/dev/null || \
kubectl get pods -n connect-api -l app=connect-api -o wide 2>/dev/null || \
log "${WARN} Namespace Connect non trouvé"

###############################################################################
# 2. DIAGNOSTIC DES SERVICES
###############################################################################
log "${INFO} === PHASE 2: ÉTAT DES SERVICES ==="

log "${INFO} Service Grafana:"
kubectl get svc -n monitoring kube-prometheus-stack-grafana -o wide 2>/dev/null || \
kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o wide

log "${INFO} Service Connect API:"
kubectl get svc -n connect connect-api -o wide 2>/dev/null || \
kubectl get svc -n connect-api connect-api -o wide 2>/dev/null || \
log "${WARN} Service Connect non trouvé"

log "${INFO} Service ERPNext:"
kubectl get svc -n erpnext erpnext -o wide

###############################################################################
# 3. DIAGNOSTIC DES INGRESS
###############################################################################
log "${INFO} === PHASE 3: ÉTAT DES INGRESS ==="

log "${INFO} Ingress Grafana (tous):"
kubectl get ingress -n monitoring -o wide

log "${INFO} Annotations Ingress Grafana:"
kubectl get ingress -n monitoring grafana-ingress -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq '.' || \
kubectl get ingress -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq '.'

log "${INFO} Ingress Connect (tous):"
kubectl get ingress -n connect -o wide 2>/dev/null || kubectl get ingress -n connect-api -o wide 2>/dev/null

log "${INFO} Annotations Ingress Connect:"
kubectl get ingress -n connect connect-ingress -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq '.' || \
kubectl get ingress -n connect connect-api -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq '.'

log "${INFO} Ingress ERPNext:"
kubectl get ingress -n erpnext -o wide

log "${INFO} Annotations Ingress ERPNext:"
kubectl get ingress -n erpnext erpnext -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq '.'

###############################################################################
# 4. TEST DE CONNECTIVITÉ INTERNE
###############################################################################
log "${INFO} === PHASE 4: TEST DE CONNECTIVITÉ INTERNE ==="

log "${INFO} Test depuis un pod worker vers Grafana service:"
GRAFANA_SVC=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}' 2>/dev/null || \
              kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
if [ -n "$GRAFANA_SVC" ]; then
    log "  Service IP Grafana: $GRAFANA_SVC"
    kubectl run test-curl-grafana --image=curlimages/curl:latest --rm -i --restart=Never -- \
        curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
        "http://$GRAFANA_SVC:80" 2>/dev/null || log "${WARN} Test échoué"
fi

log "${INFO} Test depuis un pod worker vers Connect API service:"
CONNECT_SVC=$(kubectl get svc -n connect connect-api -o jsonpath='{.spec.clusterIP}' 2>/dev/null || \
              kubectl get svc -n connect-api connect-api -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$CONNECT_SVC" ]; then
    log "  Service IP Connect: $CONNECT_SVC"
    kubectl run test-curl-connect --image=curlimages/curl:latest --rm -i --restart=Never -- \
        curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
        "http://$CONNECT_SVC:3000" 2>/dev/null || log "${WARN} Test échoué"
fi

log "${INFO} Test depuis un pod worker vers ERPNext service:"
ERPNEXT_SVC=$(kubectl get svc -n erpnext erpnext -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$ERPNEXT_SVC" ]; then
    log "  Service IP ERPNext: $ERPNEXT_SVC"
    kubectl run test-curl-erpnext --image=curlimages/curl:latest --rm -i --restart=Never -- \
        curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
        "http://$ERPNEXT_SVC:8000" 2>/dev/null || log "${WARN} Test échoué"
fi

###############################################################################
# 5. CORRECTION DES INGRESS
###############################################################################
log "${INFO} === PHASE 5: CORRECTION DES INGRESS ==="

# Supprimer les doublons si présents
log "${INFO} Suppression des Ingress en double créés par erreur..."
kubectl delete ingress kube-prometheus-stack-grafana -n monitoring 2>/dev/null && \
    log "${OK} Ingress kube-prometheus-stack-grafana supprimé" || \
    log "${INFO} Pas de doublon kube-prometheus-stack-grafana"

kubectl delete ingress connect-api -n connect 2>/dev/null && \
    log "${OK} Ingress connect-api supprimé du namespace connect" || \
    log "${INFO} Pas de doublon connect-api"

# Patcher Grafana
log "${INFO} Patch Ingress Grafana (grafana-ingress)..."
kubectl patch ingress grafana-ingress -n monitoring --type=merge -p '{
  "metadata": {
    "annotations": {
      "nginx.ingress.kubernetes.io/proxy-connect-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-send-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-read-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-body-size": "50m"
    }
  }
}' 2>/dev/null && log "${OK} Grafana patché" || log "${WARN} Échec patch Grafana"

# Patcher Connect API
log "${INFO} Patch Ingress Connect API (connect-ingress)..."
kubectl patch ingress connect-ingress -n connect --type=merge -p '{
  "metadata": {
    "annotations": {
      "nginx.ingress.kubernetes.io/proxy-connect-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-send-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-read-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-body-size": "50m"
    }
  }
}' 2>/dev/null && log "${OK} Connect API patché" || log "${WARN} Échec patch Connect"

# Patcher ERPNext
log "${INFO} Patch Ingress ERPNext..."
kubectl patch ingress erpnext -n erpnext --type=merge -p '{
  "metadata": {
    "annotations": {
      "nginx.ingress.kubernetes.io/proxy-connect-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-send-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-read-timeout": "600",
      "nginx.ingress.kubernetes.io/proxy-body-size": "50m"
    }
  }
}' 2>/dev/null && log "${OK} ERPNext patché" || log "${WARN} Échec patch ERPNext"

###############################################################################
# 6. REDÉMARRAGE DES PODS SI NÉCESSAIRE
###############################################################################
log "${INFO} === PHASE 6: REDÉMARRAGE DES PODS ==="

# Vérifier ERPNext socketio
SOCKETIO_RESTARTS=$(kubectl get pods -n erpnext -l component=socketio -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "$SOCKETIO_RESTARTS" -gt 2000 ]; then
    log "${WARN} ERPNext socketio a $SOCKETIO_RESTARTS restarts, redémarrage du deployment..."
    kubectl rollout restart deployment -n erpnext -l component=socketio 2>/dev/null || \
        log "${WARN} Impossible de redémarrer socketio"
fi

# Redémarrer Grafana pour prendre en compte les changements
log "${INFO} Redémarrage de Grafana..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana 2>/dev/null || \
kubectl rollout restart deployment -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null || \
log "${WARN} Impossible de redémarrer Grafana"

###############################################################################
# 7. VÉRIFICATION DU CONTROLLER INGRESS
###############################################################################
log "${INFO} === PHASE 7: ÉTAT DU CONTROLLER INGRESS ==="

log "${INFO} Pods Ingress NGINX:"
kubectl get pods -n ingress-nginx -o wide

log "${INFO} Logs Ingress Controller (dernières 20 lignes):"
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20 | grep -E "(error|Error|timeout|Timeout|504)" || \
    log "${OK} Pas d'erreur visible dans les logs"

###############################################################################
# 8. ATTENTE ET TESTS FINAUX
###############################################################################
log "${INFO} === PHASE 8: TESTS FINAUX ==="
log "${INFO} Attente de 30 secondes pour propagation..."
sleep 30

log "${INFO} Test des URLs:"
for url in "https://monitor.keybuzz.io" "https://connect.keybuzz.io" "https://erp.keybuzz.io"; do
    log "  Test $url:"
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 20 "$url" 2>/dev/null || echo "TIMEOUT")
    log "    HTTP $HTTP_CODE"
done

echo ""
log "${OK} Diagnostic terminé"
log "${INFO} Vérifiez les résultats ci-dessus pour identifier les problèmes restants"
