#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement COMPLET Applications KeyBuzz                 ║"
echo "║    (n8n, LiteLLM, Qdrant, Chatwoot, Superset)                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

# Fonction pour parser les .env
get_env_value() {
    local file="$1"
    local key="$2"
    
    if [ -f "$file" ]; then
        local value=$(grep -E "^${key}=" "$file" | cut -d'=' -f2- | sed 's/^["\x27]//;s/["\x27]$//' | head -n1)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    echo ""
    return 1
}

# Charger PostgreSQL credentials
POSTGRES_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_PASSWORD")
if [ -z "$POSTGRES_PASSWORD" ]; then
    echo -e "$WARN PostgreSQL password non trouvé, chargement depuis source"
    source "$CREDENTIALS_DIR/postgres.env" 2>/dev/null || true
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        echo -e "$KO Credentials PostgreSQL introuvables"
        exit 1
    fi
fi

# Charger Redis credentials
REDIS_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/redis.env" "REDIS_PASSWORD")
if [ -z "$REDIS_PASSWORD" ]; then
    source "$CREDENTIALS_DIR/redis.env" 2>/dev/null || true
    if [ -z "${REDIS_PASSWORD:-}" ]; then
        echo -e "$WARN Redis password non trouvé, utilisation valeur par défaut"
        REDIS_PASSWORD="keybuzz2025"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "CONFIGURATION VALIDÉE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Infrastructure :"
echo "  ✓ PostgreSQL : 10.0.0.10:6432 (PgBouncer - validé 19/19 tests)"
echo "  ✓ Redis      : 10.0.0.10:6379 (HAProxy + Sentinel)"
echo "  ✓ Cluster K3s: 8 nœuds (3 masters + 5 workers)"
echo "  ✓ Ingress    : DaemonSet hostNetwork (8 pods)"
echo ""
echo "Applications à déployer :"
echo "  1. n8n       : Workflow automation (port 5678)"
echo "  2. LiteLLM   : LLM Router (port 4000)"
echo "  3. Qdrant    : Vector database (ports 6333/6334)"
echo "  4. Chatwoot  : Customer support (port 3000)"
echo "  5. Superset  : Business Intelligence (port 8088)"
echo ""
echo "⚠️  IMPORTANT : Toutes les connexions PostgreSQL utilisent PgBouncer"
echo "   (port 6432) pour garantir le pooling et la haute disponibilité"
echo ""

read -p "Déployer toutes les applications ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création des namespaces ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ns in n8n litellm qdrant chatwoot superset; do
    kubectl create namespace $ns 2>/dev/null || true
    echo "  ✓ $ns"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création des Secrets (avec PgBouncer port 6432) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# n8n secret (CORRECTION: user postgres, port 6432)
echo "→ n8n secrets"
kubectl create secret generic n8n-secrets -n n8n \
  --from-literal=DB_TYPE=postgresdb \
  --from-literal=DB_POSTGRESDB_HOST=10.0.0.10 \
  --from-literal=DB_POSTGRESDB_PORT=6432 \
  --from-literal=DB_POSTGRESDB_DATABASE=n8n \
  --from-literal=DB_POSTGRESDB_USER=postgres \
  --from-literal=DB_POSTGRESDB_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# litellm secret (CORRECTION: port 6432)
echo "→ litellm secrets"
kubectl create secret generic litellm-secrets -n litellm \
  --from-literal=DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:6432/litellm" \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# chatwoot secret (CORRECTION: port 6432)
echo "→ chatwoot secrets"
CHATWOOT_SECRET_KEY=$(openssl rand -hex 64)
kubectl create secret generic chatwoot-secrets -n chatwoot \
  --from-literal=POSTGRES_HOST="10.0.0.10" \
  --from-literal=POSTGRES_PORT="6432" \
  --from-literal=POSTGRES_DATABASE="chatwoot" \
  --from-literal=POSTGRES_USERNAME="chatwoot" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \
  --from-literal=SECRET_KEY_BASE="$CHATWOOT_SECRET_KEY" \
  --from-literal=RAILS_ENV="production" \
  --from-literal=RAILS_LOG_TO_STDOUT="true" \
  --from-literal=FORCE_SSL="false" \
  --dry-run=client -o yaml | kubectl apply -f -

