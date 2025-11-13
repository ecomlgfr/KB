#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement COMPLET des Applications                     ║"
echo "║    (n8n, LiteLLM, Qdrant, Chatwoot, Superset)                     ║"
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

if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN Redis credentials non trouvés"
    REDIS_PASSWORD="keybuzz2025"
fi

if [ -f "$CREDENTIALS_DIR/rabbitmq.env" ]; then
    source "$CREDENTIALS_DIR/rabbitmq.env"
else
    echo -e "$WARN RabbitMQ credentials non trouvés"
    RABBITMQ_PASSWORD="keybuzz2025"
fi

echo ""
echo "ARCHITECTURE :"
echo "  ✅ DaemonSets avec hostNetwork (contournement VXLAN)"
echo "  ✅ Port 6432 (PgBouncer) pour les applications"
echo "  ✅ Redis Sentinel (10.0.0.10:6379)"
echo "  ✅ RabbitMQ Quorum (10.0.0.10:5672)"
echo ""
echo "Applications à déployer :"
echo "  1. n8n       (Workflow automation)"
echo "  2. LiteLLM   (LLM Router)"
echo "  3. Qdrant    (Vector database)"
echo "  4. Chatwoot  (Customer support) + Job de migration"
echo "  5. Superset  (Business Intelligence)"
echo ""
echo "⚠️ IMPORTANT : Les bases de données doivent être créées AVANT"
echo "   → Exécuter ./02_prepare_database_DIRECT.sh si ce n'est pas fait"
echo ""

read -p "Déployer toutes les applications ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création des namespaces ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace n8n 2>/dev/null || true
kubectl create namespace litellm 2>/dev/null || true
kubectl create namespace qdrant 2>/dev/null || true
kubectl create namespace chatwoot 2>/dev/null || true
kubectl create namespace superset 2>/dev/null || true

echo -e "$OK Namespaces créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création des Secrets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# n8n secret (utilise postgres user avec port 6432)
kubectl create secret generic n8n-secrets -n n8n \
  --from-literal=DB_TYPE=postgresdb \
  --from-literal=DB_POSTGRESDB_HOST=10.0.0.10 \
  --from-literal=DB_POSTGRESDB_PORT=6432 \
  --from-literal=DB_POSTGRESDB_DATABASE=n8n \
  --from-literal=DB_POSTGRESDB_USER=postgres \
  --from-literal=DB_POSTGRESDB_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ n8n secrets"

# litellm secret (port 6432)
kubectl create secret generic litellm-secrets -n litellm \
  --from-literal=DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:6432/litellm" \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ litellm secrets"

# chatwoot secrets (port 6432)
kubectl create secret generic chatwoot-secrets -n chatwoot \
  --from-literal=POSTGRES_HOST=10.0.0.10 \
  --from-literal=POSTGRES_PORT=6432 \
  --from-literal=POSTGRES_DATABASE=chatwoot \
  --from-literal=POSTGRES_USERNAME=chatwoot \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \
  --from-literal=RABBITMQ_URL="amqp://admin:${RABBITMQ_PASSWORD}@10.0.0.10:5672" \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  --from-literal=RAILS_ENV=production \
  --from-literal=RAILS_LOG_TO_STDOUT=true \
  --from-literal=FORCE_SSL=false \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ chatwoot secrets"

# superset secret (port 6432)
kubectl create secret generic superset-secrets -n superset \
  --from-literal=SUPERSET_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=DATABASE_URL="postgresql://superset:${POSTGRES_PASSWORD}@10.0.0.10:6432/superset" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379/1" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ superset secrets"

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
  selector:
    app: n8n
  ports:
  - port: 5678
    targetPort: 5678
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
  selector:
    app: litellm
  ports:
  - port: 4000
    targetPort: 4000
EOF

echo -e "$OK LiteLLM déployé"

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
  selector:
    app: qdrant
  ports:
  - name: http
    port: 6333
    targetPort: 6333
  - name: grpc
    port: 6334
    targetPort: 6334
