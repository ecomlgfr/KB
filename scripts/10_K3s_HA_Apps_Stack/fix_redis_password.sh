#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     Correction finale secrets Chatwoot & Superset (Redis pass)    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
MASTER_IP="10.0.0.100"

echo ""
echo "Problèmes identifiés :"
echo "  → Chatwoot : Redis NOAUTH (mot de passe manquant dans REDIS_URL)"
echo "  → Superset : Migrations OK mais container crash"
echo ""

read -p "Corriger les secrets ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══ Chargement des credentials ═══"
echo ""

if [ ! -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "$KO postgres.env introuvable"
    exit 1
fi

source "$CREDENTIALS_DIR/postgres.env"

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "$KO POSTGRES_PASSWORD non défini"
    exit 1
fi

# Vérifier si on a un mot de passe Redis
REDIS_PASSWORD=""
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
    REDIS_PASSWORD="${REDIS_PASSWORD:-}"
fi

# Si pas de password Redis dans les credentials, on va le chercher
if [ -z "$REDIS_PASSWORD" ]; then
    echo "Recherche du mot de passe Redis..."
    # Essayer de lire depuis le configmap Redis
    REDIS_PASSWORD=$(ssh root@10.0.0.130 "grep '^requirepass' /etc/redis/redis.conf 2>/dev/null | awk '{print \$2}'" || echo "")
    
    if [ -z "$REDIS_PASSWORD" ]; then
        echo ""
        echo -e "$WARN Mot de passe Redis introuvable"
        echo ""
        echo "Options :"
        echo "  1. Si Redis n'a PAS de mot de passe : on le désactive"
        echo "  2. Si Redis A un mot de passe : entrez-le manuellement"
        echo ""
        read -p "Redis a-t-il un mot de passe ? (yes/NO) : " has_pass
        
        if [ "$has_pass" = "yes" ]; then
            read -p "Entrez le mot de passe Redis : " REDIS_PASSWORD
        else
            echo "  → Redis sans authentification"
            REDIS_PASSWORD=""
        fi
    fi
fi

echo "  ✓ Postgres password : ${POSTGRES_PASSWORD:0:10}***"
if [ -n "$REDIS_PASSWORD" ]; then
    echo "  ✓ Redis password    : ${REDIS_PASSWORD:0:10}***"
else
    echo "  ✓ Redis password    : (aucun)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Recréation des secrets K8s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash -s "$POSTGRES_PASSWORD" "$REDIS_PASSWORD" <<'FIX_SECRETS'
set -u

POSTGRES_PASSWORD="$1"
REDIS_PASSWORD="$2"

echo "[$(date '+%F %T')] Suppression des anciens secrets..."
kubectl delete secret chatwoot-config -n chatwoot --ignore-not-found
kubectl delete secret superset-config -n superset --ignore-not-found
echo "  ✓ Secrets supprimés"

echo ""
echo "[$(date '+%F %T')] Création des nouveaux secrets..."

# Construire l'URL Redis
if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379"
else
    REDIS_URL="redis://10.0.0.10:6379"
fi

# Secret Chatwoot avec Redis password correct
kubectl create secret generic chatwoot-config -n chatwoot \
  --from-literal=POSTGRES_HOST=10.0.0.10 \
  --from-literal=POSTGRES_PORT=5432 \
  --from-literal=POSTGRES_DATABASE=chatwoot \
  --from-literal=POSTGRES_USERNAME=chatwoot \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  --from-literal=REDIS_URL="$REDIS_URL"

echo "  ✓ chatwoot-config créé (REDIS_URL corrigé)"

# Secret Superset
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
  --from-literal=REDIS_PORT=6379 \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD"

echo "  ✓ superset-config créé"

echo ""
echo "[$(date '+%F %T')] Redémarrage des déploiements..."

kubectl rollout restart deployment -n chatwoot
kubectl rollout restart deployment -n superset

echo "  ✓ Déploiements redémarrés"

FIX_SECRETS

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Attente du redémarrage (90 secondes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for i in {90..1}; do
    echo -ne "\rAttente... ${i}s restantes   "
    sleep 1
done
echo ""

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ État final ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@$MASTER_IP bash <<'CHECK'
echo "Pods des applications :"
echo ""

for ns in n8n chatwoot litellm superset qdrant; do
    echo "━━━ $ns ━━━"
    kubectl get pods -n $ns 2>/dev/null
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

RUNNING=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep "Running" | wc -l)
TOTAL=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep -v Completed | wc -l)

echo "Résumé : $RUNNING/$TOTAL pods Running"

if [ $RUNNING -ge 10 ]; then
    echo ""
    echo "🎉 SUCCÈS ! Toutes les applications fonctionnent"
else
    echo ""
    echo "⚠️  Certains pods ne sont pas encore Running"
    echo "   Vérifier les logs si échec persiste :"
    echo "   kubectl logs -n chatwoot -l app=chatwoot-web -c db-migrate --tail=50"
    echo "   kubectl logs -n superset -l app=superset --tail=50"
fi

CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Secrets corrigés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions effectuées :"
echo "  ✓ Secrets Chatwoot recréés (REDIS_URL avec password)"
echo "  ✓ Secrets Superset recréés"
echo "  ✓ Déploiements redémarrés"
echo ""
echo "Si toujours en erreur, vérifier :"
echo "  ssh root@10.0.0.100 kubectl logs -n chatwoot <pod> -c db-migrate"
echo "  ssh root@10.0.0.100 kubectl logs -n superset <pod>"
echo ""

exit 0
