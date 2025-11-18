#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v3_04_grafana_sidecars.sh
# Description: Fix Grafana sidecars - V3 (gestion secret existant)
# Date: 2025-11-18
###############################################################################

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX V3 - Grafana Sidecar Crashes (CORRIGÉ)                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Créer le namespace si manquant
kubectl create namespace monitoring 2>/dev/null || true

# Désinstaller les déploiements actuels
echo "🗑️  Suppression des déploiements Grafana actuels..."
helm uninstall kube-prometheus-stack -n monitoring --wait 2>/dev/null || true
helm uninstall grafana -n monitoring --wait 2>/dev/null || true
kubectl delete deployment grafana -n monitoring --ignore-not-found
kubectl delete statefulset grafana -n monitoring --ignore-not-found
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true
kubectl delete pvc -n monitoring -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true

sleep 10

# Créer/recréer le secret (utiliser apply au lieu de create)
echo ""
echo "🔑 Configuration du secret Grafana..."
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-credentials
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: AdminGrafana123!
YAML

echo "✅ Secret configuré"

# Déployer Grafana standalone simplifié
echo ""
echo "🚀 Déploiement Grafana standalone..."

# Ajouter le repo Helm Grafana
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

cat > /tmp/grafana-values-v3.yaml <<'EOF'
replicas: 2

# Désactiver TOUS les sidecars
sidecar:
  dashboards:
    enabled: false
  datasources:
    enabled: false
  plugins:
    enabled: false
  notifiers:
    enabled: false

# Admin credentials
admin:
  existingSecret: grafana-admin-credentials
  userKey: admin-user
  passwordKey: admin-password

# Pas de persistence (simplifie l'init)
persistence:
  enabled: false

# Resources
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi

# Node selector
nodeSelector:
  role: apps

# Service
service:
  type: ClusterIP
  port: 80
  targetPort: 3000

# Ingress
ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
  hosts:
    - monitor.keybuzz.io
  path: /
  pathType: Prefix

# Datasources (configuration manuelle)
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-operated:9090
      access: proxy
      isDefault: true
      editable: true
    - name: Loki
      type: loki
      url: http://loki:3100
      access: proxy
      editable: true

# Configuration Grafana
grafana.ini:
  server:
    root_url: http://monitor.keybuzz.io
    serve_from_sub_path: false
  security:
    admin_user: admin
    admin_password: AdminGrafana123!
  users:
    allow_sign_up: false
  auth.anonymous:
    enabled: false
  log:
    mode: console
    level: info

# Pas de plugins automatiques
env:
  GF_INSTALL_PLUGINS: ""

# Probes
livenessProbe:
  httpGet:
    path: /api/health
    port: 3000
  initialDelaySeconds: 60
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /api/health
    port: 3000
  initialDelaySeconds: 30
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3

# Pas d'init containers problématiques
initChownData:
  enabled: false

# Security context
securityContext:
  runAsUser: 472
  runAsGroup: 472
  fsGroup: 472

podSecurityContext:
  runAsUser: 472
  runAsGroup: 472
  fsGroup: 472

# Dashboard providers (vide pour éviter les sidecars)
dashboardProviders: {}

# Dashboards (vides pour éviter les sidecars)
dashboards: {}
EOF

echo "📦 Installation Grafana avec Helm..."
helm install grafana grafana/grafana \
  --namespace monitoring \
  --values /tmp/grafana-values-v3.yaml \
  --timeout 5m \
  --wait

# Attendre le démarrage
echo ""
echo "⏳ Attente du démarrage (90s)..."
sleep 90

# Vérifier les pods
echo ""
echo "✅ Vérification des pods..."
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# Compter les restarts
echo ""
echo "🔍 Nombre de restarts par pod:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' || echo "Aucun pod trouvé"

# Vérifier les logs
echo ""
echo "📋 Logs récents..."
GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$GRAFANA_POD" ]; then
    echo "Pod: $GRAFANA_POD"
    kubectl logs -n monitoring "$GRAFANA_POD" --tail=20 || true
fi

# Test HTTP
echo ""
echo "🧪 Test HTTP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://monitor.keybuzz.io --max-time 10 || echo "TIMEOUT")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "✅ Grafana opérationnel (HTTP $HTTP_CODE)"
else
    echo "⚠️  HTTP $HTTP_CODE (attendu: 200 ou 302)"
fi

# Nettoyer
rm -f /tmp/grafana-values-v3.yaml

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ FIX V3 TERMINÉ"
echo ""
echo "📱 URL: http://monitor.keybuzz.io"
echo "🔑 Credentials:"
echo "   - Login: admin"
echo "   - Password: AdminGrafana123!"
echo ""
echo "📊 Configuration:"
echo "   - Replicas: 2"
echo "   - Sidecars: TOUS désactivés"
echo "   - Persistence: Désactivée"
echo "   - Datasources: Prometheus + Loki (manuel)"
echo ""
echo "⚠️  NOTE:"
echo "   Dashboards à importer manuellement via l'UI Grafana"
echo "   ou à configurer via ConfigMaps ultérieurement."
echo ""
echo "🔍 Si problèmes persistent:"
echo "   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=100"
echo "   kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana"
echo "════════════════════════════════════════════════════════════════════"
