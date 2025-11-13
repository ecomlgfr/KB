#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Airbyte OSS (ETL)                            ║"
echo "║    (Data synchronization + PostgreSQL + MinIO)                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

echo ""
echo "Ce script déploie :"
echo "  1. Airbyte OSS 0.58.x"
echo "  2. Web UI + Worker + Temporal"
echo "  3. Connecteurs PostgreSQL (read 5433)"
echo "  4. Connecteur MinIO (S3)"
echo "  5. Ingress : etl.keybuzz.io"
echo "  6. NodeSelector : role=background"
echo ""

read -p "Déployer Airbyte ETL ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Charger credentials PostgreSQL
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO PostgreSQL credentials manquants"
    exit 1
fi

# Vérifier Helm
if ! command -v helm &> /dev/null; then
    echo -e "$KO Helm non installé"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création namespace etl ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace etl 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création base de données Airbyte ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

export PGPASSWORD="$POSTGRES_PASSWORD"

echo "Création de la base de données airbyte..."
psql -U postgres -h 10.0.0.10 -p 5432 -d postgres <<EOF
-- Créer user airbyte s'il n'existe pas
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'airbyte') THEN
        CREATE USER airbyte WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN;
    END IF;
END
\$\$;

-- Créer base airbyte s'il n'existe pas
SELECT 'CREATE DATABASE airbyte WITH OWNER = airbyte ENCODING = ''UTF8'' LC_COLLATE = ''en_US.UTF-8'' LC_CTYPE = ''en_US.UTF-8'' TEMPLATE = template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'airbyte')\gexec

-- Permissions
GRANT ALL PRIVILEGES ON DATABASE airbyte TO airbyte;
EOF

echo -e "$OK Base de données airbyte créée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Ajout repo Helm Airbyte ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm repo add airbyte https://airbytehq.github.io/helm-charts
helm repo update

echo -e "$OK Repo Airbyte ajouté"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Création values Airbyte ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/airbyte

cat > /opt/keybuzz-installer/k8s-manifests/airbyte/values.yaml <<EOF
# Airbyte OSS values
global:
  database:
    type: external
    host: 10.0.0.10
    port: 6432
    database: airbyte
    user: airbyte
    password: ${POSTGRES_PASSWORD}

webapp:
  replicaCount: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
  nodeSelector:
    role: apps

worker:
  replicaCount: 2
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi
  nodeSelector:
    role: background

server:
  replicaCount: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi

temporal:
  enabled: true
  replicaCount: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

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

# Logs
logs:
  persistence:
    enabled: true
    size: 20Gi

# Minio (internal pour Airbyte state)
minio:
  enabled: false  # On utilise MinIO externe

# External storage (MinIO KeyBuzz)
# Configuré via UI après déploiement
EOF

echo -e "$OK Values Airbyte créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Déploiement Airbyte ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm upgrade --install airbyte airbyte/airbyte \
  --namespace etl \
  --values /opt/keybuzz-installer/k8s-manifests/airbyte/values.yaml \
  --version 0.58.0 \
  --wait \
  --timeout 10m

echo -e "$OK Airbyte déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Configuration PodDisruptionBudget ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: airbyte-worker-pdb
  namespace: etl
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: airbyte
      app.kubernetes.io/component: worker
EOF

echo -e "$OK PDB configuré"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Attente démarrage (2 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente initialisation Airbyte..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Vérification ═══"
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

echo "PDB :"
kubectl get pdb -n etl
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Airbyte ETL déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 Accès Airbyte :"
echo "  URL : http://etl.keybuzz.io"
echo "  Premier accès : créer un compte admin"
echo ""
echo "🔌 Connecteurs à configurer :"
echo "  1. PostgreSQL Source (lecture) :"
echo "     Host : 10.0.0.10"
echo "     Port : 5433 (read-only via HAProxy)"
echo "     Database : <base_source>"
echo "     User : postgres"
echo "     Password : ${POSTGRES_PASSWORD}"
echo ""
echo "  2. PostgreSQL Destination :"
echo "     Host : 10.0.0.10"
echo "     Port : 6432 (PgBouncer)"
echo "     Database : <base_destination>"
echo ""
echo "  3. MinIO (S3) :"
echo "     Endpoint : http://s3.keybuzz.io"
echo "     Bucket : keybuzz-data"
echo "     Access Key : <voir MinIO>"
echo ""
echo "⚙️ Configuration :"
echo "  Webapp : 1 replica (role=apps)"
echo "  Workers : 2 replicas (role=background)"
echo "  PDB : minAvailable = 1"
echo "  Storage : 20Gi (logs)"
echo ""
echo "🔍 Synchronisations typiques :"
echo "  - PostgreSQL → MinIO (backup/export)"
echo "  - PostgreSQL → PostgreSQL (réplication logique)"
echo "  - MinIO → PostgreSQL (import données)"
echo ""
echo "Prochaine étape :"
echo "  ./18_final_validation_complete.sh"
echo ""

exit 0
