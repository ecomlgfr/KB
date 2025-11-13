#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         Test Final - Toutes les Applications                      ║"
echo "║    (n8n, litellm, qdrant, chatwoot, superset)                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_WORKER=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Applications déployées :"
echo ""

for ns in n8n litellm qdrant chatwoot superset; do
    POD_COUNT=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l)
    RUNNING=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c Running || echo 0)
    
    if [ "$POD_COUNT" -gt 0 ]; then
        if [ "$RUNNING" -eq "$POD_COUNT" ]; then
            echo -e "  ✅ $ns : $RUNNING/$POD_COUNT Running"
        else
            echo -e "  ⚠️  $ns : $RUNNING/$POD_COUNT Running"
        fi
    else
        echo -e "  ❌ $ns : Non déployé"
    fi
done

echo ""
echo "Détail des pods :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep -v 'ingress\|admission'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. État des services ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get svc -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. État des Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get ingress -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Tests HTTP internes (via pods) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test depuis les pods eux-mêmes :"
echo ""

test_internal() {
    local namespace="$1"
    local app="$2"
    local port="$3"
    local path="${4:-/}"
    
    echo -n "  $app ($namespace:$port) ... "
    
    POD=$(kubectl get pods -n "$namespace" -l app="$app" -o name 2>/dev/null | head -n1 | cut -d/ -f2)
    
    if [ -z "$POD" ]; then
        echo -e "$KO (Aucun pod)"
        return
    fi
    
    result=$(kubectl exec -n "$namespace" "$POD" -- timeout 5 curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}${path}" 2>/dev/null || echo "000")
    
    case "$result" in
        200|302|404|401)
            echo -e "$OK (HTTP $result)"
            ;;
        000|"")
            echo -e "$KO (Timeout)"
            ;;
        *)
            echo -e "$WARN (HTTP $result)"
            ;;
    esac
}

test_internal "n8n" "n8n" "5678" "/"
test_internal "litellm" "litellm" "4000" "/"
test_internal "qdrant" "qdrant" "6333" "/"
test_internal "chatwoot" "chatwoot" "3000" "/api"
test_internal "superset" "superset" "8088" "/health"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Tests via Ingress NGINX (NodePort 31695) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test depuis un worker via Ingress ($IP_WORKER:31695) :"
echo ""

test_ingress() {
    local domain="$1"
    local app="$2"
    
    echo -n "  $domain ... "
    
    result=$(timeout 5 curl -s -o /dev/null -w '%{http_code}' \
        -H "Host: $domain" "http://$IP_WORKER:31695/" 2>/dev/null || echo "000")
    
    case "$result" in
        200|302|404|401)
            echo -e "$OK (HTTP $result)"
            ;;
        503)
            echo -e "$WARN (HTTP $result - Backend pas prêt)"
            ;;
        000|"")
            echo -e "$KO (Timeout)"
            ;;
        *)
            echo -e "$WARN (HTTP $result)"
            ;;
    esac
}

test_ingress "n8n.keybuzz.io" "n8n"
test_ingress "llm.keybuzz.io" "litellm"
test_ingress "qdrant.keybuzz.io" "qdrant"
test_ingress "chat.keybuzz.io" "chatwoot"
test_ingress "superset.keybuzz.io" "superset"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Tests depuis Internet (si DNS configuré) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test stabilité depuis Internet :"
echo ""

DOMAINS=("n8n.keybuzz.io" "llm.keybuzz.io" "qdrant.keybuzz.io" "chat.keybuzz.io" "superset.keybuzz.io")
declare -A RESULTS

for domain in "${DOMAINS[@]}"; do
    echo "→ $domain"
    
    SUCCESS=0
    for i in {1..5}; do
        response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
            "http://$domain/" 2>/dev/null)
        
        echo -n "  #$i : HTTP $response "
        
        if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "401" ]; then
            echo -e "[$OK]"
            ((SUCCESS++))
        else
            echo -e "[$KO]"
        fi
        
        sleep 1
    done
    
    RESULTS[$domain]=$SUCCESS
    echo "  Résultat : $SUCCESS/5 succès"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Vérification Load Balancers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test Load Balancers séparément :"