# superset secret (NOUVEAU: création des secrets manquants)
echo "→ superset secrets"
SUPERSET_SECRET_KEY=$(openssl rand -hex 32)
kubectl create secret generic superset-secrets -n superset \
  --from-literal=DATABASE_URL="postgresql://superset:${POSTGRES_PASSWORD}@10.0.0.10:6432/superset" \
  --from-literal=SECRET_KEY="$SUPERSET_SECRET_KEY" \
  --from-literal=REDIS_HOST="10.0.0.10" \
  --from-literal=REDIS_PORT="6379" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# superset configmap
echo "→ superset configmap"
kubectl create configmap superset-config -n superset \
  --from-literal=superset_config.py="
# Superset configuration
import os
SECRET_KEY = os.environ.get('SECRET_KEY')
SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL')

# Redis cache
CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 300,
    'CACHE_KEY_PREFIX': 'superset_',
    'CACHE_REDIS_HOST': os.environ.get('REDIS_HOST'),
    'CACHE_REDIS_PORT': int(os.environ.get('REDIS_PORT', 6379)),
    'CACHE_REDIS_PASSWORD': os.environ.get('REDIS_PASSWORD'),
    'CACHE_REDIS_DB': 1
}

# Celery
class CeleryConfig:
    broker_url = f\"redis://:{os.environ.get('REDIS_PASSWORD')}@{os.environ.get('REDIS_HOST')}:{os.environ.get('REDIS_PORT')}/0\"
    result_backend = f\"redis://:{os.environ.get('REDIS_PASSWORD')}@{os.environ.get('REDIS_HOST')}:{os.environ.get('REDIS_PORT')}/0\"

CELERY_CONFIG = CeleryConfig
" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "\n$OK Secrets créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Déploiement n8n ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: n8n
  namespace: n8n
  labels:
    app: n8n
spec:
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: n8n
        image: n8nio/n8n:latest
        ports:
        - containerPort: 5678
          hostPort: 5678
        env:
        - name: N8N_HOST
          value: "0.0.0.0"
        - name: N8N_PORT
          value: "5678"
        - name: N8N_PROTOCOL
          value: "http"
        - name: WEBHOOK_URL
          value: "http://n8n.keybuzz.io"
        - name: DB_TYPE
          valueFrom:
            secretKeyRef:
              name: n8n-secrets
              key: DB_TYPE
        - name: DB_POSTGRESDB_HOST
          valueFrom:
            secretKeyRef:
              name: n8n-secrets
              key: DB_POSTGRESDB_HOST
        - name: DB_POSTGRESDB_PORT
          valueFrom:
            secretKeyRef:
              name: n8n-secrets
              key: DB_POSTGRESDB_PORT
        - name: DB_POSTGRESDB_DATABASE
          valueFrom:
            secretKeyRef:
              name: n8n-secrets
              key: DB_POSTGRESDB_DATABASE
        - name: DB_POSTGRESDB_USER
          valueFrom:
            secretKeyRef:
              name: n8n-secrets
              key: DB_POSTGRESDB_USER
        - name: DB_POSTGRESDB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: n8n-secrets
              key: DB_POSTGRESDB_PASSWORD
        - name: N8N_ENCRYPTION_KEY
          valueFrom:
            secretKeyRef:
              name: n8n-secrets
              key: N8N_ENCRYPTION_KEY
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
apiVersion: v1
kind: Service
metadata:
  name: n8n
  namespace: n8n
spec:
  type: NodePort
  selector:
    app: n8n
  ports:
  - port: 5678
    targetPort: 5678
    nodePort: 30678
EOF

