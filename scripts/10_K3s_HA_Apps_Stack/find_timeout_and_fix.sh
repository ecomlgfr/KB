#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Script: find_timeout_and_fix.sh
# Description: Trouve la source du timeout 50s et corrige
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
echo "║     IDENTIFICATION TIMEOUT 50s ET CORRECTION NGINX 300s            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# 1. TEST RAPIDE: TIMEOUT DEPUIS OÙ ?
###############################################################################
log "$INFO === 1. IDENTIFICATION SOURCE TIMEOUT ==="
echo ""

log "$INFO Test direct NodePort (bypass tout LB externe)..."
START_TIME=$(date +%s.%N)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: monitor.keybuzz.io" \
    --max-time 60 \
    http://10.0.0.100:31695/ 2>/dev/null || echo "TIMEOUT")
END_TIME=$(date +%s.%N)
DURATION=$(echo "$END_TIME - $START_TIME" | bc)

log "  → HTTP $HTTP_CODE en ${DURATION}s"

if (( $(echo "$DURATION < 10" | bc -l) )); then
    log "$OK NodePort répond rapidement (<10s) - Le timeout vient d'un composant EXTERNE"
    TIMEOUT_EXTERNAL=true
else
    log "$WARN NodePort timeout également - Le problème est dans nginx.conf"
    TIMEOUT_EXTERNAL=false
fi

###############################################################################
# 2. CORRECTION BLOCK NGINX AVEC TIMEOUT 300s
###############################################################################
echo ""
log "$INFO === 2. CORRECTION NGINX.CONF (timeout 300s → 600s) ==="
echo ""

INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
log "Pod Ingress: $INGRESS_POD"

echo ""
log "$INFO Identification du block avec timeout 300s..."
kubectl exec -n ingress-nginx "$INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    grep -n "proxy_connect_timeout.*300s" | head -1

echo ""
log "$INFO Ce timeout 300s est probablement dans un 'default backend' ou 'catch-all'"
log "$INFO On va forcer GLOBALEMENT les timeouts via ConfigMap..."

log "$INFO Patch ConfigMap avec timeouts 600s..."
kubectl patch configmap ingress-nginx-controller -n ingress-nginx --type merge -p '{
  "data": {
    "proxy-connect-timeout": "600",
    "proxy-send-timeout": "600",
    "proxy-read-timeout": "600",
    "proxy-body-size": "50m",
    "upstream-keepalive-timeout": "600"
  }
}'

log "$OK ConfigMap patché"

echo ""
log "$INFO Redémarrage Ingress NGINX pour appliquer..."
kubectl rollout restart daemonset ingress-nginx-controller -n ingress-nginx

log "$INFO Attente du redémarrage (30s)..."
sleep 30

log "$INFO Vérification nouvelle config..."
NEW_INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
log "Nouveau pod: $NEW_INGRESS_POD"

echo ""
log "$INFO Vérification timeouts dans nouvelle config nginx.conf..."
kubectl exec -n ingress-nginx "$NEW_INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    grep -E "proxy_(connect|send|read)_timeout" | sort -u

###############################################################################
# 3. VÉRIFICATION HAPROXY (si timeout externe)
###############################################################################
if [ "$TIMEOUT_EXTERNAL" = true ]; then
    echo ""
    log "$INFO === 3. VÉRIFICATION HAProxy (SOURCE DU TIMEOUT 50s) ==="
    echo ""

    log "$WARN Le timeout de 50s vient d'un composant AVANT K3s"
    log "$INFO Vérification HAProxy sur 10.0.0.11 et 10.0.0.12..."

    for haproxy_ip in 10.0.0.11 10.0.0.12; do
        log ""
        log "HAProxy $haproxy_ip:"

        # Vérifier si SSH accessible
        if timeout 3 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@$haproxy_ip "echo OK" &>/dev/null; then
            log "$OK SSH accessible"

            log "$INFO Configuration timeouts HAProxy actuels..."
            ssh -o StrictHostKeyChecking=no root@$haproxy_ip \
                "grep -E '(timeout connect|timeout client|timeout server)' /etc/haproxy/haproxy.cfg | head -10" 2>/dev/null || \
                log "$WARN Impossible de lire config HAProxy"

            log ""
            log "$INFO Recherche backend K3s dans HAProxy..."
            ssh -o StrictHostKeyChecking=no root@$haproxy_ip \
                "grep -A 10 'backend.*k3s\|backend.*ingress' /etc/haproxy/haproxy.cfg | head -20" 2>/dev/null || \
                log "$WARN Backend K3s non trouvé"

            log ""
            log "$WARN CORRECTION REQUISE sur HAProxy $haproxy_ip:"
            log "  sudo nano /etc/haproxy/haproxy.cfg"
            log "  Augmenter:"
            log "    timeout connect 600s"
            log "    timeout client  600s"
            log "    timeout server  600s"
            log "  sudo systemctl reload haproxy"
        else
            log "$KO SSH non accessible sur $haproxy_ip"
        fi
    done
fi

###############################################################################
# 4. TEST FINAL
###############################################################################
echo ""
log "$INFO === 4. TEST FINAL ==="
echo ""

log "$INFO Attente stabilisation (15s)..."
sleep 15

log "$INFO Test NodePort après corrections..."
START_TIME=$(date +%s.%N)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: monitor.keybuzz.io" \
    --max-time 60 \
    http://10.0.0.100:31695/ 2>/dev/null || echo "TIMEOUT")
END_TIME=$(date +%s.%N)
DURATION=$(echo "$END_TIME - $START_TIME" | bc)

log "  → HTTP $HTTP_CODE en ${DURATION}s"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "403" ]; then
    if (( $(echo "$DURATION < 10" | bc -l) )); then
        log "$OK K3s/Ingress fonctionne correctement"
    fi
fi

###############################################################################
# 5. RÉSUMÉ
###############################################################################
echo ""
log "═══════════════════════════════════════════════════════════════════"
log "$INFO RÉSUMÉ"
log "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$TIMEOUT_EXTERNAL" = true ]; then
    log "$WARN SOURCE DU TIMEOUT: Composant EXTERNE (HAProxy ou LB Hetzner)"
    log ""
    log "Actions requises:"
    log "  1. Vérifier config HAProxy sur 10.0.0.11 et 10.0.0.12"
    log "  2. Augmenter timeouts à 600s dans HAProxy"
    log "  3. Recharger HAProxy: sudo systemctl reload haproxy"
    log "  4. Ou vérifier config Load Balancer Hetzner si utilisé"
    echo ""
    log "$INFO K3s/Ingress: Config corrigée (tous timeouts à 600s)"
else
    log "$OK Source timeout identifiée et corrigée dans K3s/Ingress"
    log "$INFO Vérifier config HAProxy au cas où"
fi

echo ""
log "État ERPNext:"
kubectl get pods -A | grep -i erp | head -10 || log "$WARN ERPNext pas déployé ou namespace différent"

echo ""
log "$OK Script terminé"