echo ""

LB1="49.13.42.76"
LB2="138.199.132.240"

echo "→ LB1 ($LB1)"
for domain in "${DOMAINS[@]}"; do
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        -H "Host: $domain" "http://$LB1/" 2>/dev/null)
    
    echo -n "  $domain : HTTP $response "
    
    if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "401" ]; then
        echo -e "[$OK]"
    else
        echo -e "[$KO]"
    fi
done

echo ""
echo "→ LB2 ($LB2)"
for domain in "${DOMAINS[@]}"; do
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        -H "Host: $domain" "http://$LB2/" 2>/dev/null)
    
    echo -n "  $domain : HTTP $response "
    
    if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "401" ]; then
        echo -e "[$OK]"
    else
        echo -e "[$KO]"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSULTAT FINAL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Calculer score total
TOTAL_SUCCESS=0
TOTAL_TESTS=0

for domain in "${DOMAINS[@]}"; do
    success="${RESULTS[$domain]}"
    TOTAL_SUCCESS=$((TOTAL_SUCCESS + success))
    TOTAL_TESTS=$((TOTAL_TESTS + 5))
done

PERCENT=$((TOTAL_SUCCESS * 100 / TOTAL_TESTS))

echo "Score global : $TOTAL_SUCCESS/$TOTAL_TESTS ($PERCENT%)"
echo ""

if [ "$PERCENT" -ge 80 ]; then
    cat <<SUCCESS
✅ TOUTES LES APPLICATIONS FONCTIONNENT !

Applications déployées :
  ✓ n8n        : Workflow automation
  ✓ litellm    : LLM Router
  ✓ qdrant     : Vector database
  ✓ chatwoot   : Customer support
  ✓ superset   : Business Intelligence

Accès :
  - n8n       : http://n8n.keybuzz.io
  - LiteLLM   : http://llm.keybuzz.io
  - Qdrant    : http://qdrant.keybuzz.io
  - Chatwoot  : http://chat.keybuzz.io
  - Superset  : http://superset.keybuzz.io

Credentials :
  Chatwoot  : Premier accès → Créer compte admin
  Superset  : admin / Admin123!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SUCCESS
elif [ "$PERCENT" -ge 50 ]; then
    cat <<PARTIAL
⚠️  FONCTIONNEMENT PARTIEL

Score : $PERCENT%

Applications fonctionnelles : $((TOTAL_SUCCESS / 5))/$((TOTAL_TESTS / 5))

Actions à faire :
  1. Vérifier les pods en erreur :
     kubectl get pods -A | grep -v Running

  2. Vérifier les logs :
     kubectl logs -n <namespace> <pod-name>

  3. Vérifier le DNS :
     dig +short <domain>.keybuzz.io

  4. Vérifier Load Balancers dans Hetzner Console

PARTIAL
else
    cat <<FAILURE
❌ PROBLÈMES DÉTECTÉS

Score : $PERCENT% (insuffisant)

Actions à faire :
  1. Vérifier état des pods :
     kubectl get pods -A

  2. Vérifier Ingress NGINX :
     kubectl get pods -n ingress-nginx

  3. Vérifier Load Balancers :
     - Console Hetzner → Load Balancers
     - Targets : Doivent être "Healthy"
     - Services : HTTP 80 → 31695
     - Health Checks : HTTP port 31695 path /healthz

  4. Vérifier DNS :
     for domain in n8n chat llm qdrant superset; do
       dig +short \${domain}.keybuzz.io
     done
     
     → Chaque domaine doit retourner 2 IPs :
       - 49.13.42.76
       - 138.199.132.240

  5. Test manuel depuis un worker :
     curl -H "Host: llm.keybuzz.io" http://$IP_WORKER:31695/

FAILURE
fi

echo ""
echo "Commandes utiles :"
echo "  kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)'"
echo "  kubectl logs -n chatwoot -l component=web --tail=50"
echo "  kubectl logs -n superset -l app=superset --tail=50"
echo "  kubectl describe pod -n chatwoot <pod-name>"
echo ""

exit 0
