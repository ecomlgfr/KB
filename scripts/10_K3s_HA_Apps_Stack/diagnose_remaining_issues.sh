#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Script: diagnose_remaining_issues.sh
# Description: Diagnostic approfondi des 2 problèmes restants
#              1. Format URL Redis avec WRONGPASS
#              2. Timeout Connect API (50s au lieu de 600s)
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
echo "║         DIAGNOSTIC DES PROBLÈMES RESTANTS                         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# 1. INVESTIGATION REDIS URL FORMAT
###############################################################################
log "$INFO === PROBLÈME 1: FORMAT URL REDIS ==="
echo ""

log "$INFO Test Redis avec différents formats..."

# Format 1: redis-cli standard avec -a
log "Format 1: redis-cli -h 10.0.0.10 -a PASSWORD"
redis-cli -h 10.0.0.10 -p 6379 -a "SfqY41ThPI3UlGZxI1j2qlm0unBR41Ie" PING 2>&1 | head -5

# Format 2: URL avec mot de passe
log "Format 2: redis-cli -u redis://:PASSWORD@10.0.0.10:6379"
redis-cli -u "redis://:SfqY41ThPI3UlGZxI1j2qlm0unBR41Ie@10.0.0.10:6379/3" PING 2>&1 | head -5

# Format 3: URL avec utilisateur default
log "Format 3: redis-cli -u redis://default:PASSWORD@10.0.0.10:6379"
redis-cli -u "redis://default:SfqY41ThPI3UlGZxI1j2qlm0unBR41Ie@10.0.0.10:6379/3" PING 2>&1 | head -5

echo ""
log "$INFO Configuration Redis ACL actuelle:"
redis-cli -h 10.0.0.10 -a "SfqY41ThPI3UlGZxI1j2qlm0unBR41Ie" ACL LIST 2>&1 | head -10

echo ""
log "$INFO Configuration ERPNext actuelle:"
kubectl exec -n erpnext deployment/erpnext-gunicorn -- \
    cat sites/erp.keybuzz.io/site_config.json | jq '{
        redis_cache,
        redis_queue,
        redis_socketio,
        socketio_port
    }'

echo ""
log "$INFO Logs ERPNext socketio (dernières 30 lignes):"
kubectl logs -n erpnext -l component=socketio --tail=30 2>&1 | grep -E "(error|Error|WRONGPASS|Connection|refused|timeout)"

echo ""
log "$INFO État du pod socketio:"
kubectl get pods -n erpnext -l component=socketio -o jsonpath='{.items[0].status}' | jq '{
    phase,
    reason,
    message,
    containerStatuses: .containerStatuses[0] | {
        name,
        ready,
        restartCount,
        state
    }
}'

###############################################################################
# 2. INVESTIGATION TIMEOUT CONNECT API
###############################################################################
echo ""
echo ""
log "$INFO === PROBLÈME 2: TIMEOUT CONNECT API ==="
echo ""

log "$INFO État des pods Connect API:"
kubectl get pods -n connect -l app=connect-api -o wide

echo ""
log "$INFO Service Connect API:"
kubectl get svc -n connect connect-api -o yaml | grep -A 10 "spec:"

echo ""
log "$INFO Endpoints Connect API:"
kubectl get endpoints -n connect connect-api -o jsonpath='{.subsets[*].addresses[*].ip}' && echo ""

echo ""
log "$INFO Ingress Connect API annotations:"
kubectl get ingress -n connect connect-ingress -o jsonpath='{.metadata.annotations}' | jq '.'

echo ""
log "$INFO Vérification ConfigMap Ingress NGINX:"
kubectl get configmap ingress-nginx-controller -n ingress-nginx -o jsonpath='{.data}' | jq '.'

echo ""
log "$INFO Recherche du block nginx avec timeout 300s..."
INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
log "Pod Ingress NGINX: $INGRESS_POD"

