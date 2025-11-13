#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      RESET COMPLET Chatwoot & Superset (bases + déploiements)     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
MASTER_IP="10.0.0.100"

echo ""
echo -e "$WARN ATTENTION : Cette opération va :"
echo "  1. Supprimer COMPLÈTEMENT les bases 'chatwoot' et 'superset'"
echo "  2. Les recréer vides avec toutes les extensions"
echo "  3. Supprimer tous les pods Chatwoot et Superset"
echo "  4. Redémarrer les déploiements (migrations repartiront de zéro)"
echo ""
echo "Toutes les données Chatwoot et Superset seront PERDUES."
echo ""

read -p "Êtes-vous SÛR de vouloir continuer ? (tapez 'RESET' pour confirmer) : " confirm
[ "$confirm" != "RESET" ] && { echo "Annulé"; exit 0; }

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
echo "═══ 1. Suppression des bases PostgreSQL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

export PGPASSWORD="$POSTGRES_PASSWORD"

echo "[$(date '+%F %T')] Suppression des bases chatwoot et superset..."
echo ""

psql -h 10.0.0.10 -U postgres <<'SQL'
-- Terminer toutes les connexions actives
SELECT pg_terminate_backend(pg_stat_activity.pid)
FROM pg_stat_activity
WHERE pg_stat_activity.datname IN ('chatwoot', 'superset')
  AND pid <> pg_backend_pid();

-- Supprimer les bases
DROP DATABASE IF EXISTS chatwoot;
DROP DATABASE IF EXISTS superset;

-- Confirmer
SELECT 'Bases supprimées avec succès' AS status;
SQL

if [ $? -ne 0 ]; then
    echo -e "$KO Erreur lors de la suppression des bases"
    exit 1
fi

echo -e "$OK Bases chatwoot et superset supprimées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Recréation des bases avec TOUTES les extensions ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "[$(date '+%F %T')] Création des bases..."
echo ""

psql -h 10.0.0.10 -U postgres <<SQL
-- Créer les bases
CREATE DATABASE chatwoot OWNER chatwoot;
CREATE DATABASE superset OWNER superset;

-- Chatwoot : Créer toutes les extensions nécessaires
\c chatwoot

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS plpgsql;

-- Donner tous les droits
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
GRANT ALL PRIVILEGES ON SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO chatwoot;

-- Superset : Base simple
\c superset

GRANT ALL PRIVILEGES ON DATABASE superset TO superset;
GRANT ALL PRIVILEGES ON SCHEMA public TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO superset;

-- Vérifier
\c postgres
SELECT 'Bases recréées avec toutes les extensions' AS status;

\c chatwoot
\dx
SQL

if [ $? -eq 0 ]; then
    echo ""
    echo -e "$OK Bases recréées avec succès"
else
    echo ""
    echo -e "$KO Erreur lors de la création des bases"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Suppression complète des déploiements K8s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash <<'CLEANUP'
set -u

echo "[$(date '+%F %T')] Suppression des déploiements Chatwoot..."
kubectl delete deployment chatwoot-web chatwoot-worker -n chatwoot --force --grace-period=0
echo "  ✓ Déploiements supprimés"

echo ""
echo "[$(date '+%F %T')] Suppression des déploiements Superset..."
kubectl delete deployment superset -n superset --force --grace-period=0
echo "  ✓ Déploiements supprimés"

echo ""
echo "[$(date '+%F %T')] Suppression de tous les pods..."
kubectl delete pods --all -n chatwoot --force --grace-period=0 2>/dev/null || true
kubectl delete pods --all -n superset --force --grace-period=0 2>/dev/null || true
echo "  ✓ Pods supprimés"

echo ""
echo "[$(date '+%F %T')] Attente que tout soit supprimé (15s)..."
sleep 15

CLEANUP

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Recréation des déploiements depuis zéro ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pour recréer les déploiements, vous devez réexécuter :"
echo "  ./fix_apps_deployment.sh"
echo ""
echo "Ou les créer manuellement via kubectl apply -f <manifests>"
echo ""

read -p "Voulez-vous que je les recrée automatiquement ? (yes/NO) : " recreate
if [ "$recreate" = "yes" ]; then
    echo ""
    echo "Recréation automatique des déploiements..."
    echo ""
    echo -e "$WARN Non implémenté pour l'instant"
    echo "Lancez : ./fix_apps_deployment.sh"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK RESET COMPLET TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions effectuées :"
echo "  ✓ Bases chatwoot et superset supprimées"
echo "  ✓ Bases recréées VIDES avec toutes les extensions"
echo "  ✓ Déploiements K8s supprimés"
echo ""
echo "Prochaines étapes :"
echo "  1. Relancer : ./fix_apps_deployment.sh"
echo "  2. Attendre 5 minutes que les migrations s'exécutent"
echo "  3. Vérifier : ssh root@10.0.0.100 kubectl get pods -A"
echo ""

exit 0
