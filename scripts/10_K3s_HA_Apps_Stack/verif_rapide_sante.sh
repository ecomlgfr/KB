#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    VÉRIFICATION RAPIDE - État de santé KeyBuzz                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✅\033[0m'
KO='\033[0;31m❌\033[0m'
WARN='\033[0;33m⚠️\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
POSTGRES_ENV="/opt/keybuzz-installer/credentials/postgres.env"

if [ ! -f "$SERVERS_TSV" ] || [ ! -f "$POSTGRES_ENV" ]; then
    echo -e "$KO Fichiers de configuration introuvables"
    exit 1
fi

source "$POSTGRES_ENV"

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
IP_DB_LB="10.0.0.10"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. CONNECTIVITÉ POSTGRESQL ═══"
echo "═══════════════════════════════════════════════════════════════════"

if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -c "SELECT 1;" &>/dev/null; then
    echo -e "$OK PostgreSQL accessible (10.0.0.10:5432)"
else
    echo -e "$KO PostgreSQL INACCESSIBLE"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. BASES DE DONNÉES ═══"
echo "═══════════════════════════════════════════════════════════════════"

for db in n8n litellm qdrant_db superset chatwoot; do
    if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null | grep -q 1; then
        table_count=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d "$db" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null)
        if [ "$table_count" -gt 0 ]; then
            echo -e "$OK $db ($table_count tables)"
        else
            echo -e "$WARN $db (0 tables - migrations en attente)"
        fi
    else
        echo -e "$KO $db (n'existe pas)"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. PODS K3S ═══"
echo "═══════════════════════════════════════════════════════════════════"

for ns in n8n litellm qdrant superset chatwoot; do
    total=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    running=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running" 2>/dev/null || echo "0")
    
    if [ "$total" -eq 0 ]; then
        echo -e "$WARN $ns : Aucun pod"
    elif [ "$total" -eq "$running" ]; then
        echo -e "$OK $ns : $running/$total Running"
    else
        echo -e "$KO $ns : $running/$total Running (pods en erreur)"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. CONNEXIONS BDD ACTIVES ═══"
echo "═══════════════════════════════════════════════════════════════════"

echo ""
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -c "
SELECT 
    datname AS \"Base\", 
    COUNT(*) AS \"Connexions\"
FROM pg_stat_activity 
WHERE datname IN ('n8n', 'litellm', 'qdrant_db', 'superset', 'chatwoot')
GROUP BY datname 
ORDER BY datname;
" 2>/dev/null || echo -e "$WARN Impossible de récupérer les connexions actives"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. TEST CRÉATION COMPTE N8N ═══"
echo "═══════════════════════════════════════════════════════════════════"

user_count=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -tAc "SELECT COUNT(*) FROM \"user\" 2>/dev/null" 2>/dev/null || echo "0")

if [ "$user_count" -gt 0 ]; then
    echo -e "$OK $user_count utilisateur(s) dans n8n"
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT id, email, \"firstName\", \"lastName\" FROM \"user\" LIMIT 3;" 2>/dev/null
else
    echo -e "$WARN Aucun utilisateur n8n - première connexion en attente"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. URLS D'ACCÈS ═══"
echo "═══════════════════════════════════════════════════════════════════"

echo ""
echo "Applications disponibles :"
echo "  • n8n       : https://n8n.keybuzz.io"
echo "  • LiteLLM   : https://llm.keybuzz.io"
echo "  • Qdrant    : https://qdrant.keybuzz.io"
echo "  • Superset  : https://superset.keybuzz.io"
echo "  • Chatwoot  : https://chatwoot.keybuzz.io"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSUMÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Compter les problèmes
problems=0

if ! PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -c "SELECT 1;" &>/dev/null; then
    ((problems++))
fi

for db in n8n litellm qdrant_db superset chatwoot; do
    if ! PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null | grep -q 1; then
        ((problems++))
    fi
done

for ns in n8n litellm qdrant superset chatwoot; do
    total=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    running=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running" 2>/dev/null || echo "0")
    if [ "$total" -ne "$running" ]; then
        ((problems++))
    fi
done

if [ "$problems" -eq 0 ]; then
    echo -e "$OK Tout semble fonctionnel !"
    echo ""
    echo "Si vous rencontrez toujours le problème de boucle infinie :"
    echo "  1. Vérifiez les logs : kubectl logs -n n8n <POD>"
    echo "  2. Lancez le diagnostic : ./diagnostic_complet_bdd_apps.sh"
    echo "  3. Consultez le guide : GUIDE_RESOLUTION_BOUCLE_INFINIE.txt"
else
    echo -e "$KO $problems problème(s) détecté(s)"
    echo ""
    echo "Actions recommandées :"
    echo "  1. Lancez le diagnostic complet : ./diagnostic_complet_bdd_apps.sh"
    echo "  2. Si nécessaire, réinitialisez : ./reset_apps_bdd_complet.sh"
    echo "  3. Consultez le guide : GUIDE_RESOLUTION_BOUCLE_INFINIE.txt"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
