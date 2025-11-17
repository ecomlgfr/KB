#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Script: fix_final_issues.sh
# Description: Correction des 2 derniers problèmes
#              1. Format URL Redis ERPNext socketio
#              2. Timeout Connect API 50s → 600s
# Date: 2025-11-17
###############################################################################

OK='✓'
KO='✗'
WARN='⚠'
INFO='ℹ'

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
echo "║         CORRECTION FINALE DES PROBLÈMES RESTANTS                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# 1. FIX: FORMAT URL REDIS (essayer avec utilisateur 'default')
###############################################################################
log "$INFO === FIX 1: FORMAT URL REDIS AVEC USER DEFAULT ==="
echo ""

REDIS_PASSWORD="SfqY41ThPI3UlGZxI1j2qlm0unBR41Ie"
REDIS_HOST="10.0.0.10"

log "$INFO Test du format avec utilisateur 'default' explicite..."
redis-cli -u "redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:6379/3" PING 2>&1

if [ $? -eq 0 ]; then
    log "$OK Format URL avec 'default' user fonctionne!"
    log "$INFO Application de la configuration à ERPNext..."

    # Mettre à jour ERPNext avec le format qui fonctionne
    kubectl exec -n erpnext deployment/erpnext-gunicorn -- \
        bench --site erp.keybuzz.io set-config redis_cache \
        "redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:6379/0"

    kubectl exec -n erpnext deployment/erpnext-gunicorn -- \
        bench --site erp.keybuzz.io set-config redis_queue \
        "redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:6379/1"

    kubectl exec -n erpnext deployment/erpnext-gunicorn -- \
        bench --site erp.keybuzz.io set-config redis_socketio \
        "redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:6379/3"

    log "$OK Configuration ERPNext mise à jour avec user 'default'"

    log "$INFO Redémarrage du deployment socketio..."
    kubectl rollout restart deployment -n erpnext -l component=socketio

    log "$INFO Attente du redémarrage (30s)..."
    sleep 30

    log "$INFO État du pod socketio après fix:"
    kubectl get pods -n erpnext -l component=socketio

    log "$INFO Logs socketio (dernières 20 lignes):"
    kubectl logs -n erpnext -l component=socketio --tail=20
else
    log "$WARN Format avec 'default' user échoue aussi"
    log "$INFO Tentative avec format alternatif (sans scheme)..."

    # Si le format URL ne fonctionne pas du tout, utiliser le format simple
    kubectl exec -n erpnext deployment/erpnext-gunicorn -- \
        bench --site erp.keybuzz.io set-config redis_socketio \
        "${REDIS_HOST}:6379/3"

    # Configurer le mot de passe séparément si possible
    log "$WARN Configuration alternative appliquée, vérification manuelle requise"
fi

###############################################################################
# 2. FIX: TIMEOUT CONNECT API (Forcer 600s partout)
###############################################################################
echo ""
echo ""
log "$INFO === FIX 2: TIMEOUT CONNECT API ==="
echo ""

log "$INFO Patch ConfigMap Ingress NGINX avec timeouts explicites..."
kubectl patch configmap ingress-nginx-controller -n ingress-nginx --type merge -p '{
  "data": {
    "proxy-connect-timeout": "600",
    "proxy-send-timeout": "600",
    "proxy-read-timeout": "600",
    "proxy-body-size": "50m",
    "proxy-buffer-size": "16k",
    "proxy-buffers": "8 16k",
    "upstream-keepalive-timeout": "600",
    "keep-alive": "600",
    "keep-alive-requests": "1000"
  }
}'

log "$OK ConfigMap patché"

echo ""
log "$INFO Patch Ingress Connect avec toutes les annotations timeout..."
kubectl annotate ingress connect-ingress -n connect \
    nginx.ingress.kubernetes.io/proxy-connect-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-send-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-read-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-next-upstream-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-body-size="50m" \
    nginx.ingress.kubernetes.io/upstream-keepalive-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-buffering="on" \
    nginx.ingress.kubernetes.io/proxy-buffer-size="16k" \
    --overwrite

log "$OK Ingress Connect patché"

echo ""
log "$INFO Patch Ingress Grafana avec mêmes annotations..."
kubectl annotate ingress grafana-ingress -n monitoring \
    nginx.ingress.kubernetes.io/proxy-connect-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-send-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-read-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-next-upstream-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-body-size="50m" \
    nginx.ingress.kubernetes.io/upstream-keepalive-timeout="600" \
    --overwrite

log "$OK Ingress Grafana patché"

