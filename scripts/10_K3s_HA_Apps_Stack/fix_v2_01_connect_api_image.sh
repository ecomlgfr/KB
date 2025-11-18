#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v2_01_connect_api_image.sh
# Description: Fix Connect API image pull issue (ErrImageNeverPull) - V2
# Date: 2025-11-18
###############################################################################

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX V2 - Connect API Image Pull Issue                          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Supprimer le déploiement actuel
echo "🗑️  Suppression du déploiement actuel..."
kubectl delete deployment connect-api -n connect --ignore-not-found
kubectl delete pod -n connect -l app=connect-api --force --grace-period=0 2>/dev/null || true

# Reconstruire l'image avec un tag explicite
echo ""
echo "🔨 Reconstruction de l'image avec tag explicite..."
cat > /tmp/Dockerfile.connect <<'DOCKERFILE'
FROM python:3.11-slim

WORKDIR /app

# Dépendances système
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Dépendances Python
RUN pip install --no-cache-dir \
    fastapi==0.104.1 \
    uvicorn[standard]==0.24.0 \
    psycopg2-binary==2.9.9 \
    redis==5.0.1 \
    pydantic==2.5.0 \
    python-multipart==0.0.6

# Application
COPY app.py .

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

EXPOSE 3000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "3000"]
DOCKERFILE

cat > /tmp/app.py <<'PYCODE'
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import os
import psycopg2
import redis
from datetime import datetime

app = FastAPI(title="KeyBuzz Connect API Gateway", version="1.0.0")

# Configuration
DB_HOST = os.getenv("DATABASE_HOST", "10.0.0.10")
DB_PORT = int(os.getenv("DATABASE_PORT", "6432"))
DB_NAME = os.getenv("DATABASE_NAME", "connect")
DB_USER = os.getenv("DATABASE_USER", "connect")
DB_PASS = os.getenv("DATABASE_PASSWORD", "")

REDIS_HOST = os.getenv("REDIS_HOST", "10.0.0.10")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

@app.get("/")
async def root():
    return {
        "service": "KeyBuzz Connect API Gateway",
        "version": "1.0.0",
        "status": "running",
        "timestamp": datetime.utcnow().isoformat()
    }

@app.get("/health")
async def health_check():
    health_status = {
        "api": "ok",
        "database": "unknown",
        "cache": "unknown",
        "timestamp": datetime.utcnow().isoformat()
    }

    # Test PostgreSQL
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASS,
            connect_timeout=3
        )
        conn.close()
        health_status["database"] = "ok"
    except Exception as e:
        health_status["database"] = f"error: {str(e)}"

    # Test Redis
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, socket_connect_timeout=3)
        r.ping()
        health_status["cache"] = "ok"
    except Exception as e:
        health_status["cache"] = f"error: {str(e)}"

    # Status global
    all_ok = all(v == "ok" for k, v in health_status.items() if k != "timestamp")

    if all_ok:
        return JSONResponse(content=health_status, status_code=200)
    else:
        return JSONResponse(content=health_status, status_code=503)

@app.get("/api/v1/info")
async def api_info():
    return {
        "api_version": "1.0.0",
        "endpoints": [
            {"path": "/", "method": "GET", "description": "API info"},
            {"path": "/health", "method": "GET", "description": "Health check"},
            {"path": "/api/v1/info", "method": "GET", "description": "API endpoints info"}
        ]
    }
PYCODE

# Build image
echo "Building Docker image..."
docker build -t keybuzz/connect:1.0.0 -f /tmp/Dockerfile.connect /tmp/

# Import dans K3s avec crictl (plus fiable que ctr)
echo ""
echo "📥 Import de l'image dans K3s..."

# Sauvegarder l'image en tar
docker save keybuzz/connect:1.0.0 -o /tmp/connect-api.tar

# Importer sur CHAQUE worker (important car Deployment peut aller sur n'importe quel worker)
for worker in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    echo "  → Worker $worker..."
    scp -o StrictHostKeyChecking=no /tmp/connect-api.tar root@$worker:/tmp/
    ssh -o StrictHostKeyChecking=no root@$worker "ctr -n k8s.io images import /tmp/connect-api.tar && rm /tmp/connect-api.tar"
done

# Nettoyer
rm /tmp/connect-api.tar /tmp/Dockerfile.connect /tmp/app.py

# Redéployer avec imagePullPolicy: IfNotPresent
echo ""
echo "🚀 Redéploiement de Connect API..."

kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connect-api
  namespace: connect
spec:
  replicas: 2
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
        image: keybuzz/connect:1.0.0
        imagePullPolicy: IfNotPresent  # ← Changé de Never à IfNotPresent
        ports:
        - containerPort: 3000
          name: http
          protocol: TCP
        env:
        - name: DATABASE_HOST
          value: "10.0.0.10"
        - name: DATABASE_PORT
          value: "6432"
        - name: DATABASE_NAME
          value: "connect"
        - name: DATABASE_USER
          valueFrom:
            secretKeyRef:
              name: connect-secrets
              key: DATABASE_USER
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: connect-secrets
              key: DATABASE_PASSWORD
        - name: REDIS_HOST
          value: "10.0.0.10"
        - name: REDIS_PORT
          value: "6379"
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 15
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
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
  - port: 80
    targetPort: 3000
    protocol: TCP
    name: http
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: connect-ingress
  namespace: connect
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
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
              number: 80
YAML

# Attendre le démarrage
echo ""
echo "⏳ Attente du démarrage des pods (60s)..."
sleep 60

# Vérifier
echo ""
echo "✅ Vérification..."
kubectl get pods -n connect
kubectl get svc -n connect
kubectl get ingress -n connect

echo ""
echo "🧪 Test HTTP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://connect.keybuzz.io/health --max-time 10 || echo "TIMEOUT")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "503" ]; then
    echo "✅ Connect API accessible (HTTP $HTTP_CODE)"
else
    echo "⚠️  HTTP $HTTP_CODE (attendu: 200 ou 503)"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ FIX TERMINÉ"
echo ""
echo "📱 URL: http://connect.keybuzz.io"
echo "🔍 Endpoints:"
echo "   - GET /           → Info API"
echo "   - GET /health     → Health check"
echo "   - GET /api/v1/info → Liste endpoints"
echo ""
echo "Si toujours en erreur, vérifier les logs :"
echo "  kubectl logs -n connect -l app=connect-api --tail=50"
echo "════════════════════════════════════════════════════════════════════"
