#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# DÉPLOIEMENT ERPNEXT SUR K3S - KeyBuzz Standards
###############################################################################
# Auteur: Claude AI Assistant
# Date: 2025-11-13
# Version: 2.0
#
# Description:
#   Déploiement complet de ERPNext sur Kubernetes K3s avec :
#   - Connexion à MariaDB Galera via ProxySQL + Hetzner LB
#   - Redis pour cache et queue
#   - Components: Backend, Frontend, Scheduler, Workers, Socketio
#   - Ingress NGINX avec TLS
#   - Secrets sécurisés
#
# Prérequis:
#   - MariaDB Galera cluster opérationnel (3 noeuds)
#   - ProxySQL configuré (2 noeuds)
#   - Hetzner LB configuré (10.0.0.10:6033)
#   - K3s cluster opérationnel
#   - Ingress NGINX installé
#
# Usage:
#   ./deploy_erpnext_k3s.sh
###############################################################################

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

###############################################################################
# CONFIGURATION
###############################################################################

# Namespace
NAMESPACE="erpnext"

# ERPNext Version
ERPNEXT_VERSION="v15"
ERPNEXT_IMAGE="frappe/erpnext:${ERPNEXT_VERSION}"

# Database (via Hetzner LB -> ProxySQL -> MariaDB Galera)
DB_HOST="10.0.0.10"
DB_PORT="6033"
DB_NAME="erpnext"
DB_USER="erpnext"
DB_PASSWORD=""  # Sera demandé interactivement
DB_ROOT_PASSWORD=""  # Pour l'initialisation

# Redis
REDIS_CACHE_URL=""
REDIS_QUEUE_URL=""
REDIS_SOCKETIO_URL=""

# Site
SITE_NAME="erp.keybuzz.local"  # À adapter selon votre domaine

# Admin
ADMIN_PASSWORD="ChangeMe_Admin_$(openssl rand -hex 8)"

# Resources
BACKEND_REPLICAS=2
WORKER_SHORT_REPLICAS=2
WORKER_LONG_REPLICAS=1
WORKER_DEFAULT_REPLICAS=2

###############################################################################
# FONCTIONS
###############################################################################

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "${KO} ERREUR: $1"
    exit 1
}

check_prerequisites() {
    log "${INFO} Vérification des prérequis..."

    # Kubectl
    if ! command -v kubectl &> /dev/null; then
        error_exit "kubectl n'est pas installé"
    fi

    # K3s cluster accessible
    if ! kubectl cluster-info &> /dev/null; then
        error_exit "K3s cluster non accessible"
    fi

    # Ingress NGINX
    if ! kubectl get namespace ingress-nginx &> /dev/null; then
        log "${WARN} Namespace ingress-nginx non trouvé"
        log "Installer Ingress NGINX d'abord"
    fi

    log "${OK} Prérequis vérifiés"
}

get_credentials() {
    log "${INFO} Récupération des credentials..."
    echo ""
    echo "Ces credentials doivent correspondre à ceux générés lors de"
    echo "l'installation de MariaDB et ProxySQL"
    echo ""

    # Database User
    read -p "Database User [$DB_USER]: " input
    DB_USER="${input:-$DB_USER}"

    read -sp "Database Password: " DB_PASSWORD
    echo ""

    if [[ -z "$DB_PASSWORD" ]]; then
        error_exit "Le mot de passe database est requis"
    fi

    # Database Root (pour initialisation)
    read -sp "Database Root Password (pour init): " DB_ROOT_PASSWORD
    echo ""

    if [[ -z "$DB_ROOT_PASSWORD" ]]; then
        error_exit "Le mot de passe root est requis"
    fi

    # Site Name
    read -p "Site Name (domain) [$SITE_NAME]: " input
    SITE_NAME="${input:-$SITE_NAME}"

    # Redis URLs (par défaut, utilise Redis dans le même namespace)
    REDIS_CACHE_URL="redis://redis-cache:6379"
    REDIS_QUEUE_URL="redis://redis-queue:6379"
    REDIS_SOCKETIO_URL="redis://redis-socketio:6379"

    log "${OK} Credentials récupérés"
}

create_namespace() {
    log "${INFO} Création du namespace $NAMESPACE..."

    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    log "${OK} Namespace créé"
}

