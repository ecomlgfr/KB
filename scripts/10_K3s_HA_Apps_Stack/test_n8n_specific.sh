#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    TEST SPÉCIFIQUE N8N - Détection problème création compte       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✅\033[0m'
KO='\033[0;31m❌\033[0m'
WARN='\033[0;33m⚠️\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_FILE="/opt/keybuzz-installer/logs/test_n8n_api_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

if [ ! -f "$SERVERS_TSV" ]; then
    echo -e "$KO servers.tsv introuvable"
    exit 1
fi

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. ÉTAT DES PODS N8N ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n n8n -o wide"

N8N_POD=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n n8n --no-headers -o custom-columns=:metadata.name | head -1" 2>/dev/null)

if [ -z "$N8N_POD" ]; then
    echo -e "$KO Aucun pod n8n trouvé"
    exit 1
fi

echo ""
echo -e "$OK Pod sélectionné : $N8N_POD"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. VARIABLES D'ENVIRONNEMENT DANS LE POD ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Variables de connexion BDD :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- env | grep -E 'DB_|DATABASE_|POSTGRES' | sort"

echo ""
echo "🔍 Autres variables n8n importantes :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- env | grep -E 'N8N_|WEBHOOK_|EXECUTIONS_' | sort"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. TEST CONNEXION RÉSEAU DEPUIS LE POD ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Test connexion PostgreSQL (10.0.0.10:5432)..."
if ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- timeout 5 sh -c 'cat < /dev/null > /dev/tcp/10.0.0.10/5432' 2>&1" | grep -q "succeeded\|connected"; then
    echo -e "$OK Connexion TCP vers PostgreSQL OK"
else
    echo -e "$KO Connexion TCP vers PostgreSQL ÉCHOUÉE"
    echo "   → Vérifier UFW sur les workers"
    echo "   → Vérifier HAProxy sur 10.0.0.10"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. LOGS N8N (50 dernières lignes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n n8n $N8N_POD --tail=50"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. TEST ENDPOINT /HEALTHZ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Test health check n8n..."
HEALTH_RESPONSE=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- wget -qO- http://localhost:5678/healthz 2>&1" || echo "FAILED")

if echo "$HEALTH_RESPONSE" | grep -q "ok\|healthy"; then
    echo -e "$OK Health check n8n : OK"
    echo "   Response : $HEALTH_RESPONSE"
else
    echo -e "$KO Health check n8n : ÉCHEC"
    echo "   Response : $HEALTH_RESPONSE"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. TEST ACCÈS EXTERNE (via Load Balancer) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Test accès HTTPS n8n.keybuzz.io..."
HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" https://n8n.keybuzz.io 2>/dev/null || echo "000")

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
    echo -e "$OK n8n accessible via HTTPS (HTTP $HTTP_STATUS)"
else
    echo -e "$KO n8n NON accessible via HTTPS (HTTP $HTTP_STATUS)"
    echo "   → Vérifier Ingress NGINX"
    echo "   → Vérifier Load Balancer Hetzner"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. TEST API /LOGIN (setup initial) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Test endpoint /login..."
LOGIN_RESPONSE=$(curl -k -s https://n8n.keybuzz.io/login 2>&1)

if echo "$LOGIN_RESPONSE" | grep -qi "n8n\|setup\|login"; then
    echo -e "$OK Page de login/setup accessible"
else
    echo -e "$WARN Réponse inattendue de /login"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. VÉRIFICATION BASE DE DONNÉES N8N ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

POSTGRES_ENV="/opt/keybuzz-installer/credentials/postgres.env"
if [ -f "$POSTGRES_ENV" ]; then
    source "$POSTGRES_ENV"
    
    echo "🔍 Connexion à la base n8n..."
    if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 10.0.0.10 -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT 1;" &>/dev/null; then
        echo -e "$OK Connexion base n8n OK"
        
        echo ""
        echo "🔍 Tables dans n8n :"
        TABLE_COUNT=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 10.0.0.10 -p 5432 -U "${POSTGRES_USER}" -d n8n -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null)
        echo "   Nombre de tables : $TABLE_COUNT"
        
        if [ "$TABLE_COUNT" -eq 0 ]; then
            echo -e "$KO Aucune table ! Les migrations n8n n'ont pas été exécutées"
            echo ""
            echo "💡 Solution :"
            echo "   kubectl rollout restart daemonset/n8n -n n8n"
            echo "   kubectl logs -n n8n -l app=n8n -f"
        else
            echo ""
            echo "🔍 Liste des tables :"
            PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 10.0.0.10 -p 5432 -U "${POSTGRES_USER}" -d n8n -c "\dt"
            
            echo ""
            echo "🔍 Utilisateurs existants :"
            USER_COUNT=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 10.0.0.10 -p 5432 -U "${POSTGRES_USER}" -d n8n -tAc "SELECT COUNT(*) FROM \"user\" 2>/dev/null" 2>/dev/null || echo "0")
            echo "   Nombre d'utilisateurs : $USER_COUNT"
            
            if [ "$USER_COUNT" -gt 0 ]; then
                PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 10.0.0.10 -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT id, email, \"firstName\", \"lastName\" FROM \"user\" LIMIT 3;" 2>/dev/null
            fi
        fi
    else
        echo -e "$KO Impossible de se connecter à la base n8n"
    fi
else
    echo -e "$WARN postgres.env introuvable"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. ANALYSE DES ERREURS DANS LES LOGS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Recherche d'erreurs dans les logs..."
ERROR_LOGS=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n n8n $N8N_POD --tail=200 2>&1 | grep -iE 'error|failed|timeout|refused|unable|cannot'" 2>/dev/null)

if [ -z "$ERROR_LOGS" ]; then
    echo -e "$OK Aucune erreur détectée dans les logs"
else
    echo -e "$WARN Erreurs trouvées :"
    echo "$ERROR_LOGS"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10. TEST CRÉATION UTILISATEUR VIA CLI ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

read -p "Voulez-vous tester la création d'un utilisateur via CLI n8n ? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Email : " TEST_EMAIL
    read -sp "Mot de passe : " TEST_PASSWORD
    echo ""
    
    echo "🔧 Tentative de création via n8n CLI..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- n8n user-management:reset --email=\"$TEST_EMAIL\" --password=\"$TEST_PASSWORD\"" 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "$OK Utilisateur créé/réinitialisé avec succès"
        echo ""
        echo "🔍 Vérification dans la base :"
        if [ -f "$POSTGRES_ENV" ]; then
            PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 10.0.0.10 -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT id, email, \"firstName\", \"lastName\" FROM \"user\" WHERE email='$TEST_EMAIL';" 2>/dev/null
        fi
    else
        echo -e "$KO Échec de création via CLI"
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC TERMINÉ ═══"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Résumé :"
echo "   • Log complet : $LOG_FILE"
echo ""
echo "🔍 Points à vérifier :"
echo "   □ Pods n8n Running"
echo "   □ Variables DB correctes dans le pod"
echo "   □ Connexion TCP 10.0.0.10:5432 OK"
echo "   □ Health check n8n OK"
echo "   □ HTTPS accessible"
echo "   □ Base n8n existe avec tables"
echo "   □ Aucune erreur dans les logs"
echo ""
echo "💡 Si le diagnostic révèle un problème :"
echo "   1. Credentials incorrects → ./reset_apps_bdd_complet.sh"
echo "   2. Pas de tables → kubectl rollout restart daemonset/n8n -n n8n"
echo "   3. Connexion bloquée → Vérifier UFW"
echo "   4. Autre → Consulter GUIDE_RESOLUTION_BOUCLE_INFINIE.txt"
echo ""
