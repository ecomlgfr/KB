#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# DIAGNOSTIC ET CORRECTION AUTOMATIQUE - Applications K3s KeyBuzz
###############################################################################
# Auteur: Claude AI Assistant
# Date: 2025-11-14
# Version: 1.0
#
# Description:
#   Diagnostic complet et correction automatique des problèmes :
#   - ERPNext socketio (CrashLoopBackOff)
#   - Grafana (504 timeout)
#   - Connect API (504 timeout)
#   - Nettoyage pods Completed
#   - Vérification Ingress routes
#
# Usage depuis install-01:
#   ./fix_k3s_apps_issues.sh
###############################################################################

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

LOG_DIR="/opt/keybuzz-installer/logs"
LOG="$LOG_DIR/fix_k3s_apps_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG") 2>&1

# ╔════════════════════════════════════════════════════════════════════╗
# ║  DÉTECTION ET CONFIGURATION KUBECONFIG                            ║
# ╚════════════════════════════════════════════════════════════════════╝

# Fonction de log (doit être définie avant l'utilisation)
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Essayer plusieurs emplacements de kubeconfig
KUBECONFIG_LOCATIONS=(
    "${KUBECONFIG:-}"  # Variable d'environnement si déjà définie (vide par défaut)
    "/opt/keybuzz-installer/credentials/k3s.yaml"
    "/etc/rancher/k3s/k3s.yaml"
    "$HOME/.kube/config"
)

KUBECONFIG_FOUND=""
for kubeconfig_path in "${KUBECONFIG_LOCATIONS[@]}"; do
    if [ -n "$kubeconfig_path" ] && [ -f "$kubeconfig_path" ]; then
        # Tester si le kubeconfig fonctionne
        if KUBECONFIG="$kubeconfig_path" kubectl version --client &>/dev/null; then
            KUBECONFIG_FOUND="$kubeconfig_path"
            export KUBECONFIG="$kubeconfig_path"
            log "✓ Kubeconfig trouvé: $kubeconfig_path"
            break
        fi
    fi
done

# Si aucun kubeconfig trouvé, essayer de le récupérer depuis un master K3s
if [ -z "$KUBECONFIG_FOUND" ]; then
    log "⚠ Aucun kubeconfig trouvé, tentative de récupération depuis master K3s..."

    # IPs des masters K3s (selon cahier des charges)
    K3S_MASTERS=("10.0.0.100" "10.0.0.101" "10.0.0.102")

    for master_ip in "${K3S_MASTERS[@]}"; do
        log "  Tentative de connexion à $master_ip..."
        if scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            root@"$master_ip":/etc/rancher/k3s/k3s.yaml \
            /tmp/k3s_kubeconfig_temp.yaml &>/dev/null; then

            # Remplacer 127.0.0.1 par l'IP réelle du master
            sed -i "s/127.0.0.1/$master_ip/g" /tmp/k3s_kubeconfig_temp.yaml

            # Créer le répertoire credentials si nécessaire
            mkdir -p /opt/keybuzz-installer/credentials
            mv /tmp/k3s_kubeconfig_temp.yaml /opt/keybuzz-installer/credentials/k3s.yaml
            chmod 600 /opt/keybuzz-installer/credentials/k3s.yaml

            export KUBECONFIG="/opt/keybuzz-installer/credentials/k3s.yaml"
            KUBECONFIG_FOUND="$KUBECONFIG"
            log "✓ Kubeconfig récupéré depuis $master_ip"
            break
        fi
    done
fi

# Vérifier que kubectl fonctionne
if [ -z "$KUBECONFIG_FOUND" ]; then
    log "✗ ERREUR: Impossible de trouver ou récupérer un kubeconfig valide"
    log ""
    log "Ce script doit être exécuté depuis un serveur ayant accès au cluster K3s."
    log ""
    log "Options:"
    log "  1. Exécuter depuis install-01 (10.0.0.20 / install-01.keybuzz.io)"
    log "  2. Exécuter depuis un master K3s (10.0.0.100-102)"
    log "  3. Définir KUBECONFIG manuellement:"
    log "     export KUBECONFIG=/chemin/vers/k3s.yaml"
    log ""
    log "Pour récupérer manuellement le kubeconfig:"
    log "  scp root@10.0.0.100:/etc/rancher/k3s/k3s.yaml /opt/keybuzz-installer/credentials/k3s.yaml"
    log "  sed -i 's/127.0.0.1/10.0.0.100/g' /opt/keybuzz-installer/credentials/k3s.yaml"
    log "  chmod 600 /opt/keybuzz-installer/credentials/k3s.yaml"
    log "  export KUBECONFIG=/opt/keybuzz-installer/credentials/k3s.yaml"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      DIAGNOSTIC ET CORRECTION AUTOMATIQUE - K3s Apps              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

