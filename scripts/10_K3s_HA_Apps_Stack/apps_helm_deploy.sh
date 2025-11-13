#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              K3S HA APPS - Déploiement Helm & Manifests           ║"
echo "║         (n8n, Chatwoot, ERPNext, LiteLLM, Qdrant, Superset)       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
APPS_DIR="/opt/keybuzz-installer/apps"

# Vérifications préalables
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
[ ! -d "$APPS_DIR" ] && { echo -e "$KO Répertoire apps introuvable, lancez d'abord ./apps_prepare_env.sh"; exit 1; }

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/apps_helm_deploy.log"

# Récupérer l'IP du master-01
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable"
    exit 1
fi

echo "" | tee -a "$LOG_FILE"
echo "═══ Configuration ═══" | tee -a "$LOG_FILE"
echo "  Master-01         : $IP_MASTER01" | tee -a "$LOG_FILE"
echo "  Apps .env         : $APPS_DIR" | tee -a "$LOG_FILE"
echo "  Log               : $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Applications à déployer :" | tee -a "$LOG_FILE"
echo "  1. n8n       - Workflow automation" | tee -a "$LOG_FILE"
echo "  2. Chatwoot  - Customer support" | tee -a "$LOG_FILE"
echo "  3. ERPNext   - ERP/CRM" | tee -a "$LOG_FILE"
echo "  4. LiteLLM   - LLM Router" | tee -a "$LOG_FILE"
echo "  5. Qdrant    - Vector database" | tee -a "$LOG_FILE"
echo "  6. Superset  - Business Intelligence" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

read -p "Démarrer le déploiement des applications ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Installation de Helm sur master-01
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 1/7 : Installation de Helm ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'HELM_INSTALL' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Vérification de Helm..."

if command -v helm &>/dev/null; then
    HELM_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
    echo "  ✓ Helm déjà installé : $HELM_VERSION"
else
    echo "[$(date '+%F %T')] Installation de Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "  ✓ Helm installé"
fi

# Ajouter les repos Helm nécessaires
echo "[$(date '+%F %T')] Configuration des repos Helm..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
helm repo add qdrant https://qdrant.github.io/qdrant-helm 2>/dev/null || true
helm repo update >/dev/null 2>&1
echo "  ✓ Repos Helm configurés"

HELM_INSTALL

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Copier les .env vers master-01
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 2/7 : Copie des fichiers .env vers master-01 ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Créer le répertoire sur master-01
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "mkdir -p /opt/keybuzz/apps" | tee -a "$LOG_FILE"

# Copier tous les .env
for env_file in n8n.env chatwoot.env erpnext.env litellm.env qdrant.env superset.env; do
    if [ -f "$APPS_DIR/$env_file" ]; then
        scp -o StrictHostKeyChecking=no "$APPS_DIR/$env_file" root@"$IP_MASTER01":/opt/keybuzz/apps/ 2>&1 | tee -a "$LOG_FILE"
        echo -e "  $OK $env_file copié" | tee -a "$LOG_FILE"
    else
        echo -e "  $WARN $env_file introuvable, skip" | tee -a "$LOG_FILE"
    fi
done

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Créer les secrets Kubernetes depuis les .env
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 3/7 : Création des secrets Kubernetes ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'SECRETS_CREATE' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Création des secrets depuis les .env..."

for app in n8n chatwoot erpnext litellm qdrant superset; do
    if [ -f "/opt/keybuzz/apps/${app}.env" ]; then
        # Supprimer le secret s'il existe
        kubectl delete secret ${app}-config -n ${app} 2>/dev/null || true
        
        # Créer le secret depuis le .env
        kubectl create secret generic ${app}-config \
            --from-env-file=/opt/keybuzz/apps/${app}.env \
            -n ${app} >/dev/null 2>&1
        
        echo "  ✓ Secret ${app}-config créé dans namespace ${app}"
    else
        echo "  ✗ Fichier ${app}.env introuvable, skip"
    fi
done

SECRETS_CREATE

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : Déployer n8n
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 4/7 : Déploiement n8n ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'N8N_DEPLOY' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Déploiement n8n..."

