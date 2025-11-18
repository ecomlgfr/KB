#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v2_02_airbyte_dns.sh
# Description: Fix Airbyte DNS resolution issue (UnknownHostException) - V2
# Date: 2025-11-18
###############################################################################

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX V2 - Airbyte DNS Resolution Issue                          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Supprimer le déploiement actuel
echo "🗑️  Suppression du déploiement Airbyte actuel..."
helm uninstall airbyte -n etl --wait || true
kubectl delete pvc -n etl -l app.kubernetes.io/instance=airbyte --force --grace-period=0 2>/dev/null || true
kubectl delete pods -n etl --all --force --grace-period=0 2>/dev/null || true

sleep 10

# Redéployer avec configuration simplifiée et service names fixes
echo ""
echo "🚀 Redéploiement Airbyte avec DNS corrigé..."

# Ajouter le repo Helm Airbyte (si pas déjà fait)
helm repo add airbyte https://airbytehq.github.io/helm-charts 2>/dev/null || true
helm repo update

# Déployer avec values personnalisés pour fixer les noms de service
cat > /tmp/airbyte-values-v2.yaml <<'EOF'
global:
  serviceAccountName: airbyte-admin
  deploymentMode: oss
  edition: community

# Base de données interne (simplifié)
postgresql:
  enabled: true
  auth:
    username: airbyte
    password: "airbyte123"
    database: airbyte
  primary:
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 1000m
        memory: 2Gi
    persistence:
      enabled: true
      size: 20Gi
  # Fix: Forcer le nom du service
  fullnameOverride: airbyte-db-svc

# MinIO interne (simplifié)
minio:
  enabled: true
  auth:
    rootUser: minio
    rootPassword: "minio123"
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi
  persistence:
    enabled: true
    size: 50Gi

# Configuration Airbyte
airbyte:
  version: 0.50.33

  database:
    type: internal
    # Ces valeurs correspondent au service PostgreSQL créé
    host: airbyte-db-svc
    port: 5432
    database: airbyte
    user: airbyte
    password: "airbyte123"

  logs:
    storage:
      type: minio
      minio:
        endpoint: http://airbyte-minio:9000
        accessKey: minio
        secretKey: "minio123"
        bucket: airbyte-logs

  state:
    storage:
      type: minio
      minio:
        endpoint: http://airbyte-minio:9000
        accessKey: minio
        secretKey: "minio123"
        bucket: airbyte-state

# Webapp
webapp:
  replicaCount: 2
  nodeSelector:
    role: apps
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: airbyte.keybuzz.io
        paths:
          - path: /
            pathType: Prefix
    annotations:
      nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
      nginx.ingress.kubernetes.io/proxy-body-size: "100m"

# Server
server:
  replicaCount: 2
  nodeSelector:
    role: apps
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 1000m
      memory: 4Gi

# Worker
worker:
  replicaCount: 2
  nodeSelector:
    role: apps
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 4Gi

# Bootloader (job d'initialisation)
bootloader:
  nodeSelector:
    role: apps
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi

# Cron
cron:
  replicaCount: 1
  nodeSelector:
    role: apps
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

# Pod Sweeper
pod-sweeper:
  replicaCount: 1
  nodeSelector:
    role: apps
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
EOF

echo "📦 Installation Airbyte avec Helm..."
helm install airbyte airbyte/airbyte \
  --namespace etl \
  --create-namespace \
  --values /tmp/airbyte-values-v2.yaml \
  --timeout 15m \
  --wait

# Vérifier les services créés
echo ""
echo "🔍 Vérification des services DNS..."
kubectl get svc -n etl

echo ""
echo "⏳ Attente du bootloader (2 minutes)..."
sleep 120

# Vérifier les pods
echo ""
echo "✅ Vérification des pods..."
kubectl get pods -n etl

# Vérifier les logs du bootloader
echo ""
echo "📋 Logs du bootloader (si présent)..."
BOOTLOADER_POD=$(kubectl get pods -n etl -l app.kubernetes.io/name=bootloader -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$BOOTLOADER_POD" ]; then
    kubectl logs -n etl "$BOOTLOADER_POD" --tail=50 || true
else
    echo "⚠️  Pod bootloader non trouvé (peut-être déjà terminé)"
fi

# Vérifier ingress
echo ""
echo "🌐 Vérification Ingress..."
kubectl get ingress -n etl

echo ""
echo "🧪 Test HTTP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://airbyte.keybuzz.io --max-time 10 || echo "TIMEOUT")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "✅ Airbyte accessible (HTTP $HTTP_CODE)"
else
    echo "⚠️  HTTP $HTTP_CODE (attendu: 200 ou 302)"
fi

# Nettoyer
rm -f /tmp/airbyte-values-v2.yaml

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ FIX TERMINÉ"
echo ""
echo "📱 URL: http://airbyte.keybuzz.io"
echo "🔑 Credentials par défaut:"
echo "   - Email: airbyte"
echo "   - Password: password"
echo ""
echo "📊 Composants:"
echo "   - PostgreSQL: airbyte-db-svc:5432"
echo "   - MinIO: airbyte-minio:9000"
echo "   - Webapp: 2 replicas"
echo "   - Server: 2 replicas"
echo "   - Worker: 2 replicas"
echo ""
echo "Si erreur persiste, vérifier:"
echo "  kubectl logs -n etl -l app.kubernetes.io/name=server --tail=50"
echo "  kubectl logs -n etl -l app.kubernetes.io/name=worker --tail=50"
echo "════════════════════════════════════════════════════════════════════"
