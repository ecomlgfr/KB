#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic Avancé - Load Balancers Multiples + DNS             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

DOMAINS=("n8n.keybuzz.io" "chat.keybuzz.io" "llm.keybuzz.io" "qdrant.keybuzz.io" "superset.keybuzz.io")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Analyse DNS Complète ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Résolution DNS pour chaque domaine :"
echo ""

declare -A DNS_MAP
declare -A IP_LIST

for domain in "${DOMAINS[@]}"; do
    echo "→ $domain"
    
    # Récupérer TOUTES les IPs (pas juste la première)
    ips=$(dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)
    
    if [ -z "$ips" ]; then
        echo "  ❌ Pas de résolution DNS"
        DNS_MAP["$domain"]="NONE"
    else
        DNS_MAP["$domain"]="$ips"
        
        # Afficher toutes les IPs
        count=$(echo "$ips" | wc -l)
        if [ "$count" -gt 1 ]; then
            echo -e "  $WARN $count IPs trouvées (Round-Robin DNS) :"
            echo "$ips" | while read ip; do
                echo "    - $ip"
                IP_LIST["$ip"]=1
            done
        else
            echo "  ✓ $ips"
            IP_LIST["$ips"]=1
        fi
    fi
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. IPs uniques détectées ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

UNIQUE_IPS=($(echo "${!IP_LIST[@]}" | tr ' ' '\n' | sort -u))

echo "IPs publiques trouvées dans les DNS :"
echo ""

for ip in "${UNIQUE_IPS[@]}"; do
    echo "  $ip"
    
    # Identifier la source (LB ou autre)
    if [[ "$ip" == 10.0.0.* ]]; then
        echo "    → IP PRIVÉE (ne devrait PAS être dans le DNS public !)"
    else
        echo "    → IP publique (Load Balancer probable)"
    fi
    
    # Domaines utilisant cette IP
    echo -n "    Utilisée par : "
    for domain in "${DOMAINS[@]}"; do
        if echo "${DNS_MAP[$domain]}" | grep -q "$ip"; then
            echo -n "$domain "
        fi
    done
    echo ""
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test connectivité vers chaque IP publique ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for ip in "${UNIQUE_IPS[@]}"; do
    # Skip private IPs
    if [[ "$ip" == 10.0.0.* ]]; then
        continue
    fi
    
    echo "→ Test vers $ip"
    echo ""
    
    for domain in "${DOMAINS[@]}"; do
        # Tester seulement si ce domaine utilise cette IP
        if ! echo "${DNS_MAP[$domain]}" | grep -q "$ip"; then
            continue
        fi
        
        echo -n "  $domain (Host header) ... "
        
        response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
            -H "Host: $domain" "http://$ip/" 2>/dev/null)
        
        case "$response" in
            200|302)
                echo -e "$OK (HTTP $response)"
                ;;
            404|401)
                echo -e "$WARN (HTTP $response - App OK mais route manquante)"
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
    done
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test depuis Internet (sans forcer l'IP) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test HTTP normal (laisse le DNS résoudre) :"
echo ""

for domain in "${DOMAINS[@]}"; do
    echo -n "  $domain ... "
    
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        "http://$domain/" 2>/dev/null)
    
    case "$response" in
        200|302)
            echo -e "$OK (HTTP $response)"
            ;;
        404|401)
            echo -e "$WARN (HTTP $response)"
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
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Test stabilité (10 requêtes consécutives) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tester un domaine qui devrait fonctionner
TEST_DOMAIN="llm.keybuzz.io"

echo "Test de stabilité sur $TEST_DOMAIN (10 requêtes) :"
echo ""

SUCCESS=0
FAILED=0
declare -A RESPONSE_COUNTS

for i in {1..10}; do
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        "http://$TEST_DOMAIN/" 2>/dev/null)
    
    ((RESPONSE_COUNTS[$response]=${RESPONSE_COUNTS[$response]:-0}+1))
    
    echo -n "  #$i : HTTP $response "
    
    if [ "$response" = "200" ] || [ "$response" = "302" ]; then
        echo -e "[$OK]"
        ((SUCCESS++))
    else
        echo -e "[$KO]"
        ((FAILED++))
    fi
    
    sleep 1
done

echo ""
echo "Résultat :"
echo "  Succès : $SUCCESS/10"
echo "  Échecs : $FAILED/10"
echo ""

if [ "$FAILED" -gt 3 ]; then
    echo -e "$KO Instable (plus de 3 échecs)"
else
    echo -e "$OK Stable"
fi