echo ""
log "$INFO Patch Ingress ERPNext avec mêmes annotations..."
kubectl annotate ingress erpnext -n erpnext \
    nginx.ingress.kubernetes.io/proxy-connect-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-send-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-read-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-next-upstream-timeout="600" \
    nginx.ingress.kubernetes.io/proxy-body-size="50m" \
    nginx.ingress.kubernetes.io/upstream-keepalive-timeout="600" \
    --overwrite

log "$OK Ingress ERPNext patché"

###############################################################################
# 3. REDÉMARRAGE INGRESS NGINX CONTROLLER
###############################################################################
echo ""
log "$INFO === REDÉMARRAGE INGRESS NGINX CONTROLLER ==="
echo ""

log "$INFO Redémarrage DaemonSet Ingress NGINX..."
kubectl rollout restart daemonset ingress-nginx-controller -n ingress-nginx

log "$INFO Attente du redémarrage (45s)..."
sleep 45

log "$INFO État des pods Ingress NGINX:"
kubectl get pods -n ingress-nginx -o wide

###############################################################################
# 4. VÉRIFICATION DE LA CONFIG NGINX FINALE
###############################################################################
echo ""
log "$INFO === VÉRIFICATION CONFIG NGINX ==="
echo ""

INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
log "Pod Ingress: $INGRESS_POD"

echo ""
log "$INFO Vérification des timeouts dans nginx.conf:"
kubectl exec -n ingress-nginx "$INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    grep -E "proxy_(connect|send|read)_timeout" | sort -u | head -20

echo ""
log "$INFO Vérification upstream connect-connect-api-80:"
kubectl exec -n ingress-nginx "$INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    awk '/upstream connect-connect-api-80/,/^[[:space:]]*}/' | head -30

###############################################################################
# 5. REDÉMARRAGE DES BACKENDS
###############################################################################
echo ""
log "$INFO === REDÉMARRAGE DES BACKENDS ==="
echo ""

log "$INFO Redémarrage Grafana..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana

log "$INFO Redémarrage Connect API..."
kubectl rollout restart deployment -n connect connect-api

log "$INFO Attente du démarrage (30s)..."
sleep 30

###############################################################################
# 6. TESTS FINAUX
###############################################################################
echo ""
log "$INFO === TESTS FINAUX ==="
echo ""

log "$INFO État des pods:"
echo "ERPNext socketio:"
kubectl get pods -n erpnext -l component=socketio

echo ""
echo "Grafana:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

echo ""
echo "Connect API:"
kubectl get pods -n connect -l app=connect-api

echo ""
log "$INFO Test des URLs (timeout 60s):"
for url in "https://erp.keybuzz.io" "https://monitor.keybuzz.io" "https://connect.keybuzz.io"; do
    log "  Test $url:"
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 60 "$url" 2>/dev/null || echo "TIMEOUT")
    TIME=$(curl -k -s -o /dev/null -w "%{time_total}" --max-time 60 "$url" 2>/dev/null || echo "N/A")

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        log "    $OK HTTP $HTTP_CODE (${TIME}s)"
    elif [ "$HTTP_CODE" = "TIMEOUT" ]; then
        log "    $KO TIMEOUT après 60s"
    else
        log "    $WARN HTTP $HTTP_CODE (${TIME}s)"
    fi
done

###############################################################################
# 7. RÉSUMÉ FINAL
###############################################################################
echo ""
echo ""
log "═══════════════════════════════════════════════════════════════════"
log "$INFO RÉSUMÉ DES CORRECTIONS"
log "═══════════════════════════════════════════════════════════════════"
echo ""

log "Corrections appliquées:"
log "  1. Format URL Redis avec user 'default' pour ERPNext"
log "  2. Timeouts Ingress augmentés à 600s (ConfigMap + annotations)"
log "  3. Ingress NGINX Controller redémarré"
log "  4. Tous les backends redémarrés"
echo ""

log "$INFO Vérifications recommandées:"
log "  • ERPNext socketio: kubectl logs -n erpnext -l component=socketio --tail=50"
log "  • Connect API: curl -I https://connect.keybuzz.io"
log "  • Grafana: curl -I https://monitor.keybuzz.io"
echo ""

log "$INFO Si problèmes persistent:"
log "  • Vérifier nginx.conf: kubectl exec -n ingress-nginx <pod> -- cat /etc/nginx/nginx.conf | grep timeout"
log "  • Logs Ingress: kubectl logs -n ingress-nginx <pod> --tail=100"
log "  • Test direct pod: kubectl exec -n connect <pod> -- curl http://localhost:3000/health"
echo ""

log "$OK Script terminé"
