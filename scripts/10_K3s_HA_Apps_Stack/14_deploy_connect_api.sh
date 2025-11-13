#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Connect API Gateway                          ║"
echo "║    (FastAPI + Uvicorn avec HPA et PDB)                            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

echo ""
echo "Ce script déploie :"
echo "  1. Connect API Gateway (FastAPI)"
echo "  2. Image : ghcr.io/keybuzz/connect:1.0.0"
echo "  3. HPA : 1→5 pods (CPU 60%)"
echo "  4. PDB : minAvailable=2"
echo "  5. Ingress : connect.keybuzz.io"
echo "  6. QoS Guaranteed"
echo ""

read -p "Déployer Connect API ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Charger credentials PostgreSQL
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO PostgreSQL credentials manquants"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création namespace connect ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace connect 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création Secret pour DB ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create secret generic connect-db-secret -n connect \
  --from-literal=DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@10.0.0.10:6432/keybuzz_connect" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secret créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Vérification de l'image ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "⚠️  Image ghcr.io/keybuzz/connect:1.0.0"
echo ""
echo "Si l'image n'existe pas, le pod restera en ImagePullBackOff."
echo "Créer un Dockerfile minimal FastAPI :"
echo ""
cat > /tmp/Dockerfile.connect <<'DOCKERFILE'
FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn[standard] asyncpg redis

COPY . /app

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
DOCKERFILE

cat > /tmp/main.py <<'PYTHON'
from fastapi import FastAPI
import os

app = FastAPI(title="KeyBuzz Connect API", version="1.0.0")

@app.get("/")
async def root():
    return {"message": "KeyBuzz Connect API", "version": "1.0.0"}

@app.get("/health")
async def health():
    return {"status": "healthy"}

@app.get("/api/v1/info")
async def info():
    return {
        "service": "connect-api",
        "version": "1.0.0",
        "database": os.getenv("DATABASE_URL", "not configured")
    }
PYTHON

echo "Fichiers créés dans /tmp/ :"
echo "  - /tmp/Dockerfile.connect"
echo "  - /tmp/main.py"
echo ""
echo "Pour builder et push l'image :"
echo "  cd /tmp"
echo "  docker build -f Dockerfile.connect -t ghcr.io/keybuzz/connect:1.0.0 ."
echo "  docker push ghcr.io/keybuzz/connect:1.0.0"
echo ""

read -p "Continuer le déploiement ? (yes/NO) : " confirm2
[ "$confirm2" != "yes" ] && { echo "Annulé - buildez l'image d'abord"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Déploiement Connect API ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/connect

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connect-api
  namespace: connect
  labels:
    app: connect-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: connect-api
  template:
    metadata:
      labels:
        app: connect-api
    spec:
      nodeSelector:
        role: apps
      containers:
      - name: connect-api
        image: ghcr.io/keybuzz/connect:1.0.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: connect-db-secret
              key: DATABASE_URL
        - name: REDIS_URL
          value: "redis://:$(REDIS_PASSWORD)@10.0.0.10:6379/0"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        resources:
          requests:
            cpu: "200m"
            memory: "512Mi"
          limits:
            cpu: "200m"      # QoS Guaranteed (requests = limits)
            memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: connect-api
  namespace: connect
spec:
  selector:
    app: connect-api
  ports:
  - port: 8080
    targetPort: 8080
    name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: connect-ingress
  namespace: connect
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - host: connect.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: connect-api
            port:
              number: 8080
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: connect-api-hpa
  namespace: connect
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: connect-api
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: connect-api-pdb
  namespace: connect
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: connect-api
EOF

echo -e "$OK Connect API déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Attente démarrage ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente des pods (60s)..."
sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods connect :"
kubectl get pods -n connect -o wide
echo ""

echo "Services :"
kubectl get svc -n connect
echo ""

echo "Ingress :"
kubectl get ingress -n connect
echo ""

echo "HPA :"
kubectl get hpa -n connect
echo ""

echo "PDB :"
kubectl get pdb -n connect
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Connect API déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 Accès Connect API :"
echo "  URL : http://connect.keybuzz.io"
echo "  Health : http://connect.keybuzz.io/health"
echo "  Info : http://connect.keybuzz.io/api/v1/info"
echo ""
echo "⚙️ Configuration :"
echo "  Replicas : 3 (min 1, max 5)"
echo "  HPA : CPU > 60% → scale up"
echo "  PDB : minAvailable = 2"
echo "  QoS : Guaranteed (requests = limits)"
echo "  NodeSelector : role=apps"
echo ""
echo "🔍 Test :"
echo "  curl -I http://connect.keybuzz.io/health"
echo ""
echo "Prochaine étape :"
echo "  ./15_deploy_dolibarr.sh"
echo ""

exit 0
