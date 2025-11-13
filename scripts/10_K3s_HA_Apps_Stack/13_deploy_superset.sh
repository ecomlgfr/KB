#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Superset (Architecture Complète)             ║"
echo "║    PostgreSQL + Redis via LB Hetzner 10.0.0.10                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/superset_deploy_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Déploiement Superset - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS PRÉALABLES
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Charger les credentials
echo -n "→ Credentials PostgreSQL ... "
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
    echo -e "$OK"
else
    echo -e "$KO"
    echo "Fichier manquant : $CREDENTIALS_DIR/postgres.env"
    exit 1
fi

echo -n "→ Credentials Redis ... "
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
    echo -e "$OK"
else
    echo -e "$KO"
    echo "Fichier manquant : $CREDENTIALS_DIR/redis.env"
    exit 1
fi

# Vérifier K3s
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

echo -n "→ Cluster K3s ... "
if kubectl get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "K3s non accessible"
    exit 1
fi

# Vérifier les services backend
echo ""
echo "Vérification des services backend (via LB 10.0.0.10) :"

echo -n "  → PostgreSQL (10.0.0.10:5432) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/5432" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

echo -n "  → Redis (10.0.0.10:6379) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/6379" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

echo ""
echo "Architecture validée :"
echo "  ✓ PostgreSQL : 10.0.0.10:5432 (via LB Hetzner → HAProxy → Patroni)"
echo "  ✓ Redis      : 10.0.0.10:6379 (via LB Hetzner → HAProxy → Sentinel)"
echo ""

read -p "Continuer le déploiement Superset ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: CRÉATION NAMESPACE ET SECRETS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Création namespace et secrets                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl create namespace superset 2>/dev/null || true
echo -e "$OK Namespace superset créé"

# Générer les clés secrètes
SECRET_KEY=$(openssl rand -base64 42)
SQLALCHEMY_DATABASE_URI="postgresql://superset:${POSTGRES_PASSWORD}@10.0.0.10:5432/superset"
REDIS_HOST="10.0.0.10"
REDIS_PORT="6379"

# Credentials admin Superset
SUPERSET_ADMIN_USERNAME="admin"
SUPERSET_ADMIN_PASSWORD="Admin123!"
SUPERSET_ADMIN_FIRSTNAME="Admin"
SUPERSET_ADMIN_LASTNAME="KeyBuzz"
SUPERSET_ADMIN_EMAIL="admin@keybuzz.io"

echo ""
echo "Création du secret Superset..."

kubectl create secret generic superset-secrets -n superset \
  --from-literal=SECRET_KEY="$SECRET_KEY" \
  --from-literal=SQLALCHEMY_DATABASE_URI="$SQLALCHEMY_DATABASE_URI" \
  --from-literal=REDIS_HOST="$REDIS_HOST" \
  --from-literal=REDIS_PORT="$REDIS_PORT" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=ADMIN_USERNAME="$SUPERSET_ADMIN_USERNAME" \
  --from-literal=ADMIN_PASSWORD="$SUPERSET_ADMIN_PASSWORD" \
  --from-literal=ADMIN_FIRSTNAME="$SUPERSET_ADMIN_FIRSTNAME" \
  --from-literal=ADMIN_LASTNAME="$SUPERSET_ADMIN_LASTNAME" \
  --from-literal=ADMIN_EMAIL="$SUPERSET_ADMIN_EMAIL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secret superset-secrets créé"

# Créer ConfigMap pour la configuration Python
echo ""
echo "Création du ConfigMap superset-config..."

kubectl create configmap superset-config -n superset \
  --from-literal=superset_config.py="
import os
from cachelib.redis import RedisCache

# Configuration Redis pour le cache
CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 300,
    'CACHE_KEY_PREFIX': 'superset_',
    'CACHE_REDIS_HOST': os.environ.get('REDIS_HOST', '10.0.0.10'),
    'CACHE_REDIS_PORT': int(os.environ.get('REDIS_PORT', '6379')),
    'CACHE_REDIS_PASSWORD': os.environ.get('REDIS_PASSWORD', ''),
    'CACHE_REDIS_DB': 1,
}

DATA_CACHE_CONFIG = CACHE_CONFIG

# Configuration base
SECRET_KEY = os.environ.get('SECRET_KEY')
SQLALCHEMY_DATABASE_URI = os.environ.get('SQLALCHEMY_DATABASE_URI')

# Désactiver la télémétrie
ENABLE_PROXY_FIX = True
ENABLE_CORS = False

# Configuration pour les uploads
UPLOAD_FOLDER = '/app/superset_home/uploads/'
IMG_UPLOAD_FOLDER = '/app/superset_home/uploads/'
IMG_UPLOAD_URL = '/static/uploads/'
" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK ConfigMap superset-config créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: DÉPLOIEMENT SUPERSET
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Déploiement Superset (Init DB + Deployment)          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
# Job d'initialisation DB
apiVersion: batch/v1
kind: Job
metadata:
  name: superset-init-db
  namespace: superset
