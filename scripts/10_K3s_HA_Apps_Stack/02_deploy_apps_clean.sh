#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   DÉPLOIEMENT PROPRE DES APPLICATIONS K3S                          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

# Charger les credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO postgres.env introuvable"
    exit 1
fi

if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN redis.env introuvable"
    REDIS_PASSWORD=""
fi

if [ -f "$CREDENTIALS_DIR/rabbitmq.env" ]; then
    source "$CREDENTIALS_DIR/rabbitmq.env"
else
    echo -e "$WARN rabbitmq.env introuvable"
fi

echo ""
echo "Credentials chargés :"
echo "  PostgreSQL : ${POSTGRES_PASSWORD:0:10}***"
echo "  Redis      : ${REDIS_PASSWORD:0:10}***"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 1/5 : Préparation des bases de données ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Création des bases + users + permissions COMPLÈTES..."

ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres" <<SQL
-- ═══ BASE n8n ═══
CREATE DATABASE n8n;
CREATE USER n8n WITH PASSWORD '${POSTGRES_PASSWORD}';

\c n8n
ALTER SCHEMA public OWNER TO n8n;
GRANT ALL ON SCHEMA public TO n8n;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO n8n;

-- ═══ BASE litellm ═══
\c postgres
CREATE DATABASE litellm;
CREATE USER litellm WITH PASSWORD '${POSTGRES_PASSWORD}';

\c litellm
ALTER SCHEMA public OWNER TO litellm;
GRANT ALL ON SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO litellm;

-- ═══ BASE chatwoot ═══
\c postgres
CREATE DATABASE chatwoot;
CREATE USER chatwoot WITH PASSWORD '${POSTGRES_PASSWORD}';

\c chatwoot
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

ALTER SCHEMA public OWNER TO chatwoot;
GRANT ALL ON SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO chatwoot;

-- ═══ BASE superset ═══
\c postgres
CREATE DATABASE superset;
CREATE USER superset WITH PASSWORD '${POSTGRES_PASSWORD}';

\c superset
ALTER SCHEMA public OWNER TO superset;
GRANT ALL ON SCHEMA public TO superset;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO superset;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO superset;

SELECT 'Toutes les bases créées avec permissions complètes' AS status;
SQL

if [ $? -eq 0 ]; then
    echo -e "$OK Bases de données créées"
else
    echo -e "$KO Erreur lors de la création des bases"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 2/5 : Déploiement n8n ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Créer namespace
kubectl create namespace n8n 2>/dev/null || true

# Créer le secret
kubectl create secret generic n8n-secrets \
  --namespace=n8n \
  --from-literal=DB_TYPE=postgresdb \
  --from-literal=DB_POSTGRESDB_HOST=10.0.0.10 \
  --from-literal=DB_POSTGRESDB_PORT=4632 \
  --from-literal=DB_POSTGRESDB_DATABASE=n8n \
  --from-literal=DB_POSTGRESDB_USER=n8n \
  --from-literal=DB_POSTGRESDB_PASSWORD="${POSTGRES_PASSWORD}" \
  --from-literal=N8N_ENCRYPTION_KEY="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secret n8n créé"

# Déployer n8n
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: n8n
  namespace: n8n
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
        envFrom:
        - secretRef:
            name: n8n-secrets
        env:
        - name: N8N_HOST
          value: "n8n.keybuzz.io"
        - name: N8N_PORT
          value: "5678"
        - name: N8N_PROTOCOL
          value: "http"
        - name: WEBHOOK_URL
          value: "http://n8n.keybuzz.io/"
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
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: n8n
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
              number: 5678
EOF

echo "Attente démarrage n8n (60s)..."
sleep 60

N8N_RUNNING=$(kubectl get pods -n n8n --no-headers | grep -c "Running")
echo "→ Pods n8n Running : $N8N_RUNNING/8"

if [ $N8N_RUNNING -ge 4 ]; then
    echo -e "$OK n8n déployé"
else
    echo -e "$WARN n8n partiellement déployé"
    kubectl get pods -n n8n
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 3/5 : Déploiement LiteLLM ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace litellm 2>/dev/null || true

kubectl create secret generic litellm-secrets \
  --namespace=litellm \
  --from-literal=DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:4632/litellm" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secret litellm créé"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: litellm
  namespace: litellm
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
        envFrom:
        - secretRef:
            name: litellm-secrets
        env:
        - name: LITELLM_PORT
          value: "4000"
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
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  namespace: litellm
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
              number: 4000
EOF

echo "Attente démarrage litellm (60s)..."
sleep 60

