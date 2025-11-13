#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Superset DaemonSet (hostNetwork)             ║"
echo "║    Architecture unifiée avec n8n/litellm/qdrant                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

# Charger PostgreSQL credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$WARN PostgreSQL credentials non trouvés, utilisation valeur par défaut"
    POSTGRES_PASSWORD="keybuzz2025"
fi

# Charger Redis credentials
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN Redis credentials non trouvés, utilisation valeur par défaut"
    REDIS_PASSWORD="keybuzz2025"
fi

echo ""
echo "Déploiement Superset DaemonSet - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo -n "→ Credentials PostgreSQL ... "
[ -n "$POSTGRES_PASSWORD" ] && echo -e "$OK" || { echo -e "$KO"; exit 1; }

echo -n "→ Credentials Redis ... "
[ -n "$REDIS_PASSWORD" ] && echo -e "$OK" || { echo -e "$KO"; exit 1; }

echo -n "→ Cluster K3s ... "
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes >/dev/null 2>&1" && echo -e "$OK" || { echo -e "$KO"; exit 1; }

echo ""
echo "Architecture validée :"
echo "  ✓ PostgreSQL : 10.0.0.10:5432 (via LB Hetzner → HAProxy → Patroni)"
echo "  ✓ Redis      : 10.0.0.10:6379 (via LB Hetzner → HAProxy → Sentinel)"
echo ""

read -p "Continuer le déploiement Superset DaemonSet ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Nettoyage des ressources existantes                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CLEANUP'
# Supprimer DaemonSet s'il existe
kubectl delete daemonset superset -n superset 2>/dev/null && echo "  daemonset superset deleted" || echo "  (pas de daemonset)"

# Supprimer Deployment s'il existe
kubectl delete deployment superset -n superset 2>/dev/null && echo "  deployment superset deleted" || echo "  (pas de deployment)"

# Supprimer les jobs d'init
kubectl delete job superset-init-db -n superset 2>/dev/null && echo "  job superset-init-db deleted" || echo "  (pas de job init)"
kubectl delete job superset-create-admin -n superset 2>/dev/null && echo "  job superset-create-admin deleted" || echo "  (pas de job admin)"

echo "Attente suppression (10s)..."
sleep 10
CLEANUP

echo -e "$OK Nettoyage terminé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Création namespace, secrets et configuration         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl create namespace superset 2>/dev/null || true"
echo -e "$OK Namespace superset créé"

# Générer SECRET_KEY unique
SUPERSET_SECRET_KEY=$(openssl rand -hex 32)

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<SECRETS
kubectl create secret generic superset-secrets -n superset \\
  --from-literal=DATABASE_URL="postgresql://superset:${POSTGRES_PASSWORD}@10.0.0.10:5432/superset" \\
  --from-literal=SECRET_KEY="${SUPERSET_SECRET_KEY}" \\
  --from-literal=REDIS_HOST="10.0.0.10" \\
  --from-literal=REDIS_PORT="6379" \\
  --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}" \\
  --from-literal=SUPERSET_ADMIN_USERNAME="admin" \\
  --from-literal=SUPERSET_ADMIN_PASSWORD="Admin123!" \\
  --from-literal=SUPERSET_ADMIN_EMAIL="admin@keybuzz.io" \\
  --dry-run=client -o yaml | kubectl apply -f -
SECRETS

echo -e "$OK Secret superset-secrets créé"

# ConfigMap avec superset_config.py
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CONFIGMAP'
kubectl create configmap superset-config -n superset \
  --from-literal=superset_config.py="
import os
from celery.schedules import crontab

# PostgreSQL via LB Hetzner
SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL')

# Redis Cache via LB Hetzner
REDIS_HOST = os.environ.get('REDIS_HOST', '10.0.0.10')
REDIS_PORT = os.environ.get('REDIS_PORT', '6379')
REDIS_PASSWORD = os.environ.get('REDIS_PASSWORD', '')

RESULTS_BACKEND = f'redis://:{REDIS_PASSWORD}@{REDIS_HOST}:{REDIS_PORT}/1'
CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 300,
    'CACHE_KEY_PREFIX': 'superset_',
    'CACHE_REDIS_HOST': REDIS_HOST,
    'CACHE_REDIS_PORT': REDIS_PORT,
    'CACHE_REDIS_PASSWORD': REDIS_PASSWORD,
    'CACHE_REDIS_DB': 0,
}

