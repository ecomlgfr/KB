#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   Migration Chatwoot + Fix litellm DATABASE_URL                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

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
    echo -e "$WARN redis.env introuvable (on continuera sans)"
fi

echo ""
echo "Mot de passe PostgreSQL : ${POSTGRES_PASSWORD:0:10}***"
echo "Mot de passe Redis : ${REDIS_PASSWORD:0:10}***"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 1/3 : Vérifier l'état de la base chatwoot ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -d chatwoot -c '\dt'" | head -20

echo ""
read -p "La base chatwoot est-elle vide ? (yes/NO) : " is_empty

if [ "$is_empty" = "yes" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "═══ ÉTAPE 2/3 : Exécuter les migrations Chatwoot ═══"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    # Créer un pod temporaire pour exécuter les migrations
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
    env:
    - name: RAILS_ENV
      value: "production"
    envFrom:
    - secretRef:
        name: chatwoot-secrets
EOF
    
    echo "Pod de migration créé, attente de l'exécution..."
    sleep 10
    
    # Suivre les logs
    kubectl logs -n chatwoot chatwoot-migrate -f 2>/dev/null || true
    
    echo ""
    echo "Vérifier le statut du pod de migration :"
    kubectl get pod -n chatwoot chatwoot-migrate
    
    echo ""
    read -p "Migration OK ? (yes/NO) : " migration_ok
    
    if [ "$migration_ok" = "yes" ]; then
        echo -e "$OK Migrations exécutées"
        kubectl delete pod -n chatwoot chatwoot-migrate 2>/dev/null || true
    else
        echo -e "$KO Migrations échouées"
        echo "Logs complets :"
        kubectl logs -n chatwoot chatwoot-migrate
        exit 1
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 3/3 : Corriger les secrets litellm ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# litellm doit utiliser PgBouncer (port 4632)
echo "Recréation du secret litellm avec port 4632..."

kubectl delete secret -n litellm litellm-secrets 2>/dev/null || true

kubectl create secret generic litellm-secrets \
  --namespace=litellm \
  --from-literal=DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:4632/litellm" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 16)"

echo -e "$OK Secret litellm recréé avec port 4632"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Redémarrage des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl rollout restart daemonset -n chatwoot chatwoot-web
kubectl rollout restart daemonset -n chatwoot chatwoot-worker
kubectl rollout restart daemonset -n litellm litellm

echo ""
echo "Attente 2 minutes..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ État final ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -A | grep -E '(n8n|chatwoot|litellm|qdrant)' | grep -v ingress

echo ""
RUNNING=$(kubectl get pods -A | grep -E '(n8n|chatwoot|litellm|qdrant)' | grep 'Running' | wc -l)
CRASH=$(kubectl get pods -A | grep -E '(n8n|chatwoot|litellm|qdrant)' | grep -E '(CrashLoopBackOff|Error)' | wc -l)

echo "  ✓ $RUNNING pods Running"
echo "  ✗ $CRASH pods CrashLoopBackOff/Error"

if [ $CRASH -eq 0 ]; then
    echo ""
    echo -e "$OK SUCCÈS TOTAL ! Toutes les apps fonctionnent !"
    echo ""
    echo "URLs :"
    echo "  • http://n8n.keybuzz.io"
    echo "  • http://llm.keybuzz.io"
    echo "  • http://qdrant.keybuzz.io"
    echo "  • http://chat.keybuzz.io"
else
    echo ""
    echo -e "$WARN Certains pods ont encore des problèmes"
    echo ""
    echo "Pour investiguer :"
    echo "  kubectl logs -n chatwoot <pod-name>"
    echo "  kubectl logs -n litellm <pod-name>"
fi

echo ""