deploy_redis() {
    log "${INFO} Déploiement des instances Redis..."

    # Redis Cache
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-cache
  namespace: $NAMESPACE
  labels:
    app: redis-cache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-cache
  template:
    metadata:
      labels:
        app: redis-cache
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        command: ["redis-server"]
        args: ["--maxmemory", "512mb", "--maxmemory-policy", "allkeys-lru"]
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ["redis-cli", "ping"]
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: redis-cache
  namespace: $NAMESPACE
spec:
  selector:
    app: redis-cache
  ports:
  - port: 6379
    targetPort: 6379
EOF

    # Redis Queue
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-queue
  namespace: $NAMESPACE
  labels:
    app: redis-queue
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-queue
  template:
    metadata:
      labels:
        app: redis-queue
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        command: ["redis-server"]
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ["redis-cli", "ping"]
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: redis-queue
  namespace: $NAMESPACE
spec:
  selector:
    app: redis-queue
  ports:
  - port: 6379
    targetPort: 6379
EOF

    # Redis Socketio
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-socketio
  namespace: $NAMESPACE
  labels:
    app: redis-socketio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-socketio
  template:
    metadata:
      labels:
        app: redis-socketio
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        command: ["redis-server"]
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "250m"
        livenessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ["redis-cli", "ping"]
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: redis-socketio
  namespace: $NAMESPACE
spec:
  selector:
    app: redis-socketio
  ports:
  - port: 6379
    targetPort: 6379
EOF

    log "${OK} Redis déployé (cache, queue, socketio)"
}

create_secrets() {
    log "${INFO} Création des secrets..."

    kubectl create secret generic erpnext-secrets \
        --namespace="$NAMESPACE" \
        --from-literal=db-host="$DB_HOST" \
        --from-literal=db-port="$DB_PORT" \
        --from-literal=db-name="$DB_NAME" \
        --from-literal=db-user="$DB_USER" \
        --from-literal=db-password="$DB_PASSWORD" \
        --from-literal=db-root-password="$DB_ROOT_PASSWORD" \
        --from-literal=admin-password="$ADMIN_PASSWORD" \
        --from-literal=redis-cache="$REDIS_CACHE_URL" \
        --from-literal=redis-queue="$REDIS_QUEUE_URL" \
        --from-literal=redis-socketio="$REDIS_SOCKETIO_URL" \
        --from-literal=site-name="$SITE_NAME" \
        --dry-run=client -o yaml | kubectl apply -f -

    log "${OK} Secrets créés"
}

deploy_create_site_job() {
    log "${INFO} Déploiement du job de création du site ERPNext..."

    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: erpnext-create-site
  namespace: $NAMESPACE
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        job: create-site
    spec:
      restartPolicy: Never
      containers:
      - name: create-site
        image: $ERPNEXT_IMAGE
        command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "Waiting for database..."
          until nc -z \$DB_HOST \$DB_PORT; do
            echo "Database not ready, waiting..."
            sleep 5
          done

          echo "Creating ERPNext site: \$SITE_NAME"

          bench new-site \$SITE_NAME \\
            --db-host=\$DB_HOST \\
            --db-port=\$DB_PORT \\
            --db-name=\$DB_NAME \\
            --db-user=\$DB_USER \\
            --db-password=\$DB_PASSWORD \\
            --admin-password=\$ADMIN_PASSWORD \\
            --mariadb-root-password=\$DB_ROOT_PASSWORD \\
            --install-app erpnext \\
            --set-default

          echo "Site created successfully!"

          # Configuration supplémentaire
          bench --site \$SITE_NAME set-config -g redis_cache "\$REDIS_CACHE"
          bench --site \$SITE_NAME set-config -g redis_queue "\$REDIS_QUEUE"
          bench --site \$SITE_NAME set-config -g redis_socketio "\$REDIS_SOCKETIO"

          echo "Site configuration complete!"
        env:
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: db-host
        - name: DB_PORT
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: db-port
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: db-name
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: db-user
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: db-password
        - name: DB_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: db-root-password
        - name: ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: admin-password
        - name: SITE_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: site-name
        - name: REDIS_CACHE
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: redis-cache
        - name: REDIS_QUEUE
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: redis-queue
        - name: REDIS_SOCKETIO
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: redis-socketio
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: erpnext-sites
  namespace: $NAMESPACE
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: longhorn
EOF

    log "${OK} Job de création du site déployé"
    log "${INFO} Attente de la fin du job (peut prendre 5-10 minutes)..."

    # Attendre la fin du job
    kubectl wait --for=condition=complete --timeout=600s job/erpnext-create-site -n "$NAMESPACE" || {
        log "${WARN} Le job n'a pas terminé dans le temps imparti"
        log "Vérifier les logs: kubectl logs -n $NAMESPACE job/erpnext-create-site"
    }

    # Afficher les logs
    log "Logs du job:"
    kubectl logs -n "$NAMESPACE" job/erpnext-create-site || true
}