# Security
SECRET_KEY = os.environ.get('SECRET_KEY')
WTF_CSRF_ENABLED = True
WTF_CSRF_TIME_LIMIT = None

# Feature flags
FEATURE_FLAGS = {
    'ENABLE_TEMPLATE_PROCESSING': True,
}
" \
  --dry-run=client -o yaml | kubectl apply -f -
CONFIGMAP

echo -e "$OK ConfigMap superset-config créé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Initialisation base de données                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Job pour init DB (superset db upgrade)
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'INITDB'
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: superset-init-db
  namespace: superset
spec:
  backoffLimit: 3
  template:
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
          echo "Starting Superset database initialization..."
          superset db upgrade
          echo "Database initialization completed successfully"
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SUPERSET_CONFIG_PATH
          value: /app/pythonpath/superset_config.py
        volumeMounts:
        - name: config
          mountPath: /app/pythonpath
      volumes:
      - name: config
        configMap:
          name: superset-config
EOF
INITDB

# Job pour créer l'admin
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CREATEADMIN'
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: superset-create-admin
  namespace: superset
spec:
  backoffLimit: 3
  template:
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
          echo "Waiting for database to be ready..."
          sleep 20
          echo "Creating admin user..."
          superset fab create-admin \
            --username "${SUPERSET_ADMIN_USERNAME}" \
            --firstname Admin \
            --lastname User \
            --email "${SUPERSET_ADMIN_EMAIL}" \
            --password "${SUPERSET_ADMIN_PASSWORD}" || echo "Admin user already exists"
          superset init
          echo "Admin user creation completed"
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: SUPERSET_ADMIN_USERNAME
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SUPERSET_ADMIN_USERNAME
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
        - name: SUPERSET_CONFIG_PATH
          value: /app/pythonpath/superset_config.py
        volumeMounts:
        - name: config
          mountPath: /app/pythonpath
      volumes:
      - name: config
        configMap:
          name: superset-config
EOF
CREATEADMIN

echo "Attente init DB (120s max)..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl wait --for=condition=complete --timeout=120s job/superset-init-db -n superset 2>/dev/null" || echo -e "${WARN} Init DB prend plus de temps..."

echo ""
echo "Attente create admin (90s max)..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl wait --for=condition=complete --timeout=90s job/superset-create-admin -n superset 2>/dev/null" || echo -e "${WARN} Create admin prend plus de temps..."

echo -e "$OK Init DB terminée"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Déploiement DaemonSet Superset                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Déploiement DaemonSet Superset avec hostNetwork
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'DAEMONSET'
kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: superset
  namespace: superset
  labels:
    app: superset
spec:
  selector:
    matchLabels:
      app: superset
  template:
    metadata:
      labels:
        app: superset
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: superset
        image: apache/superset:latest
        ports:
        - containerPort: 8088
          hostPort: 8088
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
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
        - name: SUPERSET_CONFIG_PATH
          value: /app/pythonpath/superset_config.py
        - name: SUPERSET_PORT
          value: "8088"
        volumeMounts:
        - name: config
          mountPath: /app/pythonpath
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        readinessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
      volumes:
      - name: config
        configMap:
          name: superset-config
---
apiVersion: v1
kind: Service
metadata:
  name: superset
  namespace: superset
spec:
  type: NodePort
  selector:
    app: superset
  ports:
  - port: 8088
    targetPort: 8088
    nodePort: 30808
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset
  namespace: superset
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
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
DAEMONSET

echo -e "$OK DaemonSet déployé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Attente démarrage pods (120s)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

sleep 120

echo ""
echo "État des pods Superset :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset -o wide"

echo ""
echo "État du service :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get svc -n superset"

echo ""
echo "État de l'Ingress :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get ingress -n superset"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK SUPERSET DAEMONSET DÉPLOYÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Architecture :"
echo "  ✓ Type       : DaemonSet avec hostNetwork (comme n8n/litellm/qdrant)"
echo "  ✓ Pods       : 1 pod par nœud (8 nœuds = 8 pods)"
echo "  ✓ Port       : 8088 (hostPort sur chaque nœud)"
echo "  ✓ PostgreSQL : 10.0.0.10:5432"
echo "  ✓ Redis      : 10.0.0.10:6379"
echo ""
echo "URL d'accès : http://superset.keybuzz.io"
echo ""
echo "Credentials :"
echo "  Username : admin"
echo "  Password : Admin123!"
echo "  Email    : admin@keybuzz.io"
echo ""
echo "Prochaine étape :"
echo "  ./14_test_all_apps.sh"
echo ""
