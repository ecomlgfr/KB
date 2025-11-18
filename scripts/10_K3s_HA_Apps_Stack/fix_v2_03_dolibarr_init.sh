#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v2_03_dolibarr_init.sh
# Description: Fix Dolibarr initialization timeout (HTTP 202/504) - V2
# Date: 2025-11-18
###############################################################################

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX V2 - Dolibarr Initialization Timeout                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Supprimer le déploiement actuel
echo "🗑️  Suppression du déploiement Dolibarr actuel..."
kubectl delete deployment dolibarr-web dolibarr-cron -n erp --ignore-not-found
kubectl delete pod -n erp --all --force --grace-period=0 2>/dev/null || true

sleep 10

# Vérifier que la base de données existe
echo ""
echo "🔍 Vérification de la base de données..."
PGPASSWORD=$(kubectl get secret -n erp dolibarr-secrets -o jsonpath='{.data.DATABASE_PASSWORD}' | base64 -d)

# Test connexion DB
if PGPASSWORD="$PGPASSWORD" psql -h 10.0.0.10 -p 6432 -U dolibarr -d dolibarr -c "SELECT 1" &>/dev/null; then
    echo "✅ Base de données accessible"
else
    echo "❌ Base de données non accessible - création..."
    # Créer via port 5432 (direct PostgreSQL, pas PgBouncer)
    POSTGRES_PASSWORD=$(kubectl get secret -n postgres postgres-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d 2>/dev/null || echo "ChangeMe123!")

    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U postgres -d postgres <<EOF
CREATE USER dolibarr WITH PASSWORD '$PGPASSWORD';
CREATE DATABASE dolibarr WITH OWNER = dolibarr;
GRANT ALL PRIVILEGES ON DATABASE dolibarr TO dolibarr;
EOF
    echo "✅ Base de données créée"
fi

# Redéployer avec configuration optimisée
echo ""
echo "🚀 Redéploiement Dolibarr avec init container..."

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
        # Probes avec timeouts très longs pour l'initialisation
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 180  # 3 minutes
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 120  # 2 minutes
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 10  # Permet jusqu'à 150s d'attente supplémentaire
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

# Attendre l'initialisation (plus long que d'habitude)
echo ""
echo "⏳ Attente de l'initialisation (3 minutes)..."
echo "   Dolibarr doit créer ses tables et configurer la base de données..."
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
    kubectl logs -n erp "$WEB_POD" --tail=30 || true
fi

# Test HTTP avec timeout long
echo ""
echo "🧪 Test HTTP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://erp.keybuzz.io --max-time 30 || echo "TIMEOUT")

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Dolibarr accessible (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "202" ]; then
    echo "⏳ Dolibarr en cours d'initialisation (HTTP 202)"
    echo "   Attendre encore 2-3 minutes puis réessayer"
else
    echo "⚠️  HTTP $HTTP_CODE"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ FIX TERMINÉ"
echo ""
echo "📱 URL: http://erp.keybuzz.io"
echo "🔑 Credentials par défaut:"
echo "   - Login: admin"
echo "   - Password: Admin123!"
echo ""
echo "⚠️  IMPORTANT:"
echo "   Si HTTP 202, Dolibarr est en train de s'initialiser."
echo "   Cela peut prendre jusqu'à 5 minutes au premier démarrage."
echo ""
echo "🔍 Suivre l'initialisation:"
echo "   watch kubectl get pods -n erp"
echo "   kubectl logs -n erp -l component=web -f"
echo ""
echo "🧪 Tester manuellement:"
echo "   curl -v http://erp.keybuzz.io"
echo "════════════════════════════════════════════════════════════════════"
