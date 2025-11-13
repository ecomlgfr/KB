#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Dolibarr v18 LTS                             ║"
echo "║    (Facturation / CRM / Abonnements)                              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

echo ""
echo "Ce script déploie :"
echo "  1. Dolibarr v18 LTS (image officielle)"
echo "  2. PostgreSQL 16 (10.0.0.10:6432)"
echo "  3. Modules : Factures, Abonnements, Stripe, API REST"
echo "  4. Ingress : my.keybuzz.io"
echo "  5. 2 pods web + PDB"
echo ""

read -p "Déployer Dolibarr ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Charger credentials PostgreSQL
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO PostgreSQL credentials manquants"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création namespace erp ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace erp 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création base de données Dolibarr ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

export PGPASSWORD="$POSTGRES_PASSWORD"

# Créer la base dolibarr
echo "Création de la base de données dolibarr..."
psql -U postgres -h 10.0.0.10 -p 5432 -d postgres <<EOF
-- Créer user dolibarr s'il n'existe pas
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'dolibarr') THEN
        CREATE USER dolibarr WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN;
    END IF;
END
\$\$;

-- Créer base dolibarr s'il n'existe pas
SELECT 'CREATE DATABASE dolibarr WITH OWNER = dolibarr ENCODING = ''UTF8'' LC_COLLATE = ''en_US.UTF-8'' LC_CTYPE = ''en_US.UTF-8'' TEMPLATE = template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dolibarr')\gexec

-- Permissions
GRANT ALL PRIVILEGES ON DATABASE dolibarr TO dolibarr;
EOF

echo -e "$OK Base de données dolibarr créée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Création Secrets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create secret generic dolibarr-secrets -n erp \
  --from-literal=DOLI_DB_TYPE=pgsql \
  --from-literal=DOLI_DB_HOST=10.0.0.10 \
  --from-literal=DOLI_DB_PORT=6432 \
  --from-literal=DOLI_DB_NAME=dolibarr \
  --from-literal=DOLI_DB_USER=dolibarr \
  --from-literal=DOLI_DB_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=DOLI_ADMIN_LOGIN=admin \
  --from-literal=DOLI_ADMIN_PASSWORD="KeyBuzz2025!" \
  --from-literal=DOLI_URL_ROOT="http://my.keybuzz.io" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secrets créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Déploiement Dolibarr ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/dolibarr

kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dolibarr-documents
  namespace: erp
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dolibarr-web
  namespace: erp
  labels:
    app: dolibarr
    component: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: dolibarr
      component: web
  template:
    metadata:
      labels:
        app: dolibarr
        component: web
    spec:
      nodeSelector:
        role: apps
      containers:
      - name: dolibarr
        image: tuxgasy/dolibarr:18.0.2
        ports:
        - containerPort: 80
          name: http
        env:
        - name: DOLI_DB_TYPE
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_TYPE
        - name: DOLI_DB_HOST
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_HOST
        - name: DOLI_DB_PORT
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_PORT
        - name: DOLI_DB_NAME
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_NAME
        - name: DOLI_DB_USER
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_USER
        - name: DOLI_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_PASSWORD
        - name: DOLI_ADMIN_LOGIN
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_ADMIN_LOGIN
        - name: DOLI_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_ADMIN_PASSWORD
        - name: DOLI_URL_ROOT
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_URL_ROOT
        - name: DOLI_MODULES
          value: "modFacture,modPropale,modStripe,modAbonnement,modAPI"
        volumeMounts:
        - name: documents
          mountPath: /var/www/documents
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 5
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
      volumes:
      - name: documents
        persistentVolumeClaim:
          claimName: dolibarr-documents
---
apiVersion: v1
kind: Service
metadata:
  name: dolibarr
  namespace: erp
spec:
  selector:
    app: dolibarr
    component: web
  ports:
  - port: 80
    targetPort: 80
    name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dolibarr-ingress
  namespace: erp
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
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
            name: dolibarr
            port:
              number: 80
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: dolibarr-pdb
  namespace: erp
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: dolibarr
      component: web
EOF

echo -e "$OK Dolibarr déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Attente démarrage (2 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente initialisation Dolibarr..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods erp :"
kubectl get pods -n erp -o wide
echo ""

echo "Services :"
kubectl get svc -n erp
echo ""

echo "Ingress :"
kubectl get ingress -n erp
echo ""

echo "PVC :"
kubectl get pvc -n erp
echo ""

echo "PDB :"
kubectl get pdb -n erp
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Dolibarr déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 Accès Dolibarr :"
echo "  URL : http://my.keybuzz.io"
echo "  Login : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "📦 Modules activés :"
echo "  ✓ Factures (modFacture)"
echo "  ✓ Propositions commerciales (modPropale)"
echo "  ✓ Stripe (modStripe)"
echo "  ✓ Abonnements (modAbonnement)"
echo "  ✓ API REST (modAPI)"
echo ""
echo "🔐 Base de données :"
echo "  Type : PostgreSQL"
echo "  Host : 10.0.0.10:6432 (PgBouncer)"
echo "  Database : dolibarr"
echo "  User : dolibarr"
echo ""
echo "⚙️ Configuration :"
echo "  Replicas : 2"
echo "  PDB : minAvailable = 1"
echo "  Storage : 10Gi (documents)"
echo ""
echo "🔍 Premier accès :"
echo "  1. Ouvrir http://my.keybuzz.io"
echo "  2. Si wizard d'installation, suivre les étapes"
echo "  3. Configurer Stripe dans Modules → Stripe"
echo "  4. Activer API REST dans Modules → API"
echo ""
echo "Prochaine étape :"
echo "  ./16_deploy_airbyte_etl.sh"
echo ""

exit 0
