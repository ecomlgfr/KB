#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Chatwoot DaemonSet (hostNetwork)             ║"
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
echo "Déploiement Chatwoot DaemonSet - Architecture KeyBuzz"
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

read -p "Continuer le déploiement Chatwoot DaemonSet ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Nettoyage des ressources existantes                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CLEANUP'
# Supprimer DaemonSet s'il existe
kubectl delete daemonset chatwoot-web -n chatwoot 2>/dev/null && echo "  daemonset chatwoot-web deleted" || echo "  (pas de daemonset web)"
kubectl delete daemonset chatwoot-worker -n chatwoot 2>/dev/null && echo "  daemonset chatwoot-worker deleted" || echo "  (pas de daemonset worker)"

# Supprimer Deployment s'il existe
kubectl delete deployment chatwoot-web -n chatwoot 2>/dev/null && echo "  deployment chatwoot-web deleted" || echo "  (pas de deployment web)"
kubectl delete deployment chatwoot-worker -n chatwoot 2>/dev/null && echo "  deployment chatwoot-worker deleted" || echo "  (pas de deployment worker)"

# Supprimer les jobs
kubectl delete job chatwoot-db-migrate -n chatwoot 2>/dev/null && echo "  job chatwoot-db-migrate deleted" || echo "  (pas de job migrate)"

echo "Attente suppression (10s)..."
sleep 10
CLEANUP

echo -e "$OK Nettoyage terminé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Création namespace et secrets                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl create namespace chatwoot 2>/dev/null || true"
echo -e "$OK Namespace chatwoot créé"

# Générer SECRET_KEY_BASE unique
CHATWOOT_SECRET_KEY=$(openssl rand -hex 64)

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<SECRETS
kubectl create secret generic chatwoot-secrets -n chatwoot \\
  --from-literal=POSTGRES_HOST="10.0.0.10" \\
  --from-literal=POSTGRES_PORT="5432" \\
  --from-literal=POSTGRES_DATABASE="chatwoot" \\
  --from-literal=POSTGRES_USERNAME="chatwoot" \\
  --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \\
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \\
  --from-literal=SECRET_KEY_BASE="${CHATWOOT_SECRET_KEY}" \\
  --from-literal=RAILS_ENV="production" \\
  --from-literal=RAILS_LOG_TO_STDOUT="true" \\
  --from-literal=FORCE_SSL="false" \\
  --dry-run=client -o yaml | kubectl apply -f -
SECRETS

echo -e "$OK Secret chatwoot-secrets créé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Migration base de données                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Job pour migration DB
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'MIGRATE'
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
MIGRATE

echo "Attente migration DB (180s max)..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl wait --for=condition=complete --timeout=180s job/chatwoot-db-migrate -n chatwoot 2>/dev/null" || echo -e "${WARN} Migration prend plus de temps..."

echo -e "$OK Migration DB terminée"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Déploiement DaemonSet Chatwoot Web                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Déploiement DaemonSet Chatwoot Web avec hostNetwork
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'WEBDAEMONSET'
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
EOF
WEBDAEMONSET

echo -e "$OK DaemonSet Web déployé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Déploiement DaemonSet Chatwoot Worker                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Déploiement DaemonSet Chatwoot Worker avec hostNetwork
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'WORKERDAEMONSET'
kubectl apply -f - <<'EOF'
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
EOF
WORKERDAEMONSET

echo -e "$OK DaemonSet Worker déployé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Création Services et Ingress                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Service et Ingress
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'SERVICEINGRESS'
kubectl apply -f - <<'EOF'
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
EOF
SERVICEINGRESS

echo -e "$OK Services et Ingress créés"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 7: Attente démarrage pods (120s)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

sleep 120

echo ""
echo "État des pods Chatwoot :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n chatwoot -o wide"

echo ""
echo "État du service :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get svc -n chatwoot"

echo ""
echo "État de l'Ingress :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get ingress -n chatwoot"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CHATWOOT DAEMONSET DÉPLOYÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Architecture :"
echo "  ✓ Type       : DaemonSet avec hostNetwork (comme n8n/litellm/qdrant)"
echo "  ✓ Pods Web   : 1 pod par nœud (8 nœuds = 8 pods)"
echo "  ✓ Pods Worker: 1 pod par nœud (8 nœuds = 8 pods)"
echo "  ✓ Port       : 3000 (hostPort sur chaque nœud)"
echo "  ✓ PostgreSQL : 10.0.0.10:5432"
echo "  ✓ Redis      : 10.0.0.10:6379"
echo ""
echo "URL d'accès : http://chat.keybuzz.io"
echo ""
echo "Configuration première utilisation :"
echo "  1. Ouvrir http://chat.keybuzz.io"
echo "  2. Créer le premier compte (sera automatiquement admin)"
echo "  3. Configurer votre workspace"
echo ""
echo "Prochaine étape :"
echo "  ./17_deploy_superset_daemonset_FIXED.sh"
echo ""
