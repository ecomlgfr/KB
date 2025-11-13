#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          Correction finale - Extensions PostgreSQL                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
MASTER_IP="10.0.0.100"

echo ""
echo "Problèmes identifiés :"
echo "  → Chatwoot : Extension pg_stat_statements manquante"
echo "  → Superset : Migrations OK mais pod crash au démarrage"
echo ""
echo "Solutions :"
echo "  1. Créer l'extension pg_stat_statements en tant que superuser"
echo "  2. Vérifier/corriger le déploiement Superset"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
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

echo "  ✓ Mot de passe PostgreSQL : ${POSTGRES_PASSWORD:0:10}***"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création des extensions PostgreSQL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

export PGPASSWORD="$POSTGRES_PASSWORD"

echo "[$(date '+%F %T')] Connexion à PostgreSQL via 10.0.0.10..."
echo ""

# Créer les extensions dans la base chatwoot
psql -h 10.0.0.10 -U postgres -d chatwoot <<SQL
-- Créer les extensions nécessaires pour Chatwoot
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Vérifier
\dx

-- Donner les permissions à l'utilisateur chatwoot
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO chatwoot;

SELECT 'Extensions créées avec succès pour Chatwoot' AS status;
SQL

if [ $? -eq 0 ]; then
    echo ""
    echo -e "$OK Extensions PostgreSQL créées pour Chatwoot"
else
    echo ""
    echo -e "$KO Erreur lors de la création des extensions"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Nettoyage et redémarrage des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash <<'CLEANUP'
set -u

echo "[$(date '+%F %T')] Suppression forcée des pods en erreur..."
echo ""

# Supprimer tous les pods Chatwoot en erreur
kubectl delete pods -n chatwoot --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
echo "  ✓ Pods Chatwoot supprimés"

# Supprimer tous les pods Superset en erreur
kubectl delete pods -n superset --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
echo "  ✓ Pods Superset supprimés"

echo ""
echo "[$(date '+%F %T')] Redémarrage des déploiements..."
echo ""

kubectl rollout restart deployment/chatwoot-web -n chatwoot
kubectl rollout restart deployment/chatwoot-worker -n chatwoot
echo "  ✓ Chatwoot redémarré"

kubectl rollout restart deployment/superset -n superset
echo "  ✓ Superset redémarré"

CLEANUP

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Attente du démarrage (90 secondes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for i in {90..1}; do
    echo -ne "\rAttente... ${i}s restantes   "
    sleep 1
done
echo ""

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Vérification finale ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@$MASTER_IP bash <<'CHECK'
echo "État des pods applications :"
echo ""

for ns in n8n chatwoot litellm superset qdrant; do
    echo "━━━ $ns ━━━"
    kubectl get pods -n $ns -o wide 2>/dev/null || echo "Namespace non trouvé"
    echo ""
done

echo "Résumé :"
RUNNING=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep Running | wc -l)
TOTAL=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | wc -l)
echo "  Pods Running : $RUNNING/$TOTAL"

CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Correction terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Si des pods sont toujours en erreur, vérifier les logs :"
echo "  kubectl logs -n chatwoot <pod> -c db-migrate"
echo "  kubectl logs -n superset <pod> -c init-db"
echo ""
echo "Prochaine étape :"
echo "  ./apps_final_tests.sh"
echo ""

exit 0
