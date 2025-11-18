#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v3_03_dolibarr_init.sh
# Description: Fix Dolibarr initialization - V3 (avec création secret)
# Date: 2025-11-18
###############################################################################

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX V3 - Dolibarr Initialization (CORRIGÉ)                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Créer le namespace si manquant
kubectl create namespace erp 2>/dev/null || true

# Récupérer ou créer le mot de passe PostgreSQL
echo "🔑 Vérification/création du secret Dolibarr..."
POSTGRES_PASSWORD=$(kubectl get secret -n postgres postgres-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || echo "ChangeMe123!")

# Créer le secret Dolibarr si manquant
if ! kubectl get secret dolibarr-secrets -n erp &>/dev/null; then
    echo "Création du secret dolibarr-secrets..."
    kubectl create secret generic dolibarr-secrets -n erp \
      --from-literal=DATABASE_USER=dolibarr \
      --from-literal=DATABASE_PASSWORD="$POSTGRES_PASSWORD"
    echo "✅ Secret créé"
else
    echo "✅ Secret existe déjà"
fi

# Vérifier/créer la base de données
echo ""
echo "🔍 Vérification de la base de données..."

if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 6432 -U dolibarr -d dolibarr -c "SELECT 1" &>/dev/null; then
    echo "✅ Base de données accessible"
else
    echo "Création de la base de données dolibarr..."
    # Créer via port 5432 (direct PostgreSQL, pas PgBouncer)
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U postgres -d postgres <<EOF
CREATE USER dolibarr WITH PASSWORD '$POSTGRES_PASSWORD';
CREATE DATABASE dolibarr WITH OWNER = dolibarr;
GRANT ALL PRIVILEGES ON DATABASE dolibarr TO dolibarr;
EOF
    echo "✅ Base de données créée"
fi

# Supprimer le déploiement actuel
echo ""
echo "🗑️  Suppression du déploiement actuel..."
kubectl delete deployment dolibarr-web dolibarr-cron -n erp --ignore-not-found
kubectl delete pod -n erp --all --force --grace-period=0 2>/dev/null || true

sleep 10

# Redéployer avec configuration optimisée
echo ""
echo "🚀 Déploiement Dolibarr..."

kubectl apply -f - <<'YAML'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dolibarr-web
  namespace: erp
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
      # Init container pour attendre la DB
      initContainers:
      - name: wait-for-db
        image: postgres:16-alpine
        command:
        - sh
        - -c
        - |
          echo "Attente de la base de données..."
          until pg_isready -h $DATABASE_HOST -p $DATABASE_PORT -U $DATABASE_USER; do
            echo "DB non prête, attente 5s..."
            sleep 5
          done
          echo "✅ Base de données prête"
        env:
        - name: DATABASE_HOST
          value: "10.0.0.10"
        - name: DATABASE_PORT
          value: "6432"
        - name: DATABASE_USER
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DATABASE_USER
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DATABASE_PASSWORD
      containers:
      - name: dolibarr
        image: tuxgasy/dolibarr:18
        ports:
        - containerPort: 80
          name: http
        env:
        - name: DOLI_DB_HOST
          value: "10.0.0.10"
        - name: DOLI_DB_PORT
          value: "6432"
        - name: DOLI_DB_NAME
          value: "dolibarr"
        - name: DOLI_DB_USER
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DATABASE_USER
        - name: DOLI_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DATABASE_PASSWORD
        - name: DOLI_DB_TYPE
          value: "pgsql"
        - name: DOLI_URL_ROOT
          value: "http://erp.keybuzz.io"
        - name: DOLI_ADMIN_LOGIN
          value: "admin"
        - name: DOLI_ADMIN_PASSWORD
          value: "Admin123!"
        - name: DOLI_MODULES
          value: "modSociete,modFacture,modPropale,modProduct,modStock"
        - name: PHP_INI_MEMORY_LIMIT
          value: "512M"
        - name: PHP_INI_UPLOAD_MAX_FILESIZE
          value: "20M"
        - name: PHP_INI_POST_MAX_SIZE
          value: "22M"
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
        # Probes avec timeouts longs pour initialisation
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 180
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 120
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 10
        volumeMounts:
        - name: dolibarr-data
          mountPath: /var/www/html/documents
        - name: dolibarr-custom
          mountPath: /var/www/html/custom
      volumes:
      - name: dolibarr-data
        emptyDir: {}
      - name: dolibarr-custom
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dolibarr-cron
  namespace: erp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dolibarr
      component: cron
  template:
    metadata:
      labels:
        app: dolibarr
        component: cron
    spec:
      nodeSelector:
        role: background
      containers:
      - name: dolibarr-cron
        image: tuxgasy/dolibarr:18
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Starting cron daemon..."
          while true; do
            sleep 3600
            curl -s http://dolibarr-svc/cron/cron_run_jobs.php?securitykey=cronkey || true
          done
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 200m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: dolibarr-svc
  namespace: erp
spec:
  selector:
    app: dolibarr
    component: web
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
    name: http
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dolibarr-ingress
  namespace: erp
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "20m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
spec:
  ingressClassName: nginx
  rules:
  - host: erp.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: dolibarr-svc
            port:
              number: 80
YAML

# Attendre l'initialisation
echo ""
echo "⏳ Attente de l'initialisation (3 minutes)..."
echo "   Dolibarr doit créer ses tables et configurer la base..."
sleep 180

# Vérifier les pods
echo ""
echo "✅ Vérification des pods..."
kubectl get pods -n erp

# Vérifier les logs
echo ""
echo "📋 Logs récents..."
WEB_POD=$(kubectl get pods -n erp -l component=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$WEB_POD" ]; then
    echo "Pod: $WEB_POD"
    kubectl logs -n erp "$WEB_POD" --tail=30 || true
fi

# Test HTTP
echo ""
echo "🧪 Test HTTP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://erp.keybuzz.io --max-time 30 || echo "TIMEOUT")

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Dolibarr opérationnel (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "202" ]; then
    echo "⏳ Dolibarr en cours d'initialisation (HTTP 202)"
    echo "   Attendre encore 2-3 minutes puis réessayer"
else
    echo "⚠️  HTTP $HTTP_CODE"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ FIX V3 TERMINÉ"
echo ""
echo "📱 URL: http://erp.keybuzz.io"
echo "🔑 Credentials:"
echo "   - Login: admin"
echo "   - Password: Admin123!"
echo ""
echo "⚠️  IMPORTANT:"
echo "   Si HTTP 202, Dolibarr est en train de s'initialiser."
echo "   Cela peut prendre jusqu'à 5 minutes au premier démarrage."
echo ""
echo "🔍 Suivre l'initialisation:"
echo "   kubectl logs -n erp -l component=web -f"
echo "   curl -v http://erp.keybuzz.io"
echo "════════════════════════════════════════════════════════════════════"