deploy_backend() {
    log "${INFO} Déploiement du backend ERPNext (Gunicorn)..."

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-backend
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: backend
spec:
  replicas: $BACKEND_REPLICAS
  selector:
    matchLabels:
      app.kubernetes.io/name: erpnext
      app.kubernetes.io/component: backend
  template:
    metadata:
      labels:
        app.kubernetes.io/name: erpnext
        app.kubernetes.io/component: backend
    spec:
      containers:
      - name: backend
        image: $ERPNEXT_IMAGE
        command: ["bench"]
        args: ["start", "--skip-redis-config-generation"]
        ports:
        - containerPort: 8000
          name: http
        env:
        - name: SITE_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: site-name
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1500m"
        livenessProbe:
          httpGet:
            path: /
            port: 8000
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
---
apiVersion: v1
kind: Service
metadata:
  name: erpnext-backend
  namespace: $NAMESPACE
spec:
  selector:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: backend
  ports:
  - port: 8000
    targetPort: 8000
    name: http
EOF

    log "${OK} Backend déployé"
}

deploy_scheduler() {
    log "${INFO} Déploiement du scheduler ERPNext..."

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-scheduler
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: scheduler
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: erpnext
      app.kubernetes.io/component: scheduler
  template:
    metadata:
      labels:
        app.kubernetes.io/name: erpnext
        app.kubernetes.io/component: scheduler
    spec:
      containers:
      - name: scheduler
        image: $ERPNEXT_IMAGE
        command: ["bench"]
        args: ["schedule"]
        env:
        - name: SITE_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: site-name
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
EOF

    log "${OK} Scheduler déployé"
}

deploy_workers() {
    log "${INFO} Déploiement des workers ERPNext..."

    # Worker Default
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-worker-default
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: worker-default
spec:
  replicas: $WORKER_DEFAULT_REPLICAS
  selector:
    matchLabels:
      app.kubernetes.io/name: erpnext
      app.kubernetes.io/component: worker-default
  template:
    metadata:
      labels:
        app.kubernetes.io/name: erpnext
        app.kubernetes.io/component: worker-default
    spec:
      containers:
      - name: worker
        image: $ERPNEXT_IMAGE
        command: ["bench"]
        args: ["worker", "--queue", "default"]
        env:
        - name: SITE_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: site-name
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
        resources:
          requests:
            memory: "512Mi"
            cpu: "300m"
          limits:
            memory: "1Gi"
            cpu: "800m"
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
EOF

    # Worker Short
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-worker-short
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: worker-short
spec:
  replicas: $WORKER_SHORT_REPLICAS
  selector:
    matchLabels:
      app.kubernetes.io/name: erpnext
      app.kubernetes.io/component: worker-short
  template:
    metadata:
      labels:
        app.kubernetes.io/name: erpnext
        app.kubernetes.io/component: worker-short
    spec:
      containers:
      - name: worker
        image: $ERPNEXT_IMAGE
        command: ["bench"]
        args: ["worker", "--queue", "short"]
        env:
        - name: SITE_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: site-name
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
        resources:
          requests:
            memory: "512Mi"
            cpu: "300m"
          limits:
            memory: "1Gi"
            cpu: "800m"
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
EOF

    # Worker Long
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-worker-long
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: worker-long
spec:
  replicas: $WORKER_LONG_REPLICAS
  selector:
    matchLabels:
      app.kubernetes.io/name: erpnext
      app.kubernetes.io/component: worker-long
  template:
    metadata:
      labels:
        app.kubernetes.io/name: erpnext
        app.kubernetes.io/component: worker-long
    spec:
      containers:
      - name: worker
        image: $ERPNEXT_IMAGE
        command: ["bench"]
        args: ["worker", "--queue", "long"]
        env:
        - name: SITE_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: site-name
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
        resources:
          requests:
            memory: "512Mi"
            cpu: "300m"
          limits:
            memory: "1Gi"
            cpu: "800m"
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
EOF

    log "${OK} Workers déployés (default, short, long)"
}

deploy_socketio() {
    log "${INFO} Déploiement de Socketio ERPNext..."

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-socketio
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: socketio
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: erpnext
      app.kubernetes.io/component: socketio
  template:
    metadata:
      labels:
        app.kubernetes.io/name: erpnext
        app.kubernetes.io/component: socketio
    spec:
      containers:
      - name: socketio
        image: $ERPNEXT_IMAGE
        command: ["node"]
        args: ["apps/frappe/socketio.js"]
        ports:
        - containerPort: 9000
          name: socketio
        env:
        - name: SITE_NAME
          valueFrom:
            secretKeyRef:
              name: erpnext-secrets
              key: site-name
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          tcpSocket:
            port: 9000
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          tcpSocket:
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
---
apiVersion: v1
kind: Service
metadata:
  name: erpnext-socketio
  namespace: $NAMESPACE
spec:
  selector:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: socketio
  ports:
  - port: 9000
    targetPort: 9000
    name: socketio
EOF

    log "${OK} Socketio déployé"
}

