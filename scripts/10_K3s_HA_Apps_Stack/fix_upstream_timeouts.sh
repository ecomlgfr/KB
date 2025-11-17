#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Script: fix_upstream_timeouts.sh
# Description: Fix upstream connection timeouts pour Ingress NGINX
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
echo "║    CORRECTION TIMEOUTS UPSTREAM - INGRESS NGINX                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# 1. DIAGNOSTIC DES PODS BACKEND
###############################################################################
log "${INFO} === PHASE 1: VÉRIFICATION DES PODS BACKEND ==="

log "${INFO} État des pods ERPNext:"
kubectl get pods -n erpnext -o wide

log "${INFO} État des pods Grafana:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o wide

log "${INFO} État des pods Connect API:"
kubectl get pods -n connect -l app=connect-api -o wide

###############################################################################
# 2. VÉRIFICATION DES SERVICES
###############################################################################
log "${INFO} === PHASE 2: VÉRIFICATION DES SERVICES ==="

log "${INFO} Service ERPNext (doit pointer vers le bon port):"
kubectl get svc -n erpnext erpnext -o yaml | grep -A 5 "ports:"

log "${INFO} Endpoints ERPNext (doit avoir des IPs de pods):"
kubectl get endpoints -n erpnext erpnext

log "${INFO} Endpoints Grafana:"
kubectl get endpoints -n monitoring kube-prometheus-stack-grafana

log "${INFO} Endpoints Connect API:"
kubectl get endpoints -n connect connect-api

###############################################################################
# 3. CORRECTION DES ANNOTATIONS INGRESS (UPSTREAM TIMEOUTS)
###############################################################################
log "${INFO} === PHASE 3: CORRECTION DES TIMEOUTS UPSTREAM ==="

log "${INFO} Patch Ingress Grafana avec timeouts upstream..."
kubectl annotate ingress grafana-ingress -n monitoring \
    nginx.ingress.kubernetes.io/proxy-connect-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-send-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-read-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-next-upstream-timeout="600" \
    nginx.ingress.kubernetes.io/upstream-vhost="monitor.keybuzz.io" \
    --overwrite

log "${OK} Grafana patché"

log "${INFO} Patch Ingress Connect API avec timeouts upstream..."
kubectl annotate ingress connect-ingress -n connect \
    nginx.ingress.kubernetes.io/proxy-connect-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-send-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-read-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-next-upstream-timeout="600" \
    nginx.ingress.kubernetes.io/upstream-vhost="connect.keybuzz.io" \
    --overwrite

log "${OK} Connect API patché"

log "${INFO} Patch Ingress ERPNext avec timeouts upstream..."
kubectl annotate ingress erpnext -n erpnext \
    nginx.ingress.kubernetes.io/proxy-connect-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-send-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-read-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-next-upstream-timeout="600" \
    nginx.ingress.kubernetes.io/upstream-vhost="erp.keybuzz.io" \
    --overwrite

log "${OK} ERPNext patché"

###############################################################################
# 4. CONFIGURATION GLOBALE INGRESS NGINX CONTROLLER
###############################################################################
log "${INFO} === PHASE 4: CONFIGURATION GLOBALE INGRESS CONTROLLER ==="

log "${INFO} Patch ConfigMap ingress-nginx-controller avec timeouts globaux..."
kubectl get configmap ingress-nginx-controller -n ingress-nginx &>/dev/null || \
    kubectl create configmap ingress-nginx-controller -n ingress-nginx

kubectl patch configmap ingress-nginx-controller -n ingress-nginx --type merge -p '{
  "data": {
    "proxy-connect-timeout": "600",
    "proxy-send-timeout": "600",
    "proxy-read-timeout": "600",
    "proxy-body-size": "50m",
    "proxy-buffer-size": "16k",
    "upstream-keepalive-timeout": "600"
  }
}'

log "${OK} ConfigMap ingress-nginx-controller patché"

