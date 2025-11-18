#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v3_01_connect_api_image.sh
# Description: Fix Connect API image pull issue - V3 (corrigé)
# Date: 2025-11-18
###############################################################################

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX V3 - Connect API Image Pull Issue (CORRIGÉ)                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier que le namespace existe
kubectl create namespace connect 2>/dev/null || true

# Créer le secret si manquant
echo "🔑 Vérification/création du secret Connect..."
if ! kubectl get secret connect-secrets -n connect &>/dev/null; then
    echo "Création du secret connect-secrets..."
    POSTGRES_PASSWORD=$(kubectl get secret -n postgres postgres-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || echo "ChangeMe123!")

    kubectl create secret generic connect-secrets -n connect \
      --from-literal=DATABASE_USER=postgres \
      --from-literal=DATABASE_PASSWORD="$POSTGRES_PASSWORD"
    echo "✅ Secret créé"
else
    echo "✅ Secret existe déjà"
fi

# Créer la base de données Connect si elle n'existe pas
echo ""
echo "🔍 Vérification de la base de données..."
POSTGRES_PASSWORD=$(kubectl get secret -n postgres postgres-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || echo "ChangeMe123!")

if ! PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 6432 -U postgres -d connect -c "SELECT 1" &>/dev/null; then
    echo "Création de la base de données connect..."
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U postgres -d postgres <<EOF
CREATE DATABASE connect WITH OWNER = postgres;
GRANT ALL PRIVILEGES ON DATABASE connect TO postgres;
EOF
    echo "✅ Base de données créée"
else
    echo "✅ Base de données existe déjà"
fi

# Supprimer le déploiement actuel
echo ""
echo "🗑️  Suppression du déploiement actuel..."
kubectl delete deployment connect-api -n connect --ignore-not-found
kubectl delete pod -n connect -l app=connect-api --force --grace-period=0 2>/dev/null || true

sleep 5

# Reconstruire l'image avec un nom SANS préfixe docker.io
echo ""
echo "🔨 Reconstruction de l'image (tag local sans registry)..."
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
DB_USER = os.getenv("DATABASE_USER", "postgres")
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

# Build avec tag LOCAL (pas de registry)
echo "Building Docker image..."
docker build -t connect-api:local -f /tmp/Dockerfile.connect /tmp/

# Sauvegarder et importer sur TOUS les workers
echo ""
echo "📥 Import sur tous les workers K3s..."
docker save connect-api:local -o /tmp/connect-api.tar

for worker in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    echo "  → Worker $worker..."
    scp -o StrictHostKeyChecking=no /tmp/connect-api.tar root@$worker:/tmp/ 2>/dev/null
    ssh -o StrictHostKeyChecking=no root@$worker "ctr -n k8s.io images import /tmp/connect-api.tar && rm /tmp/connect-api.tar" 2>/dev/null
done

# Vérifier l'import sur le premier worker
echo ""
echo "🔍 Vérification de l'image sur worker 10.0.0.110..."
ssh -o StrictHostKeyChecking=no root@10.0.0.110 "ctr -n k8s.io images ls | grep connect-api" || echo "⚠️  Image non trouvée!"

# Nettoyer
rm -f /tmp/connect-api.tar /tmp/Dockerfile.connect /tmp/app.py

# Déployer avec le bon tag d'image
echo ""
echo "🚀 Déploiement de Connect API..."

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
        image: docker.io/library/connect-api:local
        imagePullPolicy: IfNotPresent
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
echo "⏳ Attente du démarrage (90s)..."
sleep 90

# Vérifier
echo ""
echo "✅ Vérification..."
kubectl get pods -n connect
echo ""
kubectl get svc -n connect
echo ""
kubectl get ingress -n connect

echo ""
echo "📋 Logs récents..."
POD_NAME=$(kubectl get pods -n connect -l app=connect-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$POD_NAME" ]; then
    kubectl logs -n connect "$POD_NAME" --tail=30 || true
    echo ""
    kubectl describe pod -n connect "$POD_NAME" | grep -A 5 "Events:" || true
fi

echo ""
echo "🧪 Test HTTP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://connect.keybuzz.io/health --max-time 10 || echo "TIMEOUT")

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Connect API opérationnel (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "503" ]; then
    echo "⏳ Connect API démarré mais backend non prêt (HTTP 503)"
else
    echo "⚠️  HTTP $HTTP_CODE"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "✅ FIX V3 TERMINÉ"
echo ""
echo "📱 URL: http://connect.keybuzz.io"
echo "🔍 Health: http://connect.keybuzz.io/health"
echo ""
echo "Si erreur persiste:"
echo "  ssh root@10.0.0.110 'ctr -n k8s.io images ls | grep connect'"
echo "  kubectl logs -n connect -l app=connect-api --tail=100"
echo "  kubectl describe pod -n connect -l app=connect-api"
echo "════════════════════════════════════════════════════════════════════"