deploy_frontend() {
    log "${INFO} Déploiement du frontend ERPNext (Nginx)..."

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-frontend
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: erpnext
      app.kubernetes.io/component: frontend
  template:
    metadata:
      labels:
        app.kubernetes.io/name: erpnext
        app.kubernetes.io/component: frontend
    spec:
      containers:
      - name: nginx
        image: $ERPNEXT_IMAGE
        command: ["nginx"]
        args: ["-g", "daemon off;"]
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: sites
          mountPath: /home/frappe/frappe-bench/sites
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
---
apiVersion: v1
kind: Service
metadata:
  name: erpnext-frontend
  namespace: $NAMESPACE
spec:
  selector:
    app.kubernetes.io/name: erpnext
    app.kubernetes.io/component: frontend
  ports:
  - port: 80
    targetPort: 8080
    name: http
EOF

    log "${OK} Frontend déployé"
}

deploy_ingress() {
    log "${INFO} Déploiement de l'Ingress ERPNext..."

    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: erpnext
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
spec:
  tls:
  - hosts:
    - $SITE_NAME
    secretName: erpnext-tls
  rules:
  - host: $SITE_NAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: erpnext-frontend
            port:
              number: 80
EOF

    log "${OK} Ingress déployé"
}

save_credentials() {
    log "${INFO} Sauvegarde des credentials..."

    CRED_FILE="/opt/keybuzz/erpnext/credentials_erpnext.txt"
    mkdir -p /opt/keybuzz/erpnext

    cat > "$CRED_FILE" <<EOF
#######################################################################
# CREDENTIALS ERPNEXT
# Généré: $(date)
# ATTENTION: Fichier sensible - à sécuriser!
#######################################################################

# Site
SITE_NAME="$SITE_NAME"
SITE_URL="https://$SITE_NAME"

# Admin
ADMIN_USER="Administrator"
ADMIN_PASSWORD="$ADMIN_PASSWORD"

# Database (via Hetzner LB -> ProxySQL -> MariaDB Galera)
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"

# Redis
REDIS_CACHE="$REDIS_CACHE_URL"
REDIS_QUEUE="$REDIS_QUEUE_URL"
REDIS_SOCKETIO="$REDIS_SOCKETIO_URL"

# Connexion
LOGIN_URL="https://$SITE_NAME/login"

# Kubernetes
NAMESPACE="$NAMESPACE"

# Commandes utiles
# kubectl get pods -n $NAMESPACE
# kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=backend
# kubectl exec -n $NAMESPACE -it <pod-name> -- bash

EOF

    chmod 600 "$CRED_FILE"

    log "${OK} Credentials sauvegardés: $CRED_FILE"
}

display_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "            DÉPLOIEMENT ERPNEXT TERMINÉ"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    log "${OK} ERPNext déployé avec succès sur K3s"
    echo ""
    echo "📋 RÉSUMÉ:"
    echo ""
    echo "  🌐 Site: https://$SITE_NAME"
    echo "  👤 Admin: Administrator"
    echo "  🔑 Password: $ADMIN_PASSWORD"
    echo ""
    echo "  💾 Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "  📦 Namespace: $NAMESPACE"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "📊 État des pods:"
    kubectl get pods -n "$NAMESPACE" -o wide
    echo ""
    echo "🔍 Vérifications:"
    echo "  • kubectl get pods -n $NAMESPACE"
    echo "  • kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=backend"
    echo "  • kubectl describe ingress -n $NAMESPACE erpnext"
    echo ""
    echo "📁 Credentials: /opt/keybuzz/erpnext/credentials_erpnext.txt"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

###############################################################################
# MAIN
###############################################################################

main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                   ║"
    echo "║         DÉPLOIEMENT ERPNEXT SUR K3S - KeyBuzz v2.0              ║"
    echo "║                                                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    get_credentials

    echo ""
    log "${INFO} Configuration:"
    echo "  • Site: $SITE_NAME"
    echo "  • Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "  • Namespace: $NAMESPACE"
    echo ""
    read -p "Continuer le déploiement ? (yes/NO): " confirm
    [[ "$confirm" != "yes" ]] && error_exit "Déploiement annulé"

    echo ""
    log "Début du déploiement..."
    echo ""

    # Étapes de déploiement
    create_namespace
    deploy_redis
    create_secrets
    deploy_create_site_job
    deploy_backend
    deploy_scheduler
    deploy_workers
    deploy_socketio
    deploy_frontend
    deploy_ingress
    save_credentials

    sleep 10

    display_summary

    log "${OK} Déploiement terminé avec succès!"
}

# Exécution
main "$@"