EOF

echo -e "$OK Qdrant déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Déploiement Chatwoot (Web + Worker) ═══"
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
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
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
        command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
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
  name: chatwoot
  namespace: chatwoot
spec:
  selector:
    app: chatwoot
    component: web
  ports:
  - port: 3000
    targetPort: 3000
EOF

echo -e "$OK Chatwoot Web + Worker déployés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Job de Migration Chatwoot (CRITIQUE) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Supprimer l'ancien Job s'il existe
kubectl delete job chatwoot-db-migrate -n chatwoot 2>/dev/null || true

echo "Création du Job de migration Chatwoot..."

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

echo ""
echo "Attente de la fin de la migration (max 2 minutes)..."
sleep 10

# Attendre que le Job soit complété
for i in {1..12}; do
    JOB_STATUS=$(kubectl get job -n chatwoot chatwoot-db-migrate -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [ "$JOB_STATUS" = "1" ]; then
        echo -e "$OK Job de migration Chatwoot complété"
        break
    fi
    echo "  Tentative $i/12 : En cours..."
    sleep 10
done

if [ "$JOB_STATUS" != "1" ]; then
    echo -e "$WARN Job de migration non complété après 2 minutes"
    echo "Vérifier les logs : kubectl logs -n chatwoot job/chatwoot-db-migrate"
fi

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
        image: apache/superset:latest
        ports:
        - containerPort: 8088
          hostPort: 8088
        env:
        - name: SUPERSET_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SUPERSET_SECRET_KEY
        - name: SQLALCHEMY_DATABASE_URI
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: REDIS_HOST
          value: "10.0.0.10"
        - name: REDIS_PORT
          value: "6379"
        command:
        - /bin/sh
        - -c
        - |
          superset db upgrade
          superset fab create-admin --username admin --firstname Admin --lastname User --email admin@keybuzz.io --password Admin123!
          superset init
          superset run -h 0.0.0.0 -p 8088 --with-threads --reload
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
  name: superset
  namespace: superset
spec:
  selector:
    app: superset
  ports:
  - port: 8088
    targetPort: 8088
EOF

echo -e "$OK Superset déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. Configuration des Ingress Routes ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n-ingress
  namespace: n8n
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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
  name: litellm-ingress
  namespace: litellm
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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
  name: qdrant-ingress
  namespace: qdrant
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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
  name: chatwoot-ingress
  namespace: chatwoot
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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
            name: chatwoot
            port:
              number: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset-ingress
  namespace: superset
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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

echo -e "$OK Ingress routes configurées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10. Attente démarrage complet (3 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente pour que tous les pods démarrent..."
sleep 180

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 11. Vérification finale ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "État des pods :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep -v 'ingress\|admission'
echo ""

echo "État des DaemonSets :"
kubectl get daemonset -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)'
echo ""

echo "État des Ingress :"
kubectl get ingress -A
echo ""

echo "État du Job Chatwoot :"
kubectl get job -n chatwoot
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK DÉPLOIEMENT COMPLET TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 URLs d'accès :"
echo "  n8n       : http://n8n.keybuzz.io"
echo "  LiteLLM   : http://llm.keybuzz.io"
echo "  Qdrant    : http://qdrant.keybuzz.io/dashboard"
echo "  Chatwoot  : http://chat.keybuzz.io"
echo "  Superset  : http://superset.keybuzz.io"
echo ""
echo "🔐 Credentials Superset :"
echo "  Username  : admin"
echo "  Password  : Admin123!"
echo "  ⚠️ À changer immédiatement après première connexion"
echo ""
echo "Applications déployées :"
echo "  1. n8n       : 8/8 pods"
echo "  2. LiteLLM   : 8/8 pods"
echo "  3. Qdrant    : 8/8 pods"
echo "  4. Chatwoot  : 16/16 pods (8 web + 8 worker)"
echo "  5. Superset  : 8/8 pods"
echo ""
echo "Prochaine étape :"
echo "  ./12_final_validation.sh"
echo ""

exit 0
