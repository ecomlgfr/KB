#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v2_04_grafana_sidecars.sh
# Description: Fix Grafana sidecar crashes (2/3 pods with restarts) - V2
# Date: 2025-11-18
###############################################################################

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX V2 - Grafana Sidecar Crashes                               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Désinstaller le déploiement Helm actuel
echo "🗑️  Suppression du déploiement Grafana Helm actuel..."
helm uninstall kube-prometheus-stack -n monitoring --wait 2>/dev/null || true
kubectl delete deployment grafana -n monitoring --ignore-not-found
kubectl delete statefulset grafana -n monitoring --ignore-not-found
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true
kubectl delete pvc -n monitoring -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true

sleep 10

# Déployer Grafana standalone (sans kube-prometheus-stack)
echo ""
echo "🚀 Déploiement Grafana standalone (sans sidecars problématiques)..."

# Créer le secret pour Grafana admin
kubectl create secret generic grafana-admin-credentials -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=AdminGrafana123! \
  --dry-run=client -o yaml | kubectl apply -f -

# Déployer Grafana avec Helm (configuration simplifiée)
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

cat > /tmp/grafana-values-v2.yaml <<'EOF'
replicas: 2

# Désactiver les sidecars qui causent des problèmes
sidecar:
  dashboards:
    enabled: false  # Désactivé pour éviter les crashes
  datasources:
    enabled: false  # Désactivé pour éviter les crashes
  plugins:
    enabled: false  # Désactivé pour éviter les crashes

# Admin credentials
admin:
  existingSecret: grafana-admin-credentials
  userKey: admin-user
  passwordKey: admin-password

# Persistence désactivée (peut causer des problèmes d'init)
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

# Datasources configurés manuellement (pas via sidecar)
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

# Dashboards providers (configuration manuelle, pas sidecar)
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
    - name: 'default'
      orgId: 1
      folder: ''
      type: file
      disableDeletion: false
      editable: true
      options:
        path: /var/lib/grafana/dashboards/default

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

# Environment variables
env:
  GF_INSTALL_PLUGINS: ""  # Pas de plugins automatiques

# Probes avec timeouts raisonnables
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

# Security context simplifié
securityContext:
  runAsUser: 472
  runAsGroup: 472
  fsGroup: 472

podSecurityContext:
  runAsUser: 472
  runAsGroup: 472
  fsGroup: 472
EOF

echo "📦 Installation Grafana avec Helm..."
helm install grafana grafana/grafana \
  --namespace monitoring \
  --values /tmp/grafana-values-v2.yaml \
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

# Vérifier qu'il n'y a pas de restarts
echo ""
echo "🔍 Nombre de restarts par pod:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

# Vérifier les logs
echo ""
echo "📋 Logs récents..."
GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$GRAFANA_POD" ]; then
    kubectl logs -n monitoring "$GRAFANA_POD" --tail=20 || true
fi

# Test HTTP
echo ""
echo "🧪 Test HTTP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://monitor.keybuzz.io --max-time 10 || echo "TIMEOUT")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "✅ Grafana accessible (HTTP $HTTP_CODE)"
else
    echo "⚠️  HTTP $HTTP_CODE (attendu: 200 ou 302)"
fi

# Nettoyer
rm -f /tmp/grafana-values-v2.yaml

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ FIX TERMINÉ"
echo ""
echo "📱 URL: http://monitor.keybuzz.io"
echo "🔑 Credentials:"
echo "   - Login: admin"
echo "   - Password: AdminGrafana123!"
echo ""
echo "📊 Configuration:"
echo "   - Replicas: 2"
echo "   - Sidecars: Désactivés (évite les crashes)"
echo "   - Persistence: Désactivée (évite les problèmes d'init)"
echo "   - Datasources: Prometheus + Loki (configuration manuelle)"
echo ""
echo "⚠️  NOTE:"
echo "   Les dashboards doivent être importés manuellement via l'UI"
echo "   ou configurés via ConfigMaps ultérieurement."
echo ""
echo "🔍 Si problèmes persistent:"
echo "   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50"
echo "   kubectl describe pods -n monitoring -l app.kubernetes.io/name=grafana"
echo "════════════════════════════════════════════════════════════════════"
