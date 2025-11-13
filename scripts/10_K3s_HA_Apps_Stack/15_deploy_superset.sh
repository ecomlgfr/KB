#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Déploiement Superset - Business Intelligence Platform          ║"
echo "║    (Init DB + Admin User + Web)                                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Charger credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO PostgreSQL credentials manquants"
    exit 1
fi

echo ""
echo "Configuration Superset :"
echo "  - PostgreSQL : 10.0.0.10:5432"
echo "  - Redis : 10.0.0.10:6379 (cache)"
echo "  - Admin : admin / Admin123!"
echo ""
echo "⚠️  IMPORTANT :"
echo "  Init DB obligatoire avant premier démarrage"
echo "  Création user admin automatique"
echo ""

read -p "Déployer Superset ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création namespace ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace superset 2>/dev/null || true
echo -e "$OK Namespace créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Génération secrets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Générer clés secrètes
SECRET_KEY=$(openssl rand -base64 42)
SUPERSET_ADMIN_USER="admin"
SUPERSET_ADMIN_PASSWORD="Admin123!"
SUPERSET_ADMIN_EMAIL="admin@keybuzz.io"

echo "  ✓ SECRET_KEY généré"
echo "  ✓ Admin user : $SUPERSET_ADMIN_USER"
echo "  ✓ Admin email : $SUPERSET_ADMIN_EMAIL"

# Charger Redis password
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    REDIS_PASSWORD="keybuzz2025"
fi

# Créer le secret K8s
kubectl create secret generic superset-secrets -n superset \
  --from-literal=DATABASE_URL="postgresql://superset:${POSTGRES_PASSWORD}@10.0.0.10:5432/superset" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379/1" \
  --from-literal=SECRET_KEY="$SECRET_KEY" \
  --from-literal=SUPERSET_ADMIN_USER="$SUPERSET_ADMIN_USER" \
  --from-literal=SUPERSET_ADMIN_PASSWORD="$SUPERSET_ADMIN_PASSWORD" \
  --from-literal=SUPERSET_ADMIN_EMAIL="$SUPERSET_ADMIN_EMAIL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secrets créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Job Init DB ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Création job d'initialisation DB..."

kubectl apply -f - <<'EOF'
---
apiVersion: batch/v1
kind: Job
metadata:
  name: superset-init-db
  namespace: superset
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: init-db
        image: apache/superset:latest
        command: ["/bin/bash"]
        args:
          - -c
          - |
            set -e
            echo "Initialisation de la base de données Superset..."
            superset db upgrade
            echo "✓ Base de données initialisée"
        env:
        - name: SUPERSET_CONFIG_PATH
          value: /app/pythonpath/superset_config.py
        - name: DATABASE_DIALECT
          value: postgresql
        - name: DATABASE_HOST
          value: "10.0.0.10"
        - name: DATABASE_PORT
          value: "5432"
        - name: DATABASE_DB
          value: superset
        - name: DATABASE_USER
          value: superset
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: REDIS_HOST
          value: "10.0.0.10"
        - name: REDIS_PORT
          value: "6379"
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SQLALCHEMY_DATABASE_URI
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        volumeMounts:
        - name: superset-config
          mountPath: /app/pythonpath
      volumes:
      - name: superset-config
        configMap:
          name: superset-config
EOF

echo -e "$OK Job init DB créé"

echo ""
echo "Attente fin de l'initialisation (peut prendre 2-3 minutes)..."

# Attendre que le job se termine
for i in {1..120}; do
    JOB_STATUS=$(kubectl get job superset-init-db -n superset -o jsonpath='{.status.succeeded}' 2>/dev/null)
    
    if [ "$JOB_STATUS" = "1" ]; then
        echo -e "$OK Init DB terminée"
        break
    fi
    
    JOB_FAILED=$(kubectl get job superset-init-db -n superset -o jsonpath='{.status.failed}' 2>/dev/null)
    if [ ! -z "$JOB_FAILED" ] && [ "$JOB_FAILED" -gt 0 ]; then
        echo -e "$WARN Job échoué, vérification des logs..."
        kubectl logs -n superset job/superset-init-db --tail=30
        break
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Attente... ($i/120)"
    fi
    
    sleep 1
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Job Création Admin User ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Création job pour admin user..."

kubectl apply -f - <<'EOF'
---
apiVersion: batch/v1
kind: Job
metadata:
  name: superset-create-admin
  namespace: superset
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: create-admin
        image: apache/superset:latest
        command: ["/bin/bash"]
        args:
          - -c
          - |
            set -e
            echo "Création de l'utilisateur admin..."
            superset fab create-admin \
              --username ${SUPERSET_ADMIN_USER} \
              --firstname Admin \
              --lastname User \
              --email ${SUPERSET_ADMIN_EMAIL} \
              --password ${SUPERSET_ADMIN_PASSWORD} || echo "User admin existe déjà"
            
            echo "Initialisation des rôles et permissions..."
            superset init || echo "Déjà initialisé"
            
            echo "✓ Admin user créé"
        env:
        - name: SUPERSET_ADMIN_USER
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SUPERSET_ADMIN_USER
        - name: SUPERSET_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SUPERSET_ADMIN_PASSWORD
        - name: SUPERSET_ADMIN_EMAIL
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SUPERSET_ADMIN_EMAIL
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SQLALCHEMY_DATABASE_URI
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
EOF

