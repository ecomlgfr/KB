#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX Airbyte - Correction Bootloader Error                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

echo ""
echo "Ce script va :"
echo "  1. Désinstaller Airbyte actuel"
echo "  2. Réinstaller avec DB interne (plus simple)"
echo "  3. Utiliser MinIO interne"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Désinstallation Airbyte actuel ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm uninstall airbyte -n etl 2>/dev/null || true

# Attendre la suppression
sleep 10

# Supprimer les PVC
kubectl delete pvc -n etl --all

echo -e "$OK Ancienne installation supprimée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création config simplifiée (DB interne) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/airbyte

cat > /opt/keybuzz-installer/k8s-manifests/airbyte/values-simple.yaml <<'EOF'
# Airbyte OSS - config simplifiée avec DB interne

# DATABASE INTERNE (pas externe PostgreSQL)
global:
  database:
    type: internal

# PostgreSQL interne
postgresql:
  enabled: true
  auth:
    username: airbyte
    password: airbyte123
    database: airbyte

# MinIO interne
minio:
  enabled: true
  auth:
    rootUser: minioadmin
    rootPassword: minioadmin123
  persistence:
    enabled: true
    size: 10Gi

# Webapp
webapp:
  replicaCount: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  nodeSelector:
    role: apps

# Worker
worker:
  replicaCount: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
  nodeSelector:
    role: background

# Server
server:
  replicaCount: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

# Temporal
temporal:
  enabled: true
  replicaCount: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

# Ingress
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: etl.keybuzz.io
      paths:
        - path: /
          pathType: Prefix
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
EOF

echo -e "$OK Config simplifiée créée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Déploiement Airbyte (version simplifiée) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm upgrade --install airbyte airbyte/airbyte \
  --namespace etl \
  --values /opt/keybuzz-installer/k8s-manifests/airbyte/values-simple.yaml \
  --version 0.58.0 \
  --wait \
  --timeout 15m

if [ $? -eq 0 ]; then
    echo -e "$OK Airbyte déployé"
else
    echo -e "$KO Échec du déploiement Airbyte"
    echo ""
    echo "Vérification des erreurs :"
    kubectl get pods -n etl
    echo ""
    echo "Logs du bootloader (si présent) :"
    kubectl logs -n etl $(kubectl get pods -n etl -o name | grep bootloader) 2>/dev/null || echo "Pas de bootloader"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Attente démarrage complet (3 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente initialisation Airbyte..."
sleep 180

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods etl :"
kubectl get pods -n etl -o wide
echo ""

echo "Services :"
kubectl get svc -n etl
echo ""

echo "Ingress :"
kubectl get ingress -n etl
echo ""

echo "PVC :"
kubectl get pvc -n etl
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Airbyte ETL corrigé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 Accès Airbyte :"
echo "  URL : http://etl.keybuzz.io"
echo ""
echo "🔐 Credentials DB interne :"
echo "  Host : airbyte-postgresql.etl.svc"
echo "  Port : 5432"
echo "  Database : airbyte"
echo "  User : airbyte"
echo "  Password : airbyte123"
echo ""
echo "🗄️ MinIO interne :"
echo "  Endpoint : airbyte-minio.etl.svc:9000"
echo "  User : minioadmin"
echo "  Password : minioadmin123"
echo ""
echo "⚙️ Configuration :"
echo "  - DB PostgreSQL interne (pas externe)"
echo "  - MinIO interne (pas KeyBuzz)"
echo "  - Webapp : 1 replica"
echo "  - Worker : 1 replica"
echo ""
echo "📝 Pour connecter aux sources externes :"
echo "  1. Accéder à http://etl.keybuzz.io"
echo "  2. Créer un compte admin"
echo "  3. Configurer connecteurs :"
echo "     - PostgreSQL KeyBuzz : 10.0.0.10:5433"
echo "     - MinIO KeyBuzz : http://s3.keybuzz.io"
echo ""

exit 0
