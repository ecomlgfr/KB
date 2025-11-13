#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          Recréation des secrets Kubernetes avec bonnes valeurs    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
MASTER_IP="10.0.0.100"

echo ""
echo "═══ Chargement des credentials ═══"
echo ""

# Charger postgres.env
if [ ! -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "$KO $CREDENTIALS_DIR/postgres.env introuvable"
    exit 1
fi

source "$CREDENTIALS_DIR/postgres.env"

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "$KO POSTGRES_PASSWORD non défini"
    exit 1
fi

echo "  ✓ Mot de passe PostgreSQL : ${POSTGRES_PASSWORD:0:10}***"
echo ""

echo "═══ Configuration ═══"
echo "  PostgreSQL LB   : 10.0.0.10:5432"
echo "  User postgres   : postgres"
echo "  Password        : ${POSTGRES_PASSWORD:0:10}***"
echo ""
echo "Applications à reconfigurer :"
echo "  1. n8n"
echo "  2. chatwoot"
echo "  3. litellm"
echo "  4. superset"
echo ""

read -p "Recréer les secrets K8s ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Recréation des secrets Kubernetes ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash -s "$POSTGRES_PASSWORD" <<'RECREATE_SECRETS'
set -u
set -o pipefail

POSTGRES_PASSWORD="$1"

echo "[$(date '+%F %T')] Suppression des anciens secrets..."
echo ""

kubectl delete secret n8n-config -n n8n --ignore-not-found
echo "  ✓ n8n-config supprimé"

kubectl delete secret chatwoot-config -n chatwoot --ignore-not-found
echo "  ✓ chatwoot-config supprimé"

kubectl delete secret litellm-config -n litellm --ignore-not-found
echo "  ✓ litellm-config supprimé"

kubectl delete secret superset-config -n superset --ignore-not-found
echo "  ✓ superset-config supprimé"

echo ""
echo "[$(date '+%F %T')] Recréation des secrets avec bonnes valeurs..."
echo ""

# Secret n8n
kubectl create secret generic n8n-config -n n8n \
  --from-literal=DB_TYPE=postgresdb \
  --from-literal=DB_POSTGRESDB_HOST=10.0.0.10 \
  --from-literal=DB_POSTGRESDB_PORT=5432 \
  --from-literal=DB_POSTGRESDB_DATABASE=n8n \
  --from-literal=DB_POSTGRESDB_USER=n8n \
  --from-literal=DB_POSTGRESDB_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=N8N_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --from-literal=N8N_USER_MANAGEMENT_JWT_SECRET="$(openssl rand -base64 32)"

echo "  ✓ n8n-config créé"

# Secret chatwoot
kubectl create secret generic chatwoot-config -n chatwoot \
  --from-literal=POSTGRES_HOST=10.0.0.10 \
  --from-literal=POSTGRES_PORT=5432 \
  --from-literal=POSTGRES_DATABASE=chatwoot \
  --from-literal=POSTGRES_USERNAME=chatwoot \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  --from-literal=REDIS_URL=redis://10.0.0.10:6379

echo "  ✓ chatwoot-config créé"

# Secret litellm
kubectl create secret generic litellm-config -n litellm \
  --from-literal=DATABASE_URL="postgresql://litellm:$POSTGRES_PASSWORD@10.0.0.10:5432/litellm" \
  --from-literal=REDIS_HOST=10.0.0.10 \
  --from-literal=REDIS_PORT=6379

echo "  ✓ litellm-config créé"

# Secret superset
SUPERSET_SECRET_KEY="$(openssl rand -base64 42)"

kubectl create secret generic superset-config -n superset \
  --from-literal=DATABASE_HOST=10.0.0.10 \
  --from-literal=DATABASE_PORT=5432 \
  --from-literal=DATABASE_DB=superset \
  --from-literal=DATABASE_USER=superset \
  --from-literal=DATABASE_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=SUPERSET_SECRET_KEY="$SUPERSET_SECRET_KEY" \
  --from-literal=SECRET_KEY="$SUPERSET_SECRET_KEY" \
  --from-literal=REDIS_HOST=10.0.0.10 \
  --from-literal=REDIS_PORT=6379

echo "  ✓ superset-config créé"

echo ""
echo "[$(date '+%F %T')] Vérification des secrets créés..."
echo ""

for ns in n8n chatwoot litellm superset; do
    SECRET_NAME="${ns}-config"
    if kubectl get secret $SECRET_NAME -n $ns >/dev/null 2>&1; then
        echo "  ✓ $ns : secret présent"
    else
        echo "  ✗ $ns : secret manquant"
    fi
done

echo ""
echo "[$(date '+%F %T')] Redémarrage des déploiements..."
echo ""

kubectl rollout restart deployment/n8n -n n8n
echo "  ✓ n8n redémarré"

kubectl rollout restart deployment/chatwoot-web -n chatwoot
kubectl rollout restart deployment/chatwoot-worker -n chatwoot
echo "  ✓ chatwoot redémarré"

kubectl rollout restart deployment/litellm -n litellm
echo "  ✓ litellm redémarré"

kubectl rollout restart deployment/superset -n superset
echo "  ✓ superset redémarré"

echo ""
echo "[$(date '+%F %T')] Attente du redémarrage des pods (30s)..."
sleep 30

echo ""
echo "[$(date '+%F %T')] État des pods après redémarrage..."
echo ""

for ns in n8n chatwoot litellm superset; do
    echo "━━━ $ns ━━━"
    kubectl get pods -n $ns -o wide
    echo ""
done

RECREATE_SECRETS

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Secrets recréés et déploiements redémarrés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions effectuées :"
echo "  ✓ Anciens secrets supprimés"
echo "  ✓ Nouveaux secrets créés avec le bon mot de passe"
echo "  ✓ Déploiements redémarrés"
echo ""
echo "Prochaines étapes :"
echo "  1. Attendre 2-3 minutes pour que les pods démarrent"
echo "  2. Vérifier l'état : ssh root@10.0.0.100 kubectl get pods -A"
echo "  3. Si OK, lancer : ./apps_final_tests.sh"
echo ""
echo "Si toujours en erreur, vérifier les logs :"
echo "  kubectl logs -n n8n -l app=n8n --tail=50"
echo "  kubectl logs -n chatwoot <pod-name> -c db-migrate"
echo ""

exit 0