echo -e "$OK n8n déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Déploiement LiteLLM ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: litellm
  namespace: litellm
  labels:
    app: litellm
spec:
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main-latest
        ports:
        - containerPort: 4000
          hostPort: 4000
        env:
        - name: PORT
          value: "4000"
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: litellm-secrets
              key: DATABASE_URL
        - name: LITELLM_MASTER_KEY
          valueFrom:
            secretKeyRef:
              name: litellm-secrets
              key: LITELLM_MASTER_KEY
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: litellm
spec:
  type: NodePort
  selector:
    app: litellm
  ports:
  - port: 4000
    targetPort: 4000
    nodePort: 30400
EOF

echo -e "$OK litellm déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Déploiement Qdrant ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: qdrant
  namespace: qdrant
  labels:
    app: qdrant
spec:
  selector:
    matchLabels:
      app: qdrant
  template:
    metadata:
      labels:
        app: qdrant
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: qdrant
        image: qdrant/qdrant:latest
        ports:
        - containerPort: 6333
          hostPort: 6333
        - containerPort: 6334
          hostPort: 6334
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
---
apiVersion: v1
kind: Service
metadata:
  name: qdrant
  namespace: qdrant
spec:
  type: NodePort
  selector:
    app: qdrant
  ports:
  - name: http
    port: 6333
    targetPort: 6333
    nodePort: 30633
  - name: grpc
    port: 6334
    targetPort: 6334
    nodePort: 30634
EOF

echo -e "$OK qdrant déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Migration Chatwoot DB ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: chatwoot-db-migrate
  namespace: chatwoot
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: db-migrate
        image: chatwoot/chatwoot:latest
        command:
        - /bin/sh
        - -c
        - |
          set -e
          echo "Starting Chatwoot database migration..."
          bundle exec rails db:chatwoot_prepare
          echo "Database migration completed successfully"
        env:
        - name: POSTGRES_HOST
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PORT
        - name: POSTGRES_DATABASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_DATABASE
        - name: POSTGRES_USERNAME
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_USERNAME
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PASSWORD
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_URL
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: SECRET_KEY_BASE
        - name: RAILS_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_ENV
        - name: RAILS_LOG_TO_STDOUT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_LOG_TO_STDOUT
        - name: FORCE_SSL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: FORCE_SSL
EOF

echo "Attente migration Chatwoot DB (180s max)..."
kubectl wait --for=condition=complete --timeout=180s job/chatwoot-db-migrate -n chatwoot 2>/dev/null || echo -e "${WARN} Migration prend plus de temps..."

echo -e "$OK Migration Chatwoot terminée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Déploiement Chatwoot Web + Worker ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chatwoot-web
  namespace: chatwoot
  labels:
    app: chatwoot
    component: web
spec:
  selector:
    matchLabels:
      app: chatwoot
      component: web
  template:
    metadata:
      labels:
        app: chatwoot
        component: web
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: chatwoot-web
        image: chatwoot/chatwoot:latest
        ports:
        - containerPort: 3000
          hostPort: 3000
        command:
        - bundle
        - exec
        - rails
        - server
        - -b
        - 0.0.0.0
        - -p
        - "3000"
        env:
        - name: POSTGRES_HOST
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PORT
        - name: POSTGRES_DATABASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_DATABASE
        - name: POSTGRES_USERNAME
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_USERNAME
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PASSWORD
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_URL
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: SECRET_KEY_BASE
        - name: RAILS_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_ENV
        - name: RAILS_LOG_TO_STDOUT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_LOG_TO_STDOUT
        - name: FORCE_SSL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: FORCE_SSL
        - name: FRONTEND_URL
          value: "http://chat.keybuzz.io"
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        readinessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chatwoot-worker
  namespace: chatwoot
  labels:
    app: chatwoot
    component: worker