echo ""
log "$INFO Extraction de la config upstream connect-connect-api-80:"
kubectl exec -n ingress-nginx "$INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    awk '/upstream connect-connect-api-80/,/^[[:space:]]*}/' | head -30

echo ""
log "$INFO Recherche de tous les proxy_connect_timeout dans nginx.conf:"
kubectl exec -n ingress-nginx "$INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    grep -n "proxy_connect_timeout" | head -20

echo ""
log "$INFO Recherche des blocks avec timeout 300s:"
kubectl exec -n ingress-nginx "$INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    grep -B 5 -A 5 "proxy_connect_timeout.*300"

echo ""
log "$INFO Test direct du pod Connect API (bypass Ingress):"
CONNECT_POD=$(kubectl get pods -n connect -l app=connect-api -o jsonpath='{.items[0].metadata.name}')
log "Pod Connect: $CONNECT_POD"
log "Test health endpoint:"
kubectl exec -n connect "$CONNECT_POD" -- curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" http://localhost:3000/health 2>/dev/null || echo "Échec"

echo ""
log "$INFO Test depuis un pod de test vers le service Connect:"
CONNECT_SVC_IP=$(kubectl get svc -n connect connect-api -o jsonpath='{.spec.clusterIP}')
log "Service IP: $CONNECT_SVC_IP"
kubectl run test-connect-timeout --image=curlimages/curl:latest --rm -i --restart=Never --command -- \
    curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
    --max-time 120 "http://$CONNECT_SVC_IP:3000/health" 2>/dev/null || log "$WARN Test échoué"

echo ""
log "$INFO Logs Ingress Controller (erreurs Connect):"
kubectl logs -n ingress-nginx "$INGRESS_POD" --tail=50 | grep -i "connect" | tail -20

echo ""
log "$INFO Vérification des variables d'environnement du pod Connect:"
kubectl exec -n connect "$CONNECT_POD" -- env | grep -E "(TIMEOUT|PORT|HOST|REDIS|DATABASE)" | sort

###############################################################################
# 3. TESTS DE LATENCE RÉSEAU
###############################################################################
echo ""
echo ""
log "$INFO === TESTS DE LATENCE RÉSEAU ==="
echo ""

log "$INFO Latence vers les pods Connect depuis Ingress controller:"
for pod_ip in $(kubectl get pods -n connect -l app=connect-api -o jsonpath='{.items[*].status.podIP}'); do
    log "Test vers $pod_ip:3000"
    kubectl exec -n ingress-nginx "$INGRESS_POD" -- \
        timeout 5 sh -c "time echo -e 'GET /health HTTP/1.0\r\n\r\n' | nc $pod_ip 3000" 2>&1 | head -5
    echo ""
done

###############################################################################
# 4. RÉSUMÉ ET RECOMMANDATIONS
###############################################################################
echo ""
log "═══════════════════════════════════════════════════════════════════"
log "$INFO RÉSUMÉ DU DIAGNOSTIC"
log "═══════════════════════════════════════════════════════════════════"
echo ""

log "Problème 1 - Redis URL Format:"
log "  • Format -a fonctionne: redis-cli -h 10.0.0.10 -a PASSWORD"
log "  • Format URL échoue: redis://:PASSWORD@host"
log "  • À investiguer: Compatibilité client Redis Python utilisé par Frappe"
echo ""

log "Problème 2 - Timeout Connect API:"
log "  • Timeout configuré: 600s (ConfigMap + annotations)"
log "  • Timeout observé: 50s (logs Ingress)"
log "  • Pod Connect: Vérifié ci-dessus"
log "  • À vérifier: Block nginx spécifique avec timeout 300s ou autre"
echo ""

log "$OK Diagnostic terminé"
log ""
log "Actions recommandées:"
log "  1. Pour Redis: Tester format URL avec 'default' user explicite"
log "  2. Pour Connect: Identifier le block nginx avec timeout 300s"
log "  3. Redémarrer les pods après corrections"
