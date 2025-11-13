#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX Connect API - Build Image Locale                           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

echo ""
echo "Ce script va :"
echo "  1. Créer une image FastAPI minimale"
echo "  2. La charger dans K3s (sans registry externe)"
echo "  3. Redéployer Connect API"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Créer un répertoire de build
BUILD_DIR="/tmp/connect-api-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création Dockerfile ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > Dockerfile <<'DOCKERFILE'
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
RUN pip install --no-cache-dir \
    fastapi==0.104.1 \
    uvicorn[standard]==0.24.0 \
    asyncpg==0.29.0 \
    redis==5.0.1

# Copy app
COPY main.py /app/

# Expose port
EXPOSE 8080

# Run
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
DOCKERFILE

echo -e "$OK Dockerfile créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création application FastAPI ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > main.py <<'PYTHON'
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import os
import asyncio
import asyncpg
import redis.asyncio as redis

app = FastAPI(
    title="KeyBuzz Connect API",
    version="1.0.0",
    description="API Gateway pour KeyBuzz"
)

# Health check
@app.get("/health")
async def health():
    """Health check endpoint"""
    return {"status": "healthy", "service": "connect-api", "version": "1.0.0"}

# Root
@app.get("/")
async def root():
    """Root endpoint"""
    return {
        "message": "KeyBuzz Connect API",
        "version": "1.0.0",
        "endpoints": {
            "health": "/health",
            "info": "/api/v1/info",
            "db_test": "/api/v1/test/db",
            "redis_test": "/api/v1/test/redis"
        }
    }

# Info
@app.get("/api/v1/info")
async def info():
    """Get API info"""
    db_url = os.getenv("DATABASE_URL", "not configured")
    redis_url = os.getenv("REDIS_URL", "not configured")
    
    # Mask passwords
    if "://" in db_url:
        parts = db_url.split("@")
        if len(parts) == 2:
            db_url = f"{parts[0].split(':')[0]}:***@{parts[1]}"
    
    return {
        "service": "connect-api",
        "version": "1.0.0",
        "database": db_url,
        "redis": redis_url if redis_url == "not configured" else "configured",
        "environment": os.getenv("ENVIRONMENT", "production")
    }

# Test DB
@app.get("/api/v1/test/db")
async def test_db():
    """Test database connection"""
    db_url = os.getenv("DATABASE_URL")
    if not db_url:
        raise HTTPException(status_code=500, detail="DATABASE_URL not configured")
    
    try:
        conn = await asyncpg.connect(db_url)
        version = await conn.fetchval("SELECT version();")
        await conn.close()
        return {
            "status": "ok",
            "message": "Database connection successful",
            "postgres_version": version.split(",")[0]
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database connection failed: {str(e)}")

# Test Redis
@app.get("/api/v1/test/redis")
async def test_redis():
    """Test Redis connection"""
    redis_url = os.getenv("REDIS_URL")
    if not redis_url:
        raise HTTPException(status_code=500, detail="REDIS_URL not configured")
    
    try:
        r = await redis.from_url(redis_url, encoding="utf-8", decode_responses=True)
        await r.ping()
        await r.close()
        return {
            "status": "ok",
            "message": "Redis connection successful"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Redis connection failed: {str(e)}")

# Readiness probe
@app.get("/ready")
async def readiness():
    """Readiness probe"""
    return {"status": "ready"}

# Liveness probe
@app.get("/live")
async def liveness():
    """Liveness probe"""
    return {"status": "live"}
PYTHON

echo -e "$OK Application FastAPI créée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Build de l'image Docker ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

docker build -t keybuzz-connect:1.0.0 .

if [ $? -eq 0 ]; then
    echo -e "$OK Image Docker créée"
else
    echo -e "$KO Échec du build Docker"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Import dans K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Sauvegarder l'image
docker save keybuzz-connect:1.0.0 -o connect-api.tar

# Importer dans K3s sur tous les workers
echo "Import de l'image sur les workers K3s..."

for node in k3s-worker-01 k3s-worker-02 k3s-worker-03; do
    echo "  - Import sur $node..."
    scp -o StrictHostKeyChecking=no connect-api.tar root@$node:/tmp/
    ssh root@$node "ctr -n k8s.io images import /tmp/connect-api.tar && rm /tmp/connect-api.tar"
done

echo -e "$OK Image importée dans K3s"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Mise à jour du deployment ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Supprimer l'ancien deployment
kubectl delete deployment connect-api -n connect

# Créer le nouveau deployment avec l'image locale
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connect-api
  namespace: connect
  labels:
    app: connect-api
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
        image: keybuzz-connect:1.0.0
        imagePullPolicy: Never
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
          value: "redis://10.0.0.10:6379/0"
        - name: ENVIRONMENT
          value: "production"
        livenessProbe:
          httpGet:
            path: /live
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
EOF

echo -e "$OK Deployment mis à jour"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Attente démarrage ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente des pods (30s)..."
sleep 30

echo ""
kubectl get pods -n connect -o wide

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Connect API corrigé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🔍 Tests :"
echo "  curl http://connect.keybuzz.io/health"
echo "  curl http://connect.keybuzz.io/api/v1/info"
echo ""

exit 0