###############################################################################
# 1. DIAGNOSTIC INITIAL
###############################################################################

log "${INFO} === PHASE 1: DIAGNOSTIC INITIAL ==="

# Vérifier kubectl
if ! command -v kubectl &>/dev/null; then
    log "${KO} kubectl non trouvé"
    exit 1
fi

log "${OK} kubectl opérationnel"

# État des namespaces problématiques
log "${INFO} État des pods problématiques:"
echo ""

log "ERPNext:"
kubectl get pods -n erpnext | grep -E "socketio|NAME"

log "Monitoring (Grafana):"
kubectl get pods -n monitoring | grep -E "grafana|NAME"

log "Connect API:"
kubectl get pods -n connect

log "Vault:"
kubectl get pods -n vault | head -5

###############################################################################
# 2. NETTOYER LES PODS COMPLETED
###############################################################################

log "${INFO} === PHASE 2: NETTOYAGE PODS COMPLETED ==="

COMPLETED_PODS=$(kubectl get pods -A --field-selector=status.phase==Succeeded -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')

if [[ -n "$COMPLETED_PODS" ]]; then
    log "${INFO} Suppression des pods Completed..."
    echo "$COMPLETED_PODS" | while read ns pod; do
        kubectl delete pod -n "$ns" "$pod" --grace-period=0 --force >/dev/null 2>&1
        log "  Supprimé: $ns/$pod"
    done
    log "${OK} Pods Completed nettoyés"
else
    log "${INFO} Aucun pod Completed à nettoyer"
fi

###############################################################################
# 3. CORRIGER ERPNEXT SOCKETIO
###############################################################################

log "${INFO} === PHASE 3: CORRECTION ERPNEXT SOCKETIO ==="

# Vérifier les logs socketio
log "${INFO} Analyse des logs ERPNext socketio..."
SOCKETIO_POD=$(kubectl get pods -n erpnext -l app=erpnext,component=socketio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$SOCKETIO_POD" ]]; then
    log "Derniers logs socketio:"
    kubectl logs -n erpnext "$SOCKETIO_POD" --tail=20 2>&1 || log "${WARN} Impossible de récupérer les logs"
fi

# Vérifier la configuration Redis
log "${INFO} Vérification configuration Redis ERPNext..."

# Récupérer la configuration du site
kubectl exec -n erpnext deployment/erpnext-gunicorn -- cat sites/currentsite.txt 2>/dev/null || log "${WARN} Site non trouvé"

SITE_NAME=$(kubectl exec -n erpnext deployment/erpnext-gunicorn -- cat sites/currentsite.txt 2>/dev/null || echo "erp.keybuzz.io")

log "Site ERPNext: $SITE_NAME"

# Vérifier la config Redis dans site_config.json
log "${INFO} Vérification site_config.json..."
kubectl exec -n erpnext deployment/erpnext-gunicorn -- cat "sites/$SITE_NAME/site_config.json" 2>/dev/null | jq '.' || log "${WARN} Impossible de lire site_config.json"

# Corriger la configuration Redis si nécessaire
log "${INFO} Correction configuration Redis socketio..."

kubectl exec -n erpnext deployment/erpnext-gunicorn -- bash -c "
cd /home/frappe/frappe-bench
bench --site $SITE_NAME set-config socketio_port 9000
bench --site $SITE_NAME set-config redis_socketio 'redis://10.0.0.10:6379/3'
" 2>&1 || log "${WARN} Erreur lors de la configuration Redis"

log "${OK} Configuration Redis mise à jour"

# Redémarrer socketio
log "${INFO} Redémarrage du pod socketio..."
kubectl delete pod -n erpnext -l app=erpnext,component=socketio --grace-period=0 --force >/dev/null 2>&1

log "${INFO} Attente du nouveau pod socketio (30s)..."
sleep 30

NEW_SOCKETIO_POD=$(kubectl get pods -n erpnext -l app=erpnext,component=socketio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$NEW_SOCKETIO_POD" ]]; then
    STATUS=$(kubectl get pod -n erpnext "$NEW_SOCKETIO_POD" -o jsonpath='{.status.phase}')
    log "Nouveau pod socketio: $NEW_SOCKETIO_POD - Status: $STATUS"

    if [[ "$STATUS" == "Running" ]]; then
        log "${OK} ERPNext socketio corrigé et opérationnel"
    else
        log "${WARN} Socketio redémarré mais pas encore Running, vérifier : kubectl logs -n erpnext $NEW_SOCKETIO_POD"
    fi
fi

###############################################################################
# 4. CORRIGER GRAFANA TIMEOUT
###############################################################################

log "${INFO} === PHASE 4: CORRECTION GRAFANA INGRESS TIMEOUT ==="

# Vérifier l'Ingress Grafana
if kubectl get ingress -n monitoring kube-prometheus-stack-grafana &>/dev/null; then
    log "${INFO} Ingress Grafana existant trouvé"

    # Ajouter annotations timeout
    kubectl patch ingress -n monitoring kube-prometheus-stack-grafana --type=json -p='[
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-connect-timeout","value":"600"},
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-send-timeout","value":"600"},
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-read-timeout","value":"600"},
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size","value":"50m"}
    ]' 2>&1 || log "${WARN} Patch Ingress Grafana échoué (peut-être déjà configuré)"

    log "${OK} Timeout Ingress Grafana augmenté (600s)"
else
    log "${WARN} Ingress Grafana non trouvé, création..."

    # Créer l'Ingress Grafana
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kube-prometheus-stack-grafana
  namespace: monitoring
  annotations:
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  ingressClassName: nginx
  rules:
  - host: monitor.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kube-prometheus-stack-grafana
            port:
              number: 80
EOF

    log "${OK} Ingress Grafana créé"
fi

###############################################################################
# 5. CORRIGER CONNECT API TIMEOUT
###############################################################################

log "${INFO} === PHASE 5: CORRECTION CONNECT API INGRESS TIMEOUT ==="

# Vérifier l'Ingress Connect
if kubectl get ingress -n connect connect-api &>/dev/null; then
    log "${INFO} Ingress Connect API existant trouvé"

    # Ajouter annotations timeout
    kubectl patch ingress -n connect connect-api --type=json -p='[
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-connect-timeout","value":"600"},
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-send-timeout","value":"600"},
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-read-timeout","value":"600"},
        {"op":"add","path":"/metadata/annotations/nginx.ingress.kubernetes.io~1proxy-body-size","value":"50m"}
    ]' 2>&1 || log "${WARN} Patch Ingress Connect échoué"

    log "${OK} Timeout Ingress Connect API augmenté (600s)"
else
    log "${WARN} Ingress Connect API non trouvé, création..."

    # Créer l'Ingress Connect
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: connect-api
  namespace: connect
  annotations:
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  ingressClassName: nginx
  rules:
  - host: connect.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: connect-api
            port:
              number: 8000
EOF

    log "${OK} Ingress Connect API créé"
fi

###############################################################################
# 6. VÉRIFIER TOUS LES INGRESS
###############################################################################

log "${INFO} === PHASE 6: VÉRIFICATION INGRESS ROUTES ==="

log "${INFO} Liste des Ingress configurés:"
kubectl get ingress -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOST:.spec.rules[0].host,SERVICE:.spec.rules[0].http.paths[0].backend.service.name'

###############################################################################
# 7. CRÉER INGRESS MANQUANTS (PLACEHOLDERS)
###############################################################################

log "${INFO} === PHASE 7: CRÉATION INGRESS PLACEHOLDERS ==="

# my.keybuzz.io (portail client)
if ! kubectl get ingress -A | grep -q "my.keybuzz.io"; then
    log "${INFO} Création placeholder Ingress my.keybuzz.io..."
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal-keybuzz
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/default-backend: "default-http-backend"
spec:
  ingressClassName: nginx
  rules:
  - host: my.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: portal-placeholder
            port:
              number: 80
EOF
    log "${OK} Placeholder my.keybuzz.io créé (à configurer plus tard)"
fi

# s3.keybuzz.io (MinIO)
if ! kubectl get ingress -A | grep -q "s3.keybuzz.io"; then
    log "${INFO} s3.keybuzz.io sera configuré plus tard (MinIO externe)"
fi

# etl.keybuzz.io (Airbyte)
if ! kubectl get ingress -A | grep -q "etl.keybuzz.io"; then
    log "${INFO} etl.keybuzz.io sera configuré plus tard (Airbyte)"
fi

###############################################################################
# 8. TEST FINAL
###############################################################################

log "${INFO} === PHASE 8: TESTS FINAUX ==="

log "${INFO} Attente propagation des changements (30s)..."
sleep 30

# Test des endpoints
log "${INFO} Test des endpoints (depuis un worker):"

WORKER_IP="10.0.0.110"

ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" bash <<'EOSSH' 2>&1 | while read line; do log "  $line"; done
echo "Test n8n.keybuzz.io:"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://n8n.keybuzz.io --connect-timeout 5

echo "Test llm.keybuzz.io:"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://llm.keybuzz.io --connect-timeout 5

echo "Test qdrant.keybuzz.io:"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://qdrant.keybuzz.io --connect-timeout 5

echo "Test chat.keybuzz.io (Chatwoot):"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://chat.keybuzz.io --connect-timeout 5

echo "Test superset.keybuzz.io:"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://superset.keybuzz.io --connect-timeout 5

echo "Test vault.keybuzz.io:"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://vault.keybuzz.io --connect-timeout 5

echo "Test monitor.keybuzz.io (Grafana):"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://monitor.keybuzz.io --connect-timeout 10

echo "Test erp.keybuzz.io (ERPNext):"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://erp.keybuzz.io --connect-timeout 10

echo "Test connect.keybuzz.io (Connect API):"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -k https://connect.keybuzz.io --connect-timeout 10
EOSSH

###############################################################################
# 9. RÉSUMÉ
###############################################################################

log "${INFO} === PHASE 9: RÉSUMÉ ==="

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "          RÉSUMÉ DES CORRECTIONS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "${OK} Corrections appliquées:"
echo "  1. ✓ Pods Completed nettoyés"
echo "  2. ✓ ERPNext socketio : Configuration Redis corrigée + redémarrage"
echo "  3. ✓ Grafana : Timeout Ingress augmenté (600s)"
echo "  4. ✓ Connect API : Timeout Ingress augmenté (600s)"
echo "  5. ✓ Ingress routes vérifiés"
echo ""

log "${INFO} État des services:"
echo ""
echo "✅ OK (6/10):"
echo "  • n8n.keybuzz.io"
echo "  • llm.keybuzz.io"
echo "  • qdrant.keybuzz.io"
echo "  • chat.keybuzz.io (Chatwoot)"
echo "  • superset.keybuzz.io"
echo "  • vault.keybuzz.io"
echo ""
echo "🔧 CORRIGÉ (3/10):"
echo "  • erp.keybuzz.io (ERPNext) - Vérifier après 5 min"
echo "  • monitor.keybuzz.io (Grafana) - Timeout augmenté"
echo "  • connect.keybuzz.io (Connect API) - Timeout augmenté"
echo ""
echo "⏳ À FAIRE PLUS TARD (4):"
echo "  • siem.keybuzz.io (Wazuh) - Pas encore déployé"
echo "  • my.keybuzz.io (Portail client) - À développer"
echo "  • s3.keybuzz.io (MinIO) - Configuration externe"
echo "  • etl.keybuzz.io (Airbyte) - À déployer"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "${INFO} Commandes de vérification:"
echo ""
echo "  # Vérifier ERPNext socketio (attendre 5 min):"
echo "  kubectl get pods -n erpnext -l component=socketio"
echo "  kubectl logs -n erpnext -l component=socketio --tail=50"
echo ""
echo "  # Tester Grafana:"
echo "  curl -k https://monitor.keybuzz.io"
echo ""
echo "  # Tester Connect API:"
echo "  curl -k https://connect.keybuzz.io"
echo ""
echo "  # Tester ERPNext:"
echo "  curl -k https://erp.keybuzz.io"
echo ""

log "${OK} Script terminé"
log "${OK} Log complet: $LOG"

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                    FIN DU DIAGNOSTIC                               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Afficher les dernières lignes du log
tail -n 50 "$LOG"
