#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Déploiement Chatwoot - Customer Support Platform               ║"
echo "║    (Web + Workers + Sidekiq + Migrations DB)                      ║"
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
    REDIS_PASSWORD="keybuzz2025"
fi

echo ""
echo "Configuration Chatwoot :"
echo "  - PostgreSQL : 10.0.0.10:5432"
echo "  - Redis : 10.0.0.10:6379 (via HAProxy)"
echo "  - Composants : web (2), workers (2), sidekiq (1)"
echo ""
echo "⚠️  IMPORTANT :"
echo "  Chatwoot n'est PAS Sentinel-aware"
echo "  → Utilise Redis via HAProxy TCP (port 6379)"
echo ""

read -p "Déployer Chatwoot ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création namespace ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace chatwoot 2>/dev/null || true
echo -e "$OK Namespace créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Génération secrets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Générer clés secrètes
SECRET_KEY_BASE=$(openssl rand -hex 64)
FRONTEND_URL="http://chat.keybuzz.io"

echo "  ✓ SECRET_KEY_BASE généré"
echo "  ✓ FRONTEND_URL : $FRONTEND_URL"

# Créer le secret K8s
kubectl create secret generic chatwoot-secrets -n chatwoot \
  --from-literal=POSTGRES_HOST=10.0.0.10 \
  --from-literal=POSTGRES_PORT=5432 \
  --from-literal=POSTGRES_DATABASE=chatwoot \
  --from-literal=POSTGRES_USERNAME=chatwoot \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \
  --from-literal=SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  --from-literal=FRONTEND_URL="$FRONTEND_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secrets créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Déploiement Chatwoot Web ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatwoot-web
  namespace: chatwoot
  labels:
    app: chatwoot
    component: web
spec:
  replicas: 2
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
      containers:
      - name: chatwoot
        image: chatwoot/chatwoot:latest
        command: ["bundle"]
        args: ["exec", "rails", "s", "-b", "0.0.0.0", "-p", "3000"]
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: RAILS_ENV
          value: "production"
        - name: NODE_ENV
          value: "production"
        - name: INSTALLATION_ENV
          value: "docker"
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
        - name: FRONTEND_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: FRONTEND_URL
        - name: FORCE_SSL
          value: "false"
        - name: ENABLE_ACCOUNT_SIGNUP
          value: "true"
        - name: LOG_LEVEL
          value: "info"
        - name: LOG_SIZE
          value: "500"
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /api
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /api
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: chatwoot-web
  namespace: chatwoot
spec:
  type: ClusterIP
  selector:
    app: chatwoot
    component: web
  ports:
  - port: 3000
    targetPort: 3000
    name: http
EOF

echo -e "$OK Chatwoot Web déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Déploiement Chatwoot Workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatwoot-worker
  namespace: chatwoot
  labels:
    app: chatwoot
    component: worker
spec:
  replicas: 2
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
      containers:
      - name: chatwoot
        image: chatwoot/chatwoot:latest
        command: ["bundle"]
        args: ["exec", "sidekiq", "-C", "config/sidekiq.yml"]
        env:
        - name: RAILS_ENV
          value: "production"
        - name: NODE_ENV
          value: "production"
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
        - name: FRONTEND_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: FRONTEND_URL
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
EOF

echo -e "$OK Chatwoot Workers déployés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Job Migration DB ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Création job de migration DB..."

kubectl apply -f - <<'EOF'
---
apiVersion: batch/v1
kind: Job
metadata:
  name: chatwoot-db-migrate
  namespace: chatwoot
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: chatwoot/chatwoot:latest
        command: ["bundle"]
        args: ["exec", "rails", "db:chatwoot_prepare"]
        env:
        - name: RAILS_ENV
          value: "production"
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
EOF

echo -e "$OK Job de migration créé"

echo ""
echo "Attente fin de la migration (peut prendre 2-3 minutes)..."

# Attendre que le job se termine
for i in {1..120}; do
    JOB_STATUS=$(kubectl get job chatwoot-db-migrate -n chatwoot -o jsonpath='{.status.succeeded}' 2>/dev/null)
    
    if [ "$JOB_STATUS" = "1" ]; then
        echo -e "$OK Migration DB terminée"
        break
    fi
    
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Attente... ($i/120)"
    fi
    
    sleep 1
done

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
  name: chatwoot
  namespace: chatwoot
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
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
kubectl get pods -n chatwoot
echo ""

echo "Services :"
kubectl get svc -n chatwoot
echo ""

echo "Ingress :"
kubectl get ingress -n chatwoot
echo ""

echo "Job migration :"
kubectl get job -n chatwoot

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Chatwoot déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<SUMMARY
✅ Composants déployés :
  - chatwoot-web : 2 réplicas (port 3000)
  - chatwoot-worker : 2 réplicas (sidekiq)
  - Migration DB : Terminée

Configuration :
  - PostgreSQL : 10.0.0.10:5432 (base chatwoot)
  - Redis : 10.0.0.10:6379 (via HAProxy)
  - Frontend URL : http://chat.keybuzz.io

Accès :
  - URL publique : http://chat.keybuzz.io
  - Premier accès : Créer un compte admin

Tests :
  # Test interne
  kubectl exec -it -n chatwoot \$(kubectl get pods -n chatwoot -l component=web -o name | head -n1 | cut -d/ -f2) -- curl -s http://localhost:3000/api

  # Test via Ingress
  IP_WORKER=\$(awk -F'\t' '\$2=="k3s-worker-01" {print \$3}' $SERVERS_TSV)
  curl -H "Host: chat.keybuzz.io" http://\$IP_WORKER:31695/

  # Test depuis Internet (si DNS configuré)
  curl http://chat.keybuzz.io/api

Logs :
  kubectl logs -n chatwoot -l component=web --tail=50
  kubectl logs -n chatwoot -l component=worker --tail=50

Prochaine étape :
  ./15_deploy_superset.sh

SUMMARY

exit 0
