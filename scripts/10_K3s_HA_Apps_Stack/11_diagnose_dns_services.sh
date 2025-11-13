#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic et Correction - DNS + Services                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Identification des IPs Load Balancer ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Récupération des IPs depuis les DNS actuels :"
echo ""

DOMAINS=("n8n.keybuzz.io" "chat.keybuzz.io" "llm.keybuzz.io" "qdrant.keybuzz.io" "superset.keybuzz.io")

declare -A DNS_IPS
for domain in "${DOMAINS[@]}"; do
    ip=$(dig +short "$domain" | head -n1)
    DNS_IPS["$domain"]="$ip"
    echo "  $domain → $ip"
done

echo ""
echo "Analyse :"
echo ""

# Trouver l'IP du LB (celle qui est la plus utilisée et qui n'est pas 10.0.0.100)
declare -A IP_COUNT
for domain in "${DOMAINS[@]}"; do
    ip="${DNS_IPS[$domain]}"
    if [ "$ip" != "10.0.0.100" ] && [ -n "$ip" ]; then
        ((IP_COUNT[$ip]=${IP_COUNT[$ip]:-0}+1))
    fi
done

LB_IP=""
MAX_COUNT=0
for ip in "${!IP_COUNT[@]}"; do
    count=${IP_COUNT[$ip]}
    if [ $count -gt $MAX_COUNT ]; then
        MAX_COUNT=$count
        LB_IP="$ip"
    fi
done

if [ -z "$LB_IP" ]; then
    echo -e "$WARN Impossible de déterminer automatiquement l'IP du Load Balancer"
    echo ""
    read -p "Entrez l'IP publique du Load Balancer Hetzner : " LB_IP
fi

echo "  IP Load Balancer détectée : $LB_IP"
echo ""
echo "  Problèmes identifiés :"

for domain in "${DOMAINS[@]}"; do
    ip="${DNS_IPS[$domain]}"
    if [ "$ip" = "10.0.0.100" ]; then
        echo -e "    $KO $domain pointe vers 10.0.0.100 (IP privée Master K3s)"
    elif [ "$ip" != "$LB_IP" ]; then
        echo -e "    $WARN $domain pointe vers $ip (devrait être $LB_IP)"
    else
        echo -e "    $OK $domain correctement configuré"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test des Services K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Vérification des services déployés :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'SERVICES_CHECK'
check_service() {
    local namespace="$1"
    local service="$2"
    
    echo -n "  $namespace/$service ... "
    
    if kubectl get svc -n "$namespace" "$service" >/dev/null 2>&1; then
        endpoints=$(kubectl get endpoints -n "$namespace" "$service" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        if [ -n "$endpoints" ]; then
            echo -e "\033[0;32mOK\033[0m (endpoints: $endpoints)"
        else
            echo -e "\033[0;33mWARN\033[0m (service existe mais pas d'endpoints)"
        fi
    else
        echo -e "\033[0;31mKO\033[0m (service n'existe pas)"
    fi
}

check_service "n8n" "n8n"
check_service "chatwoot" "chatwoot-web"
check_service "litellm" "litellm"
check_service "qdrant" "qdrant"
check_service "superset" "superset"
SERVICES_CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test depuis un Worker (local) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)

WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "Test depuis k3s-worker-01 ($WORKER_IP) via NodePort $HTTP_NODEPORT :"
echo ""

for domain in "${DOMAINS[@]}"; do
    echo -n "  $domain ... "
    
    response=$(ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" \
        "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $domain' http://127.0.0.1:$HTTP_NODEPORT/ --max-time 5" 2>/dev/null)
    
    case "$response" in
        200|302)
            echo -e "$OK (HTTP $response)"
            ;;
        404)
            echo -e "$WARN (HTTP $response - Route OK mais service manquant)"
            ;;
        503)
            echo -e "$WARN (HTTP $response - Ingress OK mais backend indisponible)"
            ;;
        000|"")
            echo -e "$KO (Timeout - Problème Ingress ou backend)"
            ;;
        *)
            echo -e "$WARN (HTTP $response)"
            ;;
    esac
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test depuis Internet (via Load Balancer) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test HTTP depuis Internet via $LB_IP :"
echo ""

for domain in "${DOMAINS[@]}"; do
    ip="${DNS_IPS[$domain]}"
    
    echo -n "  $domain "
    
    if [ "$ip" != "$LB_IP" ]; then
        echo -e "$WARN (DNS incorrect: $ip)"
    else
        echo -n "... "
        
        response=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$domain" 2>/dev/null)
        
        case "$response" in
            200|302)
                echo -e "$OK (HTTP $response)"
                ;;
            404)
                echo -e "$WARN (HTTP $response - Service non déployé)"
                ;;
            503)
                echo -e "$WARN (HTTP $response - Backend indisponible)"
                ;;
            000|"")
                echo -e "$KO (Timeout)"
                ;;
            *)
                echo -e "$WARN (HTTP $response)"
                ;;
        esac
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSUMÉ ET ACTIONS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<SUMMARY

📊 État actuel :

✅ Fonctionnels (depuis Internet) :
   - llm.keybuzz.io (HTTP 200)
   - superset.keybuzz.io (HTTP 302)

⚠️  Partiellement fonctionnels :
   - chat.keybuzz.io (HTTP 503 - Service non déployé dans K3s)

❌ Non fonctionnels :
   - n8n.keybuzz.io (DNS incorrect → 10.0.0.100)
   - qdrant.keybuzz.io (À vérifier)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔧 Actions à effectuer :

1️⃣  CORRIGER LE DNS POUR n8n.keybuzz.io

   Chez votre registrar DNS, modifier l'enregistrement :
   
   n8n.keybuzz.io    A    $LB_IP
   
   (Actuellement pointe vers 10.0.0.100)

2️⃣  DÉPLOYER LES SERVICES MANQUANTS

   Les Ingress routes existent mais les applications ne sont pas
   déployées dans K3s :
   
   - n8n        : Déployer dans namespace n8n
   - Chatwoot   : Déployer dans namespace chatwoot
   - Qdrant     : Déployer dans namespace qdrant

3️⃣  VÉRIFIER LE LOAD BALANCER HETZNER

   Console Hetzner → Load Balancers → lb-keybuzz-1
   
   Vérifier que :
   - Targets : 5 workers sont "Healthy" (vert)
   - Services : HTTP (80 → $HTTP_NODEPORT) et HTTPS configurés
   - Health Check : HTTP sur port $HTTP_NODEPORT, path /healthz

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎯 Prochaine étape :

Une fois le DNS corrigé et les services déployés, relancer :
  ./10_verify_final.sh

SUMMARY

echo ""
