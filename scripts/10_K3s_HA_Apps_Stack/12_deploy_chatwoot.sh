#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Chatwoot (Architecture Complète)             ║"
echo "║    PostgreSQL + Redis + RabbitMQ via LB Hetzner 10.0.0.10         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/chatwoot_deploy_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Déploiement Chatwoot - Architecture KeyBuzz"
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

echo -n "→ Credentials RabbitMQ ... "
if [ -f "$CREDENTIALS_DIR/rabbitmq.env" ]; then
    source "$CREDENTIALS_DIR/rabbitmq.env"
    echo -e "$OK"
else
    echo -e "$WARN"
    echo "Fichier manquant : $CREDENTIALS_DIR/rabbitmq.env (utilisation de valeurs par défaut)"
    RABBITMQ_ADMIN_USER="admin"
    RABBITMQ_ADMIN_PASS="keybuzz2025"
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

echo -n "  → RabbitMQ (10.0.0.10:5672) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/5672" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN"
    echo "  RabbitMQ non accessible, mais le déploiement peut continuer"
fi

echo ""
echo "Architecture validée :"
echo "  ✓ PostgreSQL : 10.0.0.10:5432 (via LB Hetzner → HAProxy → Patroni)"
echo "  ✓ Redis      : 10.0.0.10:6379 (via LB Hetzner → HAProxy → Sentinel)"
echo "  ✓ RabbitMQ   : 10.0.0.10:5672 (via LB Hetzner → HAProxy → Cluster)"
echo ""

read -p "Continuer le déploiement Chatwoot ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: CRÉATION NAMESPACE ET SECRETS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Création namespace et secrets                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl create namespace chatwoot 2>/dev/null || true
echo -e "$OK Namespace chatwoot créé"

# Générer les clés secrètes
SECRET_KEY_BASE=$(openssl rand -hex 64)
FRONTEND_URL="http://chat.keybuzz.io"

echo ""
echo "Création du secret Chatwoot..."

kubectl create secret generic chatwoot-secrets -n chatwoot \
  --from-literal=POSTGRES_HOST=10.0.0.10 \
  --from-literal=POSTGRES_PORT=5432 \
  --from-literal=POSTGRES_DATABASE=chatwoot \
  --from-literal=POSTGRES_USERNAME=chatwoot \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=REDIS_URL="redis://10.0.0.10:6379" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=RABBITMQ_URL="amqp://${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASS}@10.0.0.10:5672" \
  --from-literal=SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  --from-literal=FRONTEND_URL="$FRONTEND_URL" \
  --from-literal=RAILS_ENV=production \
  --from-literal=NODE_ENV=production \
  --from-literal=INSTALLATION_ENV=docker \
  --from-literal=ACTIVE_STORAGE_SERVICE=local \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secret chatwoot-secrets créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: DÉPLOIEMENT CHATWOOT
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Déploiement Chatwoot (Web + Workers + Migration)     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
# Job de migration DB (à exécuter en premier)
apiVersion: batch/v1
kind: Job
metadata:
  name: chatwoot-db-migrate
  namespace: chatwoot
spec:
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app: chatwoot
        component: migrate
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: chatwoot/chatwoot:latest
        command: 
        - bundle
        - exec
        - rails
        - db:chatwoot:prepare
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
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_PASSWORD
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
---
# Deployment Web (2 réplicas)
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
        ports:
        - containerPort: 3000
          name: http
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
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_PASSWORD
        - name: RABBITMQ_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RABBITMQ_URL
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
        - name: RAILS_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_ENV
        - name: NODE_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: NODE_ENV
        - name: INSTALLATION_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: INSTALLATION_ENV
        - name: ACTIVE_STORAGE_SERVICE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: ACTIVE_STORAGE_SERVICE
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
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
---
# Deployment Workers (2 réplicas)
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
      - name: worker
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
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_PASSWORD
        - name: RABBITMQ_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RABBITMQ_URL
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
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
# Service
apiVersion: v1
kind: Service
metadata:
  name: chatwoot
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
---
# Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chatwoot
  namespace: chatwoot
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
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
            name: chatwoot
            port:
              number: 3000
EOF

echo -e "$OK Ressources Chatwoot créées"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: ATTENTE ET VÉRIFICATIONS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Attente migration DB et démarrage pods               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Attente du job de migration (60s max)..."
kubectl wait --for=condition=complete --timeout=60s job/chatwoot-db-migrate -n chatwoot 2>/dev/null || {
    echo -e "$WARN Migration prend plus de temps, vérification des logs..."
    kubectl logs -n chatwoot job/chatwoot-db-migrate --tail=20
}

echo ""
echo "Attente des pods Web (60s max)..."
kubectl wait --for=condition=ready --timeout=60s pod -l component=web -n chatwoot 2>/dev/null || {
    echo -e "$WARN Pods pas encore prêts"
}

echo ""
echo "Attente des pods Workers (30s max)..."
kubectl wait --for=condition=ready --timeout=30s pod -l component=worker -n chatwoot 2>/dev/null || {
    echo -e "$WARN Workers pas encore prêts"
}

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ RÉSUMÉ FINAL                                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "État des pods Chatwoot :"
kubectl get pods -n chatwoot -o wide

echo ""
echo "État du service :"
kubectl get svc -n chatwoot

echo ""
echo "État de l'Ingress :"
kubectl get ingress -n chatwoot

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CHATWOOT DÉPLOYÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "URL d'accès : http://chat.keybuzz.io"
echo ""
echo "⚠️  IMPORTANT - Configuration DNS requise :"
echo "  chat.keybuzz.io  A  49.13.42.76      TTL 60"
echo "  chat.keybuzz.io  A  138.199.132.240  TTL 60"
echo ""
echo "Premier accès :"
echo "  1. Ouvrir http://chat.keybuzz.io"
echo "  2. Créer le premier compte (sera admin)"
echo "  3. Configurer l'entreprise"
echo ""
echo "Logs utiles :"
echo "  kubectl logs -n chatwoot -l component=web --tail=50"
echo "  kubectl logs -n chatwoot -l component=worker --tail=50"
echo "  kubectl logs -n chatwoot job/chatwoot-db-migrate"
echo ""
echo "Architecture :"
echo "  ✓ PostgreSQL : 10.0.0.10:5432 (LB Hetzner → HAProxy → Patroni)"
echo "  ✓ Redis      : 10.0.0.10:6379 (LB Hetzner → HAProxy → Sentinel)"
echo "  ✓ RabbitMQ   : 10.0.0.10:5672 (LB Hetzner → HAProxy → Cluster)"
echo ""
echo "Prochaine étape :"
echo "  ./13_deploy_superset.sh"
echo ""