# Créer le manifeste n8n
cat > /tmp/n8n-deployment.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data
  namespace: n8n
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  namespace: n8n
  labels:
    app: n8n
spec:
  replicas: 2
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      containers:
      - name: n8n
        image: n8nio/n8n:latest
        ports:
        - containerPort: 5678
          name: http
        envFrom:
        - secretRef:
            name: n8n-config
        volumeMounts:
        - name: data
          mountPath: /home/node/.n8n
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 5678
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /healthz
            port: 5678
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: n8n-data
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
  - port: 80
    targetPort: 5678
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
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
              number: 80
EOF

kubectl apply -f /tmp/n8n-deployment.yaml
echo "  ✓ n8n déployé"

N8N_DEPLOY

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 5 : Déployer Chatwoot
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 5/7 : Déploiement Chatwoot ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CHATWOOT_DEPLOY' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Déploiement Chatwoot..."

# Créer le manifeste Chatwoot
cat > /tmp/chatwoot-deployment.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: chatwoot-storage
  namespace: chatwoot
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatwoot-web
  namespace: chatwoot
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chatwoot-web
  template:
    metadata:
      labels:
        app: chatwoot-web
    spec:
      initContainers:
      - name: db-migrate
        image: chatwoot/chatwoot:latest
        command: ['bundle', 'exec', 'rails', 'db:chatwoot_prepare']
        envFrom:
        - secretRef:
            name: chatwoot-config
      containers:
      - name: chatwoot
        image: chatwoot/chatwoot:latest
        ports:
        - containerPort: 3000
        envFrom:
        - secretRef:
            name: chatwoot-config
        volumeMounts:
        - name: storage
          mountPath: /app/storage
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: chatwoot-storage
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatwoot-worker
  namespace: chatwoot
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chatwoot-worker
  template:
    metadata:
      labels:
        app: chatwoot-worker
    spec:
      containers:
      - name: worker
        image: chatwoot/chatwoot:latest
        command: ['bundle', 'exec', 'sidekiq', '-C', 'config/sidekiq.yml']
        envFrom:
        - secretRef:
            name: chatwoot-config
        volumeMounts:
        - name: storage
          mountPath: /app/storage
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: chatwoot-storage
---
apiVersion: v1
kind: Service
metadata:
  name: chatwoot
  namespace: chatwoot
spec:
  selector:
    app: chatwoot-web
  ports:
  - port: 80
    targetPort: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chatwoot
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
              number: 80
EOF

kubectl apply -f /tmp/chatwoot-deployment.yaml
echo "  ✓ Chatwoot déployé"

CHATWOOT_DEPLOY

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 6 : Déployer les autres applications (LiteLLM, Qdrant, Superset)
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 6/7 : Déploiement LiteLLM, Qdrant, Superset ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# LiteLLM
echo "→ Déploiement LiteLLM..." | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'LITELLM_DEPLOY' | tee -a "$LOG_FILE"
cat > /tmp/litellm-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: litellm
spec:
  replicas: 2
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
    spec:
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main-latest
        ports:
        - containerPort: 4000
        envFrom:
        - secretRef:
            name: litellm-config
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
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
  - port: 80
    targetPort: 4000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
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
              number: 80
EOF

kubectl apply -f /tmp/litellm-deployment.yaml
echo "  ✓ LiteLLM déployé"
LITELLM_DEPLOY

# Qdrant
echo "→ Déploiement Qdrant..." | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'QDRANT_DEPLOY' | tee -a "$LOG_FILE"
cat > /tmp/qdrant-deployment.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qdrant-storage
  namespace: qdrant
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: qdrant
  namespace: qdrant
spec:
  serviceName: qdrant
  replicas: 1
  selector:
    matchLabels:
      app: qdrant
  template:
    metadata:
      labels:
        app: qdrant
    spec:
      containers:
      - name: qdrant
        image: qdrant/qdrant:latest
        ports:
        - containerPort: 6333
          name: http
        - containerPort: 6334
          name: grpc
        envFrom:
        - secretRef:
            name: qdrant-config
        volumeMounts:
        - name: storage
          mountPath: /qdrant/storage
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: qdrant-storage
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
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qdrant
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
EOF

