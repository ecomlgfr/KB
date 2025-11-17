#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# DÉPLOIEMENT ERPNEXT SUR K3S - KeyBuzz Standards (NON-INTERACTIVE)
###############################################################################
# Auteur: Claude AI Assistant
# Date: 2025-11-13
# Version: 2.1 (Automated)
#
# Description:
#   Déploiement automatique de ERPNext sur K3s
#   Mode non-interactif pour orchestration depuis install-01
#
# Usage:
#   ENV_FILE=/path/to/.env ./deploy_erpnext_auto.sh
###############################################################################

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

###############################################################################
# LOAD CONFIGURATION
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.mariadb_proxysql_erpnext}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERREUR: Fichier $ENV_FILE introuvable!"
    exit 1
fi

# Load environment
set -a
source "$ENV_FILE"
set +a

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "${KO} ERREUR: $1"
    exit 1
}

###############################################################################
# CHECK PREREQUISITES
###############################################################################

check_prerequisites() {
    log "${INFO} Vérification des prérequis..."

    if ! command -v kubectl &> /dev/null; then
        error_exit "kubectl n'est pas installé"
    fi

    if ! kubectl cluster-info &> /dev/null; then
        error_exit "K3s cluster non accessible"
    fi

    log "${OK} Prérequis vérifiés"
}

###############################################################################
# CREATE NAMESPACE
###############################################################################

create_namespace() {
    log "${INFO} Création du namespace $ERPNEXT_NAMESPACE..."

    kubectl create namespace "$ERPNEXT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    log "${OK} Namespace créé"
}

###############################################################################
# DEPLOY REDIS
###############################################################################

deploy_redis() {
    log "${INFO} Déploiement des instances Redis..."

    # Redis Cache
    kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-cache
  namespace: $ERPNEXT_NAMESPACE
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
        command: ["redis-server", "--maxmemory", "512mb", "--maxmemory-policy", "allkeys-lru"]
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis-cache
  namespace: $ERPNEXT_NAMESPACE
spec:
  selector:
    app: redis-cache
  ports:
  - port: 6379
EOF

    # Redis Queue
    kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-queue
  namespace: $ERPNEXT_NAMESPACE
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
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis-queue
  namespace: $ERPNEXT_NAMESPACE
spec:
  selector:
    app: redis-queue
  ports:
  - port: 6379
EOF

    # Redis Socketio
    kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-socketio
  namespace: $ERPNEXT_NAMESPACE
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
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "250m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis-socketio
  namespace: $ERPNEXT_NAMESPACE
spec:
  selector:
    app: redis-socketio
  ports:
  - port: 6379
EOF

    log "${OK} Redis déployé"
}

###############################################################################
# CREATE SECRETS
###############################################################################

create_secrets() {
    log "${INFO} Création des secrets..."

    kubectl create secret generic erpnext-secrets \
        --namespace="$ERPNEXT_NAMESPACE" \
        --from-literal=db-host="$HETZNER_LB_IP" \
        --from-literal=db-port="$HETZNER_LB_PORT" \
        --from-literal=db-name="$ERPNEXT_DB_NAME" \
        --from-literal=db-user="$ERPNEXT_DB_USER" \
        --from-literal=db-password="$ERPNEXT_DB_PASSWORD" \
        --from-literal=db-root-password="$MYSQL_ROOT_PASSWORD" \
        --from-literal=admin-password="$ERPNEXT_ADMIN_PASSWORD" \
        --from-literal=redis-cache="$REDIS_CACHE_URL" \
        --from-literal=redis-queue="$REDIS_QUEUE_URL" \
        --from-literal=redis-socketio="$REDIS_SOCKETIO_URL" \
        --from-literal=site-name="$ERPNEXT_SITE_NAME" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    log "${OK} Secrets créés"
}

###############################################################################
# CREATE PVC
###############################################################################

