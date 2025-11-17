#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Script: investigate_timeout_source.sh
# Description: Identifier la source réelle du timeout de 50s
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
echo "║         INVESTIGATION SOURCE DU TIMEOUT 50s                        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# 1. VÉRIFIER SI ERPNext EST DÉPLOYÉ
###############################################################################
log "$INFO === 1. ÉTAT ERPNext ==="
echo ""

log "$INFO Recherche namespace erpnext..."
kubectl get namespaces | grep -E "(NAME|erpnext)" || log "$WARN Namespace erpnext introuvable"

echo ""
log "$INFO Recherche pods ERPNext dans TOUS les namespaces..."
kubectl get pods -A | grep -i erp | head -20 || log "$WARN Aucun pod ERPNext trouvé"

echo ""
log "$INFO Recherche déploiements Frappe/ERPNext..."
kubectl get deployments -A | grep -i -E "(erp|frappe)" | head -20 || log "$WARN Aucun déploiement trouvé"

###############################################################################
# 2. TEST DEPUIS L'INTÉRIEUR DU CLUSTER (bypass LB externe)
###############################################################################
echo ""
log "$INFO === 2. TESTS DEPUIS INTÉRIEUR CLUSTER (bypass LB) ==="
echo ""

log "$INFO Test Grafana via service interne..."
kubectl run test-internal-grafana --image=curlimages/curl:latest --rm -i --restart=Never -- \
    sh -c 'time curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" --max-time 120 http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local' 2>&1 || log "$WARN Test failed"

echo ""
log "$INFO Test Connect API via service interne..."
kubectl run test-internal-connect --image=curlimages/curl:latest --rm -i --restart=Never -- \
    sh -c 'time curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" --max-time 120 http://connect-api.connect.svc.cluster.local/health' 2>&1 || log "$WARN Test failed"

###############################################################################
# 3. TEST DIRECT NODEPORT (bypass LB mais via Ingress)
###############################################################################
echo ""
log "$INFO === 3. TESTS NODEPORT (bypass LB externe) ==="
echo ""

log "$INFO Test direct Grafana via NodePort 31695..."
time curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
    -H "Host: monitor.keybuzz.io" \
    --max-time 120 \
    http://10.0.0.100:31695/ 2>&1

echo ""
log "$INFO Test direct Connect via NodePort 31695..."
time curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
    -H "Host: connect.keybuzz.io" \
    --max-time 120 \
    http://10.0.0.100:31695/ 2>&1

###############################################################################
# 4. IDENTIFICATION BLOCK NGINX AVEC TIMEOUT 300s
###############################################################################
echo ""
log "$INFO === 4. IDENTIFICATION BLOCK NGINX 300s ==="
echo ""

INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
log "Pod Ingress: $INGRESS_POD"

echo ""
log "$INFO Extraction du context autour du timeout 300s..."
kubectl exec -n ingress-nginx "$INGRESS_POD" -- cat /etc/nginx/nginx.conf | \
    awk '/proxy_connect_timeout.*300s/ {
        # Print 15 lines before
        for(i=NR-15; i<NR; i++) if(i in lines) print i": "lines[i]
        # Print current line
        print NR": "$0
        # Print 15 lines after
        for(i=1; i<=15; i++) {
            if(getline > 0) print NR+i": "$0
        }
        exit
    }
    {lines[NR]=$0}'

###############################################################################
# 5. VÉRIFICATION LOAD BALANCER HETZNER
###############################################################################
echo ""
log "$INFO === 5. VÉRIFICATION LOAD BALANCER ==="
echo ""

log "$INFO Services de type LoadBalancer..."
kubectl get svc -A -o wide | grep -E "(NAME|LoadBalancer)" || log "$INFO Aucun service LoadBalancer"

echo ""
log "$INFO Recherche annotations Hetzner Cloud..."
kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | {
    name: .metadata.name,
    namespace: .metadata.namespace,
    annotations: .metadata.annotations
}' 2>/dev/null || log "$INFO Pas de LB Hetzner détecté"

###############################################################################
# 6. VÉRIFICATION HAPROXY (devant les masters)
###############################################################################
echo ""
log "$INFO === 6. VÉRIFICATION HAProxy DEVANT K3S ==="
echo ""

log "$INFO Test si HAProxy écoute sur 443/80..."
for ip in 10.0.0.11 10.0.0.12; do
    log "Test HAProxy $ip:443..."
    timeout 5 curl -k -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
        -H "Host: monitor.keybuzz.io" \
        https://$ip/ 2>&1 || log "$WARN Timeout ou erreur"
done

echo ""
log "$INFO Vérification timeouts HAProxy (si accessible)..."
for ip in 10.0.0.11 10.0.0.12; do
    log "HAProxy $ip config..."
    timeout 3 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@$ip \
        "grep -E '(timeout connect|timeout client|timeout server)' /etc/haproxy/haproxy.cfg 2>/dev/null || echo 'SSH failed'" 2>&1 | head -10
done

###############################################################################
# 7. VÉRIFICATION DES IPS ET ROUTAGE
###############################################################################
echo ""
log "$INFO === 7. ROUTAGE ET RÉSOLUTION DNS ==="
echo ""

log "$INFO Résolution DNS des domaines..."
for domain in monitor.keybuzz.io connect.keybuzz.io erp.keybuzz.io; do
    log "$domain:"
    dig +short $domain | head -5 || nslookup $domain | grep -A 2 "Name:" | head -5
done

echo ""
log "$INFO Test depuis cette machine vers les URLs publiques..."
for url in https://monitor.keybuzz.io https://connect.keybuzz.io; do
    log "Test $url (max 60s)..."
    time curl -k -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s - IP: %{remote_ip}\n" \
        --max-time 60 \
        "$url" 2>&1
done

###############################################################################
# 8. RÉSUMÉ ET DIAGNOSTIC
###############################################################################
echo ""
log "═══════════════════════════════════════════════════════════════════"
log "$INFO ANALYSE"
log "═══════════════════════════════════════════════════════════════════"
echo ""

log "Si timeout 50s apparaît UNIQUEMENT depuis l'extérieur:"
log "  → Le problème est dans le Load Balancer Hetzner ou HAProxy devant K3s"
echo ""

log "Si timeout 50s apparaît même en NodePort direct:"
log "  → Le problème est dans la config nginx.conf (block avec 300s)"
echo ""

log "Si pas de timeout en accès interne (ClusterIP):"
log "  → Confirme que le problème est au niveau réseau externe"
echo ""

log "Prochaines actions recommandées:"
log "  1. Identifier la couche qui introduit le timeout 50s"
log "  2. Vérifier config HAProxy (timeout server, timeout client)"
log "  3. Vérifier config Hetzner LB (si utilisé)"
log "  4. Corriger le block nginx avec timeout 300s"
echo ""

log "$OK Investigation terminée"