echo -e "$OK Job création admin créé"

echo ""
echo "Attente fin de la création admin (1-2 minutes)..."

for i in {1..60}; do
    JOB_STATUS=$(kubectl get job superset-create-admin -n superset -o jsonpath='{.status.succeeded}' 2>/dev/null)
    
    if [ "$JOB_STATUS" = "1" ]; then
        echo -e "$OK Admin user créé"
        break
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Attente... ($i/60)"
    fi
    
    sleep 1
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Déploiement Superset Web ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: superset-config
  namespace: superset
data:
  superset_config.py: |
    import os
    
    # Superset configuration
    SECRET_KEY = os.environ.get('SECRET_KEY', 'change-this-secret-key')
    SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL', 'postgresql://superset:superset@localhost/superset')
    
    # Redis configuration
    REDIS_HOST = os.environ.get('REDIS_HOST', '10.0.0.10')
    REDIS_PORT = os.environ.get('REDIS_PORT', '6379')
    
    # Cache configuration
    CACHE_CONFIG = {
        'CACHE_TYPE': 'RedisCache',
        'CACHE_DEFAULT_TIMEOUT': 300,
        'CACHE_KEY_PREFIX': 'superset_',
        'CACHE_REDIS_HOST': REDIS_HOST,
        'CACHE_REDIS_PORT': REDIS_PORT,
        'CACHE_REDIS_DB': 1,
    }
    
    # Enable various features
    FEATURE_FLAGS = {
        'ENABLE_TEMPLATE_PROCESSING': True,
    }
    
    # Security
    WTF_CSRF_ENABLED = True
    WTF_CSRF_TIME_LIMIT = None
    
    # Public role
    PUBLIC_ROLE_LIKE = 'Gamma'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: superset
  namespace: superset
  labels:
    app: superset
spec:
  replicas: 2
  selector:
    matchLabels:
      app: superset
  template:
    metadata:
      labels:
        app: superset
    spec:
      containers:
      - name: superset
        image: apache/superset:latest
        ports:
        - containerPort: 8088
          name: http
          protocol: TCP
        env:
        - name: SUPERSET_CONFIG_PATH
          value: /app/pythonpath/superset_config.py
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SQLALCHEMY_DATABASE_URI
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: REDIS_HOST
          value: "10.0.0.10"
        - name: REDIS_PORT
          value: "6379"
        volumeMounts:
        - name: superset-config
          mountPath: /app/pythonpath
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
      volumes:
      - name: superset-config
        configMap:
          name: superset-config
---
apiVersion: v1
kind: Service
metadata:
  name: superset
  namespace: superset
spec:
  type: ClusterIP
  selector:
    app: superset
  ports:
  - port: 8088
    targetPort: 8088
    name: http
EOF

echo -e "$OK Superset Web déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Création Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset
  namespace: superset
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
spec:
  ingressClassName: nginx
  rules:
  - host: superset.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: superset
            port:
              number: 8088
EOF

echo -e "$OK Ingress créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Attente démarrage (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods :"
kubectl get pods -n superset
echo ""

echo "Services :"
kubectl get svc -n superset
echo ""

echo "Ingress :"
kubectl get ingress -n superset
echo ""

echo "Jobs :"
kubectl get job -n superset

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Superset déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<SUMMARY
✅ Composants déployés :
  - superset : 2 réplicas (port 8088)
  - Init DB : Terminé
  - Admin user : Créé

Configuration :
  - PostgreSQL : 10.0.0.10:5432 (base superset)
  - Redis : 10.0.0.10:6379 (cache)

Accès :
  - URL publique : http://superset.keybuzz.io
  - Login : $SUPERSET_ADMIN_USER
  - Password : $SUPERSET_ADMIN_PASSWORD

Tests :
  # Test interne
  kubectl exec -it -n superset \$(kubectl get pods -n superset -l app=superset -o name | head -n1 | cut -d/ -f2) -- curl -s http://localhost:8088/health

  # Test via Ingress
  IP_WORKER=\$(awk -F'\t' '\$2=="k3s-worker-01" {print \$3}' $SERVERS_TSV)
  curl -H "Host: superset.keybuzz.io" http://\$IP_WORKER:31695/

  # Test depuis Internet (si DNS configuré)
  curl http://superset.keybuzz.io/health

Logs :
  kubectl logs -n superset -l app=superset --tail=50

Prochaine étape :
  ./16_test_all_apps.sh

SUMMARY

exit 0