###############################################################################
# 5. REDÉMARRAGE PODS INGRESS NGINX
###############################################################################
log "${INFO} === PHASE 5: REDÉMARRAGE INGRESS NGINX CONTROLLER ==="

log "${INFO} Redémarrage des pods Ingress NGINX pour appliquer la config..."
kubectl rollout restart daemonset ingress-nginx-controller -n ingress-nginx

log "${INFO} Attente du redémarrage (30s)..."
sleep 30

log "${INFO} État des pods Ingress NGINX après redémarrage:"
kubectl get pods -n ingress-nginx -o wide

###############################################################################
# 6. VÉRIFICATION ET CORRECTION ERPNEXT
###############################################################################
log "${INFO} === PHASE 6: CORRECTION ERPNEXT ==="

# Vérifier si le pod socketio existe
SOCKETIO_COUNT=$(kubectl get pods -n erpnext -l component=socketio --no-headers 2>/dev/null | wc -l)

if [ "$SOCKETIO_COUNT" -eq 0 ]; then
    log "${WARN} Pod ERPNext socketio manquant, vérification du deployment..."

    # Vérifier si le deployment existe
    SOCKETIO_DEPLOY=$(kubectl get deployment -n erpnext -l component=socketio --no-headers 2>/dev/null | wc -l)

    if [ "$SOCKETIO_DEPLOY" -eq 0 ]; then
        log "${WARN} Deployment socketio manquant, il faut le recréer manuellement"
        log "${INFO} Vérifiez le chart Helm ou les manifests ERPNext"
    else
        log "${INFO} Deployment existe, scaling à 1 replica..."
        kubectl scale deployment -n erpnext -l component=socketio --replicas=1
        log "${OK} Deployment socketio mis à l'échelle"
    fi
else
    log "${OK} Pod ERPNext socketio existe ($SOCKETIO_COUNT pod(s))"

    # Vérifier les logs
    log "${INFO} Logs socketio (dernières 20 lignes):"
    kubectl logs -n erpnext -l component=socketio --tail=20
fi

# Redémarrer tous les pods ERPNext pour une configuration propre
log "${INFO} Redémarrage des deployments ERPNext..."
kubectl rollout restart deployment -n erpnext 2>/dev/null || log "${WARN} Impossible de redémarrer ERPNext"

###############################################################################
# 7. REDÉMARRAGE DES BACKENDS
###############################################################################
log "${INFO} === PHASE 7: REDÉMARRAGE DES BACKENDS ==="

log "${INFO} Redémarrage Grafana..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana

log "${INFO} Redémarrage Connect API..."
kubectl rollout restart deployment -n connect connect-api 2>/dev/null || \
    log "${WARN} Deployment connect-api non trouvé"

log "${INFO} Attente du démarrage des pods (45s)..."
sleep 45

###############################################################################
# 8. TESTS FINAUX
###############################################################################
log "${INFO} === PHASE 8: TESTS FINAUX ==="

log "${INFO} État final des pods:"
echo "ERPNext:"
kubectl get pods -n erpnext

echo ""
echo "Grafana:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

echo ""
echo "Connect API:"
kubectl get pods -n connect -l app=connect-api

log "${INFO} Test des URLs (avec timeout de 30s):"
for url in "https://monitor.keybuzz.io" "https://connect.keybuzz.io" "https://erp.keybuzz.io"; do
    log "  Test $url:"
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 30 "$url" 2>/dev/null || echo "TIMEOUT")
    TIME=$(curl -k -s -o /dev/null -w "%{time_total}" --max-time 30 "$url" 2>/dev/null || echo "N/A")
    log "    HTTP $HTTP_CODE (${TIME}s)"
done

echo ""
log "${OK} Script terminé"
log "${INFO} Si les timeouts persistent, vérifiez les logs des pods backend :"
log "  kubectl logs -n erpnext <pod-name>"
log "  kubectl logs -n monitoring <grafana-pod>"
log "  kubectl logs -n connect <connect-api-pod>"
