#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   Diagnostic et Fix LiteLLM                                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 1/4 : Logs des pods en erreur ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Pods LiteLLM actuellement en erreur :"
kubectl get pods -n litellm | grep -E '(Error|CrashLoopBackOff)' || echo "  Aucun pod en erreur"

echo ""
echo "→ Logs du premier pod en erreur :"
POD_ERROR=$(kubectl get pods -n litellm -o name | grep litellm | head -1 | cut -d'/' -f2)
if [ -n "$POD_ERROR" ]; then
    echo "  Pod: $POD_ERROR"
    echo ""
    kubectl logs -n litellm $POD_ERROR --tail=30
else
    echo "  Aucun pod trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 2/4 : Vérification de la base litellm ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -d litellm -c '\dt'" | head -20

echo ""
read -p "La base litellm a-t-elle des tables ? (yes/NO) : " has_tables

if [ "$has_tables" != "yes" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "═══ ÉTAPE 3/4 : Initialiser la base LiteLLM ═══"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    # LiteLLM n'a pas de migrations Rails, il initialise la DB au premier démarrage
    # Le problème est probablement la connexion ou les permissions
    
    echo "LiteLLM initialise sa base au démarrage..."
    echo "Vérifions les permissions PostgreSQL..."
    
    ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres" <<'SQL'
\c litellm
-- Vérifier le owner du schéma
SELECT 
    n.nspname AS schema,
    pg_catalog.pg_get_userbyid(n.nspowner) AS owner
FROM pg_namespace n
WHERE n.nspname = 'public';

-- Donner tous les droits à litellm
GRANT ALL ON SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO litellm;

SELECT 'Permissions litellm OK' AS status;
SQL

fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 4/4 : Vérifier et corriger la configuration ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Contenu du secret litellm-secrets :"
echo ""
echo "DATABASE_URL:"
kubectl get secret -n litellm litellm-secrets -o jsonpath='{.data.DATABASE_URL}' | base64 -d && echo
echo ""
echo "REDIS_URL:"
kubectl get secret -n litellm litellm-secrets -o jsonpath='{.data.REDIS_URL}' | base64 -d && echo
echo ""
echo "LITELLM_MASTER_KEY:"
kubectl get secret -n litellm litellm-secrets -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d && echo
echo ""

read -p "Les URLs semblent-elles correctes ? (yes/NO) : " urls_ok

if [ "$urls_ok" != "yes" ]; then
    CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
    
    if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
        source "$CREDENTIALS_DIR/postgres.env"
    fi
    
    if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
        source "$CREDENTIALS_DIR/redis.env"
    fi
    
    echo ""
    echo "Recréation du secret litellm avec les bonnes valeurs..."
    
    kubectl delete secret -n litellm litellm-secrets 2>/dev/null || true
    
    kubectl create secret generic litellm-secrets \
      --namespace=litellm \
      --from-literal=DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:4632/litellm" \
      --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379" \
      --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 16)" \
      --from-literal=LITELLM_DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@10.0.0.10:4632/litellm"
    
    echo -e "$OK Secret litellm recréé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Redémarrage LiteLLM ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl rollout restart daemonset -n litellm litellm

echo "Attente 2 minutes..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ État final ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -n litellm

RUNNING=$(kubectl get pods -n litellm | grep 'Running' | wc -l)
CRASH=$(kubectl get pods -n litellm | grep -E '(CrashLoopBackOff|Error)' | wc -l)

echo ""
echo "  ✓ $RUNNING pods Running"
echo "  ✗ $CRASH pods CrashLoopBackOff/Error"

if [ $CRASH -eq 0 ]; then
    echo ""
    echo -e "$OK LiteLLM corrigé !"
    echo ""
    echo "Test de l'API :"
    echo "  curl -I http://llm.keybuzz.io"
else
    echo ""
    echo -e "$WARN Certains pods ont encore des problèmes"
    echo ""
    echo "Logs du pod en erreur :"
    POD_ERROR=$(kubectl get pods -n litellm -o name | grep litellm | head -1 | cut -d'/' -f2)
    kubectl logs -n litellm $POD_ERROR --tail=50
fi

echo ""