echo ""
echo "Répartition des codes HTTP :"
for code in "${!RESPONSE_COUNTS[@]}"; do
    count=${RESPONSE_COUNTS[$code]}
    echo "  HTTP $code : $count fois"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC ET RECOMMANDATIONS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Compter les IPs uniques (hors privées)
PUBLIC_IP_COUNT=0
for ip in "${UNIQUE_IPS[@]}"; do
    if [[ "$ip" != 10.0.0.* ]]; then
        ((PUBLIC_IP_COUNT++))
    fi
done

cat <<DIAGNOSTIC

📊 Résumé du diagnostic :

Nombre d'IPs publiques détectées : $PUBLIC_IP_COUNT

DIAGNOSTIC:

if [ "$PUBLIC_IP_COUNT" -eq 0 ]; then
    cat <<PROBLEM
❌ PROBLÈME CRITIQUE : Aucune IP publique valide

   Tous les domaines pointent vers des IPs privées (10.0.0.x)
   
   ACTION REQUISE :
   1. Identifier l'IP publique du Load Balancer Hetzner
   2. Mettre à jour TOUS les DNS pour pointer vers cette IP

PROBLEM

elif [ "$PUBLIC_IP_COUNT" -eq 1 ]; then
    MAIN_IP="${UNIQUE_IPS[0]}"
    
    cat <<PROBLEM
✅ Configuration correcte : 1 seule IP publique
   
   IP du Load Balancer : $MAIN_IP
   
   Vérifications à faire :
   
   1. Tous les domaines pointent vers cette IP ?
PROBLEM
    
    # Vérifier si tous pointent vers la même
    BAD_DNS=0
    for domain in "${DOMAINS[@]}"; do
        if ! echo "${DNS_MAP[$domain]}" | grep -q "$MAIN_IP"; then
            echo "      ❌ $domain pointe ailleurs"
            ((BAD_DNS++))
        fi
    done
    
    if [ "$BAD_DNS" -gt 0 ]; then
        cat <<FIX
   
   → Corriger les $BAD_DNS domaines mal configurés
   
FIX
    fi
    
    cat <<CHECKS
   
   2. Load Balancer Hetzner configuré correctement ?
      → Console : https://console.hetzner.cloud/
      → Onglet Targets : Tous "Healthy" ?
      → Onglet Services : Port 80 → 31695 ?
      → Onglet Health Checks : HTTP /healthz sur port 31695 ?
   
CHECKS

else
    cat <<PROBLEM
⚠️  PROBLÈME : $PUBLIC_IP_COUNT IPs publiques différentes
   
   IPs trouvées :
PROBLEM
    
    for ip in "${UNIQUE_IPS[@]}"; do
        if [[ "$ip" != 10.0.0.* ]]; then
            echo "      - $ip"
        fi
    done
    
    cat <<EXPLANATION
   
   Causes possibles :
   
   A) Plusieurs Load Balancers Hetzner
      → Identifier le bon et supprimer les autres
      → Ou configurer tous correctement
   
   B) DNS mal configurés
      → Certains domaines pointent vers une ancienne IP
      → Mettre à jour tous les DNS vers la même IP
   
   C) CDN ou proxy devant
      → Cloudflare, etc.
      → Vérifier la configuration
   
   ACTION IMMÉDIATE :
   
   1. Aller sur Hetzner Console
      https://console.hetzner.cloud/
      → Load Balancers
      → Noter l'IP IPv4 du Load Balancer actif
   
   2. Mettre à jour TOUS les DNS pour pointer vers cette IP :
EXPLANATION
    
    for domain in "${DOMAINS[@]}"; do
        echo "      $domain    A    <IP_DU_LOAD_BALANCER>"
    done
    
fi

cat <<NEXTCHECKS

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔍 Vérifications supplémentaires :

1. État des targets Hetzner (CRITIQUE)
   
   Aller sur : https://console.hetzner.cloud/
   → Load Balancers → lb-keybuzz-1 → Onglet "Targets"
   
   Vérifier :
   ✓ 5 targets présents (10.0.0.110 à 114) ?
   ✓ Tous "Healthy" (vert) ?
   
   Si "Unhealthy" (rouge) :
   → Onglet "Health Checks" → Vérifier :
     - Protocol : HTTP
     - Port : 31695
     - Path : /healthz
     - Status codes : 200

2. Services K3s
   
   Vérifier que les services ont des endpoints :
   kubectl get svc,endpoints -n n8n
   kubectl get svc,endpoints -n qdrant
   kubectl get svc,endpoints -n superset

3. Logs Ingress NGINX
   
   Vérifier les erreurs :
   kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

NEXTCHECKS

echo ""