spec:
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app: superset
        component: init
    spec:
      restartPolicy: OnFailure
      containers:
      - name: init-db
        image: apache/superset:latest
        command:
        - /bin/sh
        - -c
        - |
          set -e
          echo "Initialisation de la base de données Superset..."
          superset db upgrade
          echo "✓ Base de données initialisée"
        env:
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SQLALCHEMY_DATABASE_URI
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SQLALCHEMY_DATABASE_URI
        - name: REDIS_HOST
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_HOST
        - name: REDIS_PORT
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PORT
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PASSWORD
        - name: PYTHONPATH
          value: "/app/pythonpath"
        volumeMounts:
        - name: config
          mountPath: /app/pythonpath
      volumes:
      - name: config
        configMap:
          name: superset-config
---
# Job création admin user
apiVersion: batch/v1
kind: Job
metadata:
  name: superset-create-admin
  namespace: superset
spec:
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app: superset
        component: create-admin
    spec:
      restartPolicy: OnFailure
      containers:
      - name: create-admin
        image: apache/superset:latest
        command:
        - /bin/sh
        - -c
        - |
          set -e
          echo "Création de l'utilisateur admin..."
          superset fab create-admin \
            --username "${ADMIN_USERNAME}" \
            --firstname "${ADMIN_FIRSTNAME}" \
            --lastname "${ADMIN_LASTNAME}" \
            --email "${ADMIN_EMAIL}" \
            --password "${ADMIN_PASSWORD}" || true
          superset init
          echo "✓ Utilisateur admin créé"
        env:
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SQLALCHEMY_DATABASE_URI
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SQLALCHEMY_DATABASE_URI
        - name: REDIS_HOST
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_HOST
        - name: REDIS_PORT
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PORT
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PASSWORD
        - name: ADMIN_USERNAME
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: ADMIN_USERNAME
        - name: ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: ADMIN_PASSWORD
        - name: ADMIN_FIRSTNAME
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: ADMIN_FIRSTNAME
        - name: ADMIN_LASTNAME
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: ADMIN_LASTNAME
        - name: ADMIN_EMAIL
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: ADMIN_EMAIL
        - name: PYTHONPATH
          value: "/app/pythonpath"
        volumeMounts:
        - name: config
          mountPath: /app/pythonpath
      volumes:
      - name: config
        configMap:
          name: superset-config
---
# Deployment Superset (2 réplicas)
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
        command:
        - /bin/sh
        - -c
        - |
          gunicorn \
            --bind 0.0.0.0:8088 \
            --workers 4 \
            --timeout 120 \
            --limit-request-line 0 \
            --limit-request-field_size 0 \
            "superset.app:create_app()"
        env:
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SQLALCHEMY_DATABASE_URI
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SQLALCHEMY_DATABASE_URI
        - name: REDIS_HOST
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_HOST
        - name: REDIS_PORT
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PORT
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PASSWORD
        - name: PYTHONPATH
          value: "/app/pythonpath"
        - name: SUPERSET_PORT
          value: "8088"
        volumeMounts:
        - name: config
          mountPath: /app/pythonpath
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
      volumes:
      - name: config
        configMap:
          name: superset-config
---
# Service
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
---
# Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset
  namespace: superset
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
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

echo -e "$OK Ressources Superset créées"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: ATTENTE ET VÉRIFICATIONS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Attente init DB et démarrage pods                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Attente du job init-db (90s max)..."
kubectl wait --for=condition=complete --timeout=90s job/superset-init-db -n superset 2>/dev/null || {
    echo -e "$WARN Init DB prend plus de temps, vérification des logs..."
    kubectl logs -n superset job/superset-init-db --tail=20
}

echo ""
echo "Attente du job create-admin (60s max)..."
kubectl wait --for=condition=complete --timeout=60s job/superset-create-admin -n superset 2>/dev/null || {
    echo -e "$WARN Create admin prend plus de temps, vérification des logs..."
    kubectl logs -n superset job/superset-create-admin --tail=20
}

echo ""
echo "Attente des pods Superset (60s max)..."
kubectl wait --for=condition=ready --timeout=60s pod -l app=superset -n superset 2>/dev/null || {
    echo -e "$WARN Pods pas encore prêts"
}

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ RÉSUMÉ FINAL                                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "État des jobs :"
kubectl get jobs -n superset

echo ""
echo "État des pods Superset :"
kubectl get pods -n superset -o wide

echo ""
echo "État du service :"
kubectl get svc -n superset

echo ""
echo "État de l'Ingress :"
kubectl get ingress -n superset

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK SUPERSET DÉPLOYÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "URL d'accès : http://superset.keybuzz.io"
echo ""
echo "⚠️  IMPORTANT - Configuration DNS requise :"
echo "  superset.keybuzz.io  A  49.13.42.76      TTL 60"
echo "  superset.keybuzz.io  A  138.199.132.240  TTL 60"
echo ""
echo "Credentials :"
echo "  Username : $SUPERSET_ADMIN_USERNAME"
echo "  Password : $SUPERSET_ADMIN_PASSWORD"
echo "  Email    : $SUPERSET_ADMIN_EMAIL"
echo ""
echo "Logs utiles :"
echo "  kubectl logs -n superset -l app=superset --tail=50"
echo "  kubectl logs -n superset job/superset-init-db"
echo "  kubectl logs -n superset job/superset-create-admin"
echo ""
echo "Architecture :"
echo "  ✓ PostgreSQL : 10.0.0.10:5432 (LB Hetzner → HAProxy → Patroni)"
echo "  ✓ Redis      : 10.0.0.10:6379 (LB Hetzner → HAProxy → Sentinel)"
echo ""
echo "Prochaine étape :"
echo "  ./14_test_all_apps.sh"
echo ""
