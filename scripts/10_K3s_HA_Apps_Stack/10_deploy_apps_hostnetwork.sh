#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Apps en DaemonSets (hostNetwork)             ║"
echo "║    (n8n, litellm, qdrant - Solution VXLAN)                        ║"
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
    echo -e "$WARN PostgreSQL credentials non trouvés"
    POSTGRES_PASSWORD="keybuzz2025"
fi

# Charger Redis credentials
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN Redis credentials non trouvés"
    REDIS_PASSWORD="keybuzz2025"
fi

echo ""
echo "IMPORTANT :"
echo "  ❌ Pas de Helm / Deployments classiques"
echo "  ✅ DaemonSets avec hostNetwork"
echo ""
echo "Raison :"
echo "  VXLAN bloqué sur Hetzner"
echo "  → hostNetwork = Communication locale"
echo ""
echo "Services à déployer :"
echo "  - n8n       (Workflow automation)"
echo "  - litellm   (LLM Router)"
echo "  - qdrant    (Vector database)"
echo ""
echo "Services NON déployés (à faire manuellement) :"
echo "  - chatwoot  (Trop complexe, nécessite setup DB)"
echo "  - superset  (Erreur de port, à corriger)"
echo ""

read -p "Déployer les apps ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création des namespaces ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace n8n 2>/dev/null || true
kubectl create namespace litellm 2>/dev/null || true
kubectl create namespace qdrant 2>/dev/null || true

echo -e "$OK Namespaces créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création des Secrets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# n8n secret
kubectl create secret generic n8n-secrets -n n8n \
  --from-literal=DB_TYPE=postgresdb \
  --from-literal=DB_POSTGRESDB_HOST=10.0.0.10 \
  --from-literal=DB_POSTGRESDB_PORT=5432 \
  --from-literal=DB_POSTGRESDB_DATABASE=n8n \
  --from-literal=DB_POSTGRESDB_USER=n8n \
  --from-literal=DB_POSTGRESDB_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ n8n secrets"

# litellm secret
kubectl create secret generic litellm-secrets -n litellm \
  --from-literal=DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:5432/litellm" \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ litellm secrets"

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
echo "═══ 4. Déploiement litellm ═══"
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
echo "═══ 5. Déploiement qdrant ═══"
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
echo "═══ 6. Attente démarrage (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant)' | grep -v 'ingress\|admission'
echo ""

echo "DaemonSets :"
kubectl get daemonset -A
echo ""

echo "Services :"
kubectl get svc -A | grep -E '(n8n|litellm|qdrant)'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Applications déployées"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Ports :"
echo "  n8n     : 5678 (NodePort 30678)"
echo "  litellm : 4000 (NodePort 30400)"
echo "  qdrant  : 6333 (NodePort 30633)"
echo ""
echo "Prochaine étape :"
echo "  ./11_configure_ingress_routes.sh"
echo ""