create_pvc() {
    log "${INFO} Création du PVC pour les sites..."

    kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: erpnext-sites
  namespace: $ERPNEXT_NAMESPACE
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: longhorn
EOF

    log "${OK} PVC créé"
}

###############################################################################
# DEPLOY CREATE SITE JOB
###############################################################################

deploy_create_site_job() {
    log "${INFO} Déploiement du job de création du site ERPNext..."

    kubectl apply -f - <<EOF >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: erpnext-create-site
  namespace: $ERPNEXT_NAMESPACE
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: create-site
        image: frappe/erpnext:$ERPNEXT_VERSION
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

          bench new-site \$SITE_NAME \
            --db-host=\$DB_HOST \
            --db-port=\$DB_PORT \
            --db-name=\$DB_NAME \
            --mariadb-user-host-login-scope='%' \
            --db-user=\$DB_USER \
            --db-password=\$DB_PASSWORD \
            --admin-password=\$ADMIN_PASSWORD \
            --mariadb-root-password=\$DB_ROOT_PASSWORD \
            --install-app erpnext \
            --set-default

          echo "Site created successfully!"

          # Configuration Redis
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
EOF

    log "${OK} Job de création du site déployé"
    log "${INFO} Attente de la fin du job (peut prendre 5-10 minutes)..."

    # Attendre la fin du job
    if kubectl wait --for=condition=complete --timeout=${WAIT_ERPNEXT_JOB}s job/erpnext-create-site -n "$ERPNEXT_NAMESPACE" 2>/dev/null; then
        log "${OK} Job terminé avec succès"
    else
        log "${WARN} Le job n'a pas terminé dans le temps imparti"
        log "Vérifier les logs: kubectl logs -n $ERPNEXT_NAMESPACE job/erpnext-create-site"
    fi
}

###############################################################################
# DEPLOY COMPONENTS
###############################################################################

deploy_backend() {
    log "${INFO} Déploiement du backend ERPNext..."

    kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-backend
  namespace: $ERPNEXT_NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: erpnext-backend
  template:
    metadata:
      labels:
        app: erpnext-backend
    spec:
      containers:
      - name: backend
        image: frappe/erpnext:$ERPNEXT_VERSION
        command: ["bench", "start", "--skip-redis-config-generation"]
        ports:
        - containerPort: 8000
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
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
---
apiVersion: v1
kind: Service
metadata:
  name: erpnext-backend
  namespace: $ERPNEXT_NAMESPACE
spec:
  selector:
    app: erpnext-backend
  ports:
  - port: 8000
EOF

    log "${OK} Backend déployé"
}

deploy_socketio() {
    log "${INFO} Déploiement de Socketio..."

    kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-socketio
  namespace: $ERPNEXT_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: erpnext-socketio
  template:
    metadata:
      labels:
        app: erpnext-socketio
    spec:
      containers:
      - name: socketio
        image: frappe/erpnext:$ERPNEXT_VERSION
        command: ["node", "apps/frappe/socketio.js"]
        ports:
        - containerPort: 9000
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
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
---
apiVersion: v1
kind: Service
metadata:
  name: erpnext-socketio
  namespace: $ERPNEXT_NAMESPACE
spec:
  selector:
    app: erpnext-socketio
  ports:
  - port: 9000
EOF

    log "${OK} Socketio déployé"
}

deploy_workers() {
    log "${INFO} Déploiement des workers..."

    # Workers default, short, long...
    for queue in default short long; do
        replicas=2
        [[ "$queue" == "long" ]] && replicas=1

        kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-worker-$queue
  namespace: $ERPNEXT_NAMESPACE
spec:
  replicas: $replicas
  selector:
    matchLabels:
      app: erpnext-worker-$queue
  template:
    metadata:
      labels:
        app: erpnext-worker-$queue
    spec:
      containers:
      - name: worker
        image: frappe/erpnext:$ERPNEXT_VERSION
        command: ["bench", "worker", "--queue", "$queue"]
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
    done

    log "${OK} Workers déployés"
}

