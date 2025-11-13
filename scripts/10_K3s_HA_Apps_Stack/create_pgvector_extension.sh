#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           Création extension pgvector pour Chatwoot               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
MASTER_IP="10.0.0.100"

echo ""
echo "Problème identifié :"
echo "  → Chatwoot : Extension 'vector' (pgvector) manquante"
echo "  → Superset : Init containers en cours (migrations OK)"
echo ""

read -p "Créer l'extension pgvector ? (yes/NO) : " confirm
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

echo "  ✓ Mot de passe PostgreSQL chargé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Création de l'extension pgvector ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

export PGPASSWORD="$POSTGRES_PASSWORD"

echo "[$(date '+%F %T')] Connexion à PostgreSQL via 10.0.0.10..."
echo ""

# Créer l'extension vector dans la base chatwoot
psql -h 10.0.0.10 -U postgres -d chatwoot <<'SQL'
-- Créer l'extension pgvector
CREATE EXTENSION IF NOT EXISTS vector;

-- Vérifier les extensions installées
\dx

-- Confirmer
SELECT 'Extension vector créée avec succès' AS status;
SQL

if [ $? -eq 0 ]; then
    echo ""
    echo -e "$OK Extension pgvector créée pour Chatwoot"
else
    echo ""
    echo -e "$KO Erreur lors de la création de l'extension"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Redémarrage des pods Chatwoot ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash <<'RESTART'
set -u

echo "[$(date '+%F %T')] Suppression forcée des pods Chatwoot en erreur..."
kubectl delete pods -n chatwoot --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
echo "  ✓ Pods supprimés"

echo ""
echo "[$(date '+%F %T')] Redémarrage des déploiements..."
kubectl rollout restart deployment/chatwoot-web -n chatwoot
kubectl rollout restart deployment/chatwoot-worker -n chatwoot
echo "  ✓ Chatwoot redémarré"

RESTART

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Attente du démarrage (60 secondes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for i in {60..1}; do
    echo -ne "\rAttente... ${i}s restantes   "
    sleep 1
done
echo ""

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ État final des applications ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@$MASTER_IP bash <<'CHECK'
echo "Pods des applications :"
echo ""

kubectl get pods -n n8n -n chatwoot -n litellm -n superset -n qdrant

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

RUNNING=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep "Running" | wc -l)
TOTAL=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep -v Completed | wc -l)

echo "Résumé des pods :"
echo "  Pods Running : $RUNNING/$TOTAL"
echo ""

if [ $RUNNING -ge 10 ]; then
    echo "✅ SUCCÈS ! La majorité des pods sont Running"
    echo ""
    echo "Applications disponibles :"
    echo "  • n8n      : https://n8n.keybuzz.io"
    echo "  • Chatwoot : https://chat.keybuzz.io"
    echo "  • LiteLLM  : https://llm.keybuzz.io"
    echo "  • Qdrant   : https://qdrant.keybuzz.io"
    echo "  • Superset : https://superset.keybuzz.io"
else
    echo "⚠️  Certains pods ne sont pas encore Running"
    echo "   Attendez 2-3 minutes et vérifiez à nouveau"
fi

CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Correction terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Prochaines étapes :"
echo "  1. Attendre 2-3 minutes que Superset termine ses init containers"
echo "  2. Vérifier : ssh root@10.0.0.100 kubectl get pods -A"
echo "  3. Lancer : ./apps_final_tests.sh"
echo ""

exit 0