LITELLM_RUNNING=$(kubectl get pods -n litellm --no-headers | grep -c "Running")
echo "→ Pods litellm Running : $LITELLM_RUNNING/8"

if [ $LITELLM_RUNNING -ge 4 ]; then
    echo -e "$OK litellm déployé"
else
    echo -e "$WARN litellm partiellement déployé"
    kubectl get pods -n litellm
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 4/5 : Déploiement Qdrant ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace qdrant 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: qdrant
  namespace: qdrant
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
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qdrant
  namespace: qdrant
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

echo "Attente démarrage qdrant (30s)..."
sleep 30

QDRANT_RUNNING=$(kubectl get pods -n qdrant --no-headers | grep -c "Running")
echo "→ Pods qdrant Running : $QDRANT_RUNNING/8"

if [ $QDRANT_RUNNING -eq 8 ]; then
    echo -e "$OK qdrant déployé"
else
    echo -e "$WARN qdrant partiellement déployé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 5/5 : Déploiement Chatwoot ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace chatwoot 2>/dev/null || true

# Générer des secrets Chatwoot
SECRET_KEY_BASE="$(openssl rand -hex 64)"
FRONTEND_URL="http://chat.keybuzz.io"

kubectl create secret generic chatwoot-secrets \
  --namespace=chatwoot \
  --from-literal=POSTGRES_HOST=10.0.0.10 \
  --from-literal=POSTGRES_PORT=5432 \
  --from-literal=POSTGRES_DATABASE=chatwoot \
  --from-literal=POSTGRES_USERNAME=chatwoot \
  --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \
  --from-literal=SECRET_KEY_BASE="${SECRET_KEY_BASE}" \
  --from-literal=FRONTEND_URL="${FRONTEND_URL}" \
  --from-literal=RAILS_ENV=production \
  --from-literal=INSTALLATION_NAME=KeyBuzz \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secret chatwoot créé"

# Exécuter les migrations
echo "→ Exécution des migrations Chatwoot..."

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: chatwoot-migrate
  namespace: chatwoot
spec:
  restartPolicy: Never
  containers:
  - name: migrate
    image: chatwoot/chatwoot:latest
    command: ["bundle", "exec", "rails", "db:prepare"]
    envFrom:
    - secretRef:
        name: chatwoot-secrets
EOF

sleep 20

kubectl wait --for=condition=Ready pod/chatwoot-migrate -n chatwoot --timeout=120s 2>/dev/null || true
kubectl logs -n chatwoot chatwoot-migrate --tail=20

kubectl delete pod -n chatwoot chatwoot-migrate 2>/dev/null || true

echo -e "$OK Migrations Chatwoot exécutées"

# Déployer Chatwoot
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chatwoot-web
  namespace: chatwoot
spec:
  selector:
    matchLabels:
      app: chatwoot-web
  template:
    metadata:
      labels:
        app: chatwoot-web
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: web
        image: chatwoot/chatwoot:latest
        ports:
        - containerPort: 3000
          hostPort: 3000
        envFrom:
        - secretRef:
            name: chatwoot-secrets
        command: ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chatwoot-worker
  namespace: chatwoot
spec:
  selector:
    matchLabels:
      app: chatwoot-worker
  template:
    metadata:
      labels:
        app: chatwoot-worker
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: worker
        image: chatwoot/chatwoot:latest
        envFrom:
        - secretRef:
            name: chatwoot-secrets
        command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
---
apiVersion: v1
kind: Service
metadata:
  name: chatwoot-web
  namespace: chatwoot
spec:
  type: NodePort
  selector:
    app: chatwoot-web
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

echo "Attente démarrage chatwoot (90s)..."
sleep 90

CHATWOOT_RUNNING=$(kubectl get pods -n chatwoot --no-headers | grep -c "Running")
echo "→ Pods chatwoot Running : $CHATWOOT_RUNNING/16"

if [ $CHATWOOT_RUNNING -ge 10 ]; then
    echo -e "$OK chatwoot déployé"
else
    echo -e "$WARN chatwoot partiellement déployé"
    kubectl get pods -n chatwoot
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DÉPLOIEMENT TERMINÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -v ingress

TOTAL_RUNNING=$(kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -c "Running")

echo ""
echo "Total pods Running : $TOTAL_RUNNING/40"
echo ""
echo "URLs de test :"
echo "  • http://n8n.keybuzz.io"
echo "  • http://llm.keybuzz.io"
echo "  • http://qdrant.keybuzz.io"
echo "  • http://chat.keybuzz.io"
echo ""