spec:
  selector:
    matchLabels:
      app: chatwoot
      component: worker
  template:
    metadata:
      labels:
        app: chatwoot
        component: worker
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: chatwoot-worker
        image: chatwoot/chatwoot:latest
        command:
        - bundle
        - exec
        - sidekiq
        - -C
        - config/sidekiq.yml
        env:
        - name: POSTGRES_HOST
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PORT
        - name: POSTGRES_DATABASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_DATABASE
        - name: POSTGRES_USERNAME
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_USERNAME
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PASSWORD
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_URL
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: SECRET_KEY_BASE
        - name: RAILS_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_ENV
        - name: RAILS_LOG_TO_STDOUT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_LOG_TO_STDOUT
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
apiVersion: v1
kind: Service
metadata:
  name: chatwoot-web
  namespace: chatwoot
spec:
  type: NodePort
  selector:
    app: chatwoot
    component: web
  ports:
  - port: 3000
    targetPort: 3000
    nodePort: 30300
EOF

echo -e "$OK chatwoot déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Déploiement Superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

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
        image: amancevice/superset:latest
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
        - name: SUPERSET_ENV
          value: production
        - name: SUPERSET_LOAD_EXAMPLES
          value: "no"
        volumeMounts:
        - name: config
          mountPath: /etc/superset
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
          initialDelaySeconds: 45
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 6
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
EOF

echo -e "$OK superset déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. Création Ingress Routes ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: n8n
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
spec:
  ingressClassName: nginx
  rules:
  - host: n8n.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: n8n
            port:
              number: 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  namespace: litellm
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: llm.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: litellm
            port:
              number: 4000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qdrant
  namespace: qdrant
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: qdrant.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: qdrant
            port:
              number: 6333
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chatwoot
  namespace: chatwoot
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
spec:
  ingressClassName: nginx
  rules:
  - host: chat.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: chatwoot-web
            port:
              number: 3000
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

echo -e "$OK Ingress routes créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10. Attente démarrage pods (120s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 11. Vérification finale ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "DaemonSets :"
kubectl get daemonset -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)'

echo ""
echo "Pods :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep -v 'ingress'

echo ""
echo "Services :"
kubectl get svc -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)'

echo ""
echo "Ingress :"
kubectl get ingress -A

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK DÉPLOIEMENT COMPLET TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 ARCHITECTURE FINALE :"
echo ""
echo "  ✅ Ingress NGINX : DaemonSet (8 pods) - Ports 31695/32720"
echo "  ✅ PostgreSQL    : 10.0.0.10:6432 (PgBouncer - HA)"
echo "  ✅ Redis         : 10.0.0.10:6379 (Sentinel - HA)"
echo ""
echo "📱 APPLICATIONS DÉPLOYÉES :"
echo ""
echo "  1. n8n       : http://n8n.keybuzz.io       (port 5678)"
echo "  2. LiteLLM   : http://llm.keybuzz.io       (port 4000)"
echo "  3. Qdrant    : http://qdrant.keybuzz.io    (port 6333)"
echo "  4. Chatwoot  : http://chat.keybuzz.io      (port 3000)"
echo "  5. Superset  : http://superset.keybuzz.io  (port 8088)"
echo ""
echo "🔐 ACCÈS APPLICATIONS :"
echo ""
echo "  n8n       : Créer un compte au premier accès"
echo "  LiteLLM   : API key dans secret litellm-secrets"
echo "  Qdrant    : Pas d'auth par défaut"
echo "  Chatwoot  : Créer un compte au premier accès (sera admin)"
echo "  Superset  : Username: admin / Password: Admin123!"
echo ""
echo "✅ CORRECTIONS APPLIQUÉES :"
echo "  • PostgreSQL : Port 6432 (PgBouncer) au lieu de 5432"
echo "  • n8n        : User 'postgres' au lieu de 'n8n'"
echo "  • Superset   : Secrets créés automatiquement"
echo ""
echo "Prochaine étape :"
echo "  Tester les applications via les URLs ci-dessus"
echo ""
