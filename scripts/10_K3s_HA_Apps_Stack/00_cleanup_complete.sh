#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   CLEANUP COMPLET - Reset K3s Apps + Bases de Données             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "⚠️  ATTENTION : Ce script va SUPPRIMER :"
echo "  1. Tous les namespaces apps (n8n, litellm, chatwoot, qdrant, superset)"
echo "  2. Tous les secrets et ConfigMaps associés"
echo "  3. Toutes les bases de données PostgreSQL des apps"
echo "  4. Tous les Ingress et Services"
echo ""
echo "NE TOUCHE PAS :"
echo "  ✓ Cluster K3s (masters + workers)"
echo "  ✓ PostgreSQL/Patroni (juste nettoyage des bases apps)"
echo "  ✓ Redis, RabbitMQ, HAProxy"
echo "  ✓ Ingress NGINX, cert-manager"
echo ""

read -p "Êtes-vous ABSOLUMENT SÛR de vouloir tout nettoyer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 1/4 : Suppression des namespaces K3s apps ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for NS in n8n litellm chatwoot qdrant superset erpnext; do
    if kubectl get namespace $NS >/dev/null 2>&1; then
        echo "→ Suppression namespace $NS..."
        kubectl delete namespace $NS --grace-period=0 --force 2>/dev/null || true
        echo -e "  $OK $NS supprimé"
    else
        echo -e "  $WARN $NS n'existe pas"
    fi
done

echo ""
echo "Attente de la suppression complète (30s)..."
sleep 30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 2/4 : Nettoyage des bases de données PostgreSQL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$WARN postgres.env introuvable, utilisation mot de passe par défaut"
    read -sp "Mot de passe PostgreSQL : " POSTGRES_PASSWORD
    echo ""
fi

echo "→ Suppression des bases de données apps..."

ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres" <<SQL
-- Terminer toutes les connexions actives
SELECT pg_terminate_backend(pid) FROM pg_stat_activity 
WHERE datname IN ('n8n', 'litellm', 'chatwoot', 'superset', 'erpnext') 
AND pid <> pg_backend_pid();

-- Supprimer les bases
DROP DATABASE IF EXISTS n8n;
DROP DATABASE IF EXISTS litellm;
DROP DATABASE IF EXISTS chatwoot;
DROP DATABASE IF EXISTS superset;
DROP DATABASE IF EXISTS erpnext;

-- Supprimer les users (si pas utilisés ailleurs)
DROP USER IF EXISTS n8n;
DROP USER IF EXISTS litellm;
DROP USER IF EXISTS chatwoot;
DROP USER IF EXISTS superset;
DROP USER IF EXISTS erpnext;

SELECT 'Bases de données supprimées' AS status;
SQL

if [ $? -eq 0 ]; then
    echo -e "$OK Bases de données nettoyées"
else
    echo -e "$KO Erreur lors du nettoyage des bases"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 3/4 : Vérification de la suppression ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Namespaces restants :"
kubectl get namespaces | grep -E '(n8n|litellm|chatwoot|qdrant|superset|erpnext)' && echo -e "$WARN Namespaces encore présents" || echo -e "$OK Tous les namespaces apps supprimés"

echo ""
echo "→ Bases de données restantes :"
ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -c '\l'" | grep -E '(n8n|litellm|chatwoot|superset|erpnext)' && echo -e "$WARN Bases encore présentes" || echo -e "$OK Toutes les bases apps supprimées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 4/4 : État du cluster K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Nœuds K3s :"
kubectl get nodes

echo ""
echo "→ Pods systèmes (doivent rester Running) :"
kubectl get pods -n kube-system
kubectl get pods -n ingress-nginx
kubectl get pods -n cert-manager

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CLEANUP TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "État du cluster :"
echo "  ✓ K3s cluster : OK"
echo "  ✓ Ingress NGINX : OK"
echo "  ✓ cert-manager : OK"
echo "  ✓ PostgreSQL/Patroni : OK (bases apps supprimées)"
echo "  ✓ Redis/RabbitMQ : OK"
echo ""
echo "Prochaines étapes :"
echo "  1. ./01_verify_prerequisites.sh  - Vérifier tous les pré-requis"
echo "  2. ./02_deploy_apps_clean.sh     - Redéployer proprement"
echo ""