kubectl apply -f /tmp/qdrant-deployment.yaml
echo "  ✓ Qdrant déployé"
QDRANT_DEPLOY

# Superset
echo "→ Déploiement Superset..." | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'SUPERSET_DEPLOY' | tee -a "$LOG_FILE"
cat > /tmp/superset-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: superset
  namespace: superset
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
      initContainers:
      - name: init-db
        image: apache/superset:latest
        command: ['superset', 'db', 'upgrade']
        envFrom:
        - secretRef:
            name: superset-config
      - name: init-admin
        image: apache/superset:latest
        command: ['superset', 'fab', 'create-admin', '--username', 'admin', '--firstname', 'Admin', '--lastname', 'User', '--email', 'admin@keybuzz.io', '--password', 'changeme']
        envFrom:
        - secretRef:
            name: superset-config
      - name: init-roles
        image: apache/superset:latest
        command: ['superset', 'init']
        envFrom:
        - secretRef:
            name: superset-config
      containers:
      - name: superset
        image: apache/superset:latest
        ports:
        - containerPort: 8088
        envFrom:
        - secretRef:
            name: superset-config
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
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
  - port: 80
    targetPort: 8088
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset
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
              number: 80
EOF

kubectl apply -f /tmp/superset-deployment.yaml
echo "  ✓ Superset déployé"
SUPERSET_DEPLOY

echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 7 : Vérification des déploiements
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 7/7 : Vérification des déploiements ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Attente du démarrage des pods (60s)..." | tee -a "$LOG_FILE"
sleep 60

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'STATUS_CHECK' | tee -a "$LOG_FILE"
echo ""
echo "État des applications :"
echo ""

for ns in n8n chatwoot litellm qdrant superset; do
    echo "━━━ Namespace: $ns ━━━"
    kubectl get pods -n $ns -o wide 2>/dev/null || echo "  Aucun pod"
    echo ""
done

echo "━━━ Ingress configurés ━━━"
kubectl get ingress -A 2>/dev/null | grep -E "n8n|chatwoot|litellm|qdrant|superset" || echo "Aucun ingress"
echo ""

STATUS_CHECK

# ═══════════════════════════════════════════════════════════════════════════
# Résumé final
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo -e "$OK DÉPLOIEMENT DES APPLICATIONS TERMINÉ" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Applications déployées :" | tee -a "$LOG_FILE"
echo "  ✓ n8n        → https://n8n.keybuzz.io" | tee -a "$LOG_FILE"
echo "  ✓ Chatwoot   → https://chat.keybuzz.io" | tee -a "$LOG_FILE"
echo "  ✓ LiteLLM    → https://llm.keybuzz.io" | tee -a "$LOG_FILE"
echo "  ✓ Qdrant     → https://qdrant.keybuzz.io" | tee -a "$LOG_FILE"
echo "  ✓ Superset   → https://superset.keybuzz.io" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Note : ERPNext nécessite un chart Helm spécifique (non inclus dans ce script)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Commandes utiles :" | tee -a "$LOG_FILE"
echo "  # Voir l'état des pods" | tee -a "$LOG_FILE"
echo "  ssh root@$IP_MASTER01 kubectl get pods -A" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Voir les ingress" | tee -a "$LOG_FILE"
echo "  ssh root@$IP_MASTER01 kubectl get ingress -A" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Logs d'une application" | tee -a "$LOG_FILE"
echo "  ssh root@$IP_MASTER01 kubectl logs -n n8n -l app=n8n" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Prochaine étape :" | tee -a "$LOG_FILE"
echo "  ./apps_final_tests.sh" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "═══════════════════════════════════════════════════════════════════"
echo "Log complet (50 dernières lignes) :"
echo "═══════════════════════════════════════════════════════════════════"
tail -n 50 "$LOG_FILE"

exit 0