deploy_scheduler() {
    log "${INFO} Déploiement du scheduler..."

    kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-scheduler
  namespace: $ERPNEXT_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: erpnext-scheduler
  template:
    metadata:
      labels:
        app: erpnext-scheduler
    spec:
      containers:
      - name: scheduler
        image: frappe/erpnext:$ERPNEXT_VERSION
        command: ["bench", "schedule"]
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

deploy_frontend() {
    log "${INFO} Déploiement du frontend..."

    kubectl apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erpnext-frontend
  namespace: $ERPNEXT_NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: erpnext-frontend
  template:
    metadata:
      labels:
        app: erpnext-frontend
    spec:
      containers:
      - name: nginx
        image: frappe/erpnext:$ERPNEXT_VERSION
        command: ["nginx", "-g", "daemon off;"]
        ports:
        - containerPort: 8080
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
      volumes:
      - name: sites
        persistentVolumeClaim:
          claimName: erpnext-sites
---
apiVersion: v1
kind: Service
metadata:
  name: erpnext-frontend
  namespace: $ERPNEXT_NAMESPACE
spec:
  selector:
    app: erpnext-frontend
  ports:
  - port: 80
    targetPort: 8080
EOF

    log "${OK} Frontend déployé"
}

deploy_ingress() {
    log "${INFO} Déploiement de l'Ingress..."

    kubectl apply -f - <<EOF >/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: erpnext
  namespace: $ERPNEXT_NAMESPACE
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  tls:
  - hosts:
    - $ERPNEXT_SITE_NAME
    secretName: erpnext-tls
  rules:
  - host: $ERPNEXT_SITE_NAME
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

###############################################################################
# SAVE CREDENTIALS
###############################################################################

save_credentials() {
    log "${INFO} Sauvegarde des credentials..."

    mkdir -p /opt/keybuzz/erpnext
    CRED_FILE="/opt/keybuzz/erpnext/credentials_erpnext.sh"

    cat > "$CRED_FILE" <<EOF
#!/usr/bin/env bash
# CREDENTIALS ERPNEXT
# Généré: $(date)

export SITE_NAME="$ERPNEXT_SITE_NAME"
export SITE_URL="https://$ERPNEXT_SITE_NAME"
export ADMIN_USER="Administrator"
export ADMIN_PASSWORD="$ERPNEXT_ADMIN_PASSWORD"
export DB_HOST="$HETZNER_LB_IP"
export DB_PORT="$HETZNER_LB_PORT"
export DB_NAME="$ERPNEXT_DB_NAME"
export DB_USER="$ERPNEXT_DB_USER"
export DB_PASSWORD="$ERPNEXT_DB_PASSWORD"
export NAMESPACE="$ERPNEXT_NAMESPACE"

# Connexion: https://$ERPNEXT_SITE_NAME
# User: Administrator
# Password: $ERPNEXT_ADMIN_PASSWORD
EOF

    chmod 600 "$CRED_FILE"

    log "${OK} Credentials sauvegardés: $CRED_FILE"
}

###############################################################################
# MAIN
###############################################################################

main() {
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║  DÉPLOIEMENT ERPNEXT SUR K3S (Automated)                     ║"
    log "╚═══════════════════════════════════════════════════════════════╝"

    check_prerequisites

    log "${INFO} Début du déploiement automatique..."

    create_namespace
    deploy_redis
    create_secrets
    create_pvc
    deploy_create_site_job
    deploy_backend
    deploy_socketio
    deploy_workers
    deploy_scheduler
    deploy_frontend
    deploy_ingress
    save_credentials

    log "${OK} Déploiement ERPNext terminé"
    log "${INFO} Site: https://$ERPNEXT_SITE_NAME"
    log "${INFO} Admin: Administrator / $ERPNEXT_ADMIN_PASSWORD"
}

main "$@"
