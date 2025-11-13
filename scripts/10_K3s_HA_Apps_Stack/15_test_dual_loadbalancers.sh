#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Test des 2 Load Balancers en Redondance                        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Configuration détectée : 2 Load Balancers en redondance"
echo ""

# IPs des Load Balancers
LB1_IP="49.13.42.76"
LB2_IP="138.199.132.240"

DOMAINS=("n8n.keybuzz.io" "chat.keybuzz.io" "llm.keybuzz.io" "qdrant.keybuzz.io" "superset.keybuzz.io")

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Configuration DNS (Round-Robin) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Vérification DNS pour chaque domaine :"
echo ""

for domain in "${DOMAINS[@]}"; do
    echo "→ $domain"
    
    # Récupérer toutes les IPs (round-robin)
    ips=$(dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)
    
    if [ -z "$ips" ]; then
        echo "  ❌ Pas de résolution DNS"
    else
        count=$(echo "$ips" | wc -l)
        
        if [ "$count" -eq 2 ]; then
            echo -e "  $OK Round-Robin configuré (2 IPs)"
            echo "$ips" | while read ip; do
                if [ "$ip" = "$LB1_IP" ]; then
                    echo "    - $ip (LB1)"
                elif [ "$ip" = "$LB2_IP" ]; then
                    echo "    - $ip (LB2)"
                else
                    echo "    - $ip (IP inconnue !)"
                fi
            done
        elif [ "$count" -eq 1 ]; then
            ip=$(echo "$ips" | head -n1)
            if [ "$ip" = "$LB1_IP" ] || [ "$ip" = "$LB2_IP" ]; then
                echo -e "  $WARN Un seul Load Balancer (pas de redondance)"
                echo "    - $ip"
            elif [[ "$ip" == 10.0.0.* ]]; then
                echo -e "  $KO IP privée dans le DNS public !"
                echo "    - $ip"
            else
                echo -e "  $WARN IP inconnue"
                echo "    - $ip"
            fi
        else
            echo -e "  $WARN Plus de 2 IPs détectées"
            echo "$ips" | while read ip; do
                echo "    - $ip"
            done
        fi
    fi
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test LOAD BALANCER 1 ($LB1_IP) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test direct vers LB1 (en forçant l'IP) :"
echo ""

LB1_SUCCESS=0
LB1_FAILED=0

for domain in "${DOMAINS[@]}"; do
    echo -n "  $domain ... "
    
    # Forcer l'IP du LB1
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        -H "Host: $domain" "http://$LB1_IP/" 2>/dev/null)
    
    case "$response" in
        200|302)
            echo -e "$OK (HTTP $response)"
            ((LB1_SUCCESS++))
            ;;
        404|401)
            echo -e "$WARN (HTTP $response - App OK mais route manquante)"
            ((LB1_SUCCESS++))
            ;;
        503)
            echo -e "$WARN (HTTP $response - Backend indisponible)"
            ((LB1_FAILED++))
            ;;
        000|"")
            echo -e "$KO (Timeout - LB ne répond pas)"
            ((LB1_FAILED++))
            ;;
        *)
            echo -e "$WARN (HTTP $response)"
            ((LB1_FAILED++))
            ;;
    esac
done

echo ""
echo "Résultat LB1 : $LB1_SUCCESS/5 domaines fonctionnels"

if [ "$LB1_FAILED" -eq 0 ]; then
    echo -e "$OK Load Balancer 1 fonctionne correctement"
    LB1_STATUS="OK"
elif [ "$LB1_SUCCESS" -eq 0 ]; then
    echo -e "$KO Load Balancer 1 ne répond pas du tout"
    LB1_STATUS="KO"
else
    echo -e "$WARN Load Balancer 1 fonctionne partiellement"
    LB1_STATUS="WARN"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test LOAD BALANCER 2 ($LB2_IP) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test direct vers LB2 (en forçant l'IP) :"
echo ""

LB2_SUCCESS=0
LB2_FAILED=0

for domain in "${DOMAINS[@]}"; do
    echo -n "  $domain ... "
    
    # Forcer l'IP du LB2
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
-H "Host: $domain" "http://$LB2_IP/" 2>/dev/null)
    
    case "$response" in
        200|302)
            echo -e "$OK (HTTP $response)"
            ((LB2_SUCCESS++))
            ;;
        404|401)
            echo -e "$WARN (HTTP $response - App OK mais route manquante)"
            ((LB2_SUCCESS++))
            ;;
        503)
            echo -e "$WARN (HTTP $response - Backend indisponible)"
            ((LB2_FAILED++))
            ;;
        000|"")
            echo -e "$KO (Timeout - LB ne répond pas)"
            ((LB2_FAILED++))
            ;;
        *)
            echo -e "$WARN (HTTP $response)"
            ((LB2_FAILED++))
            ;;
    esac
done

echo ""
echo "Résultat LB2 : $LB2_SUCCESS/5 domaines fonctionnels"

if [ "$LB2_FAILED" -eq 0 ]; then
    echo -e "$OK Load Balancer 2 fonctionne correctement"
    LB2_STATUS="OK"
elif [ "$LB2_SUCCESS" -eq 0 ]; then
    echo -e "$KO Load Balancer 2 ne répond pas du tout"
    LB2_STATUS="KO"
else
    echo -e "$WARN Load Balancer 2 fonctionne partiellement"
    LB2_STATUS="WARN"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test Stabilité (10 requêtes via DNS Round-Robin) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

TEST_DOMAIN="llm.keybuzz.io"

echo "Test via DNS Round-Robin sur $TEST_DOMAIN (10 requêtes) :"
echo ""

declare -A RESPONSE_COUNTS
TOTAL_SUCCESS=0
TOTAL_FAILED=0

for i in {1..10}; do
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        "http://$TEST_DOMAIN/" 2>/dev/null)
    
    ((RESPONSE_COUNTS[$response]=${RESPONSE_COUNTS[$response]:-0}+1))
    
    echo -n "  #$i : HTTP $response "
    
    if [ "$response" = "200" ] || [ "$response" = "302" ]; then
        echo -e "[$OK]"
        ((TOTAL_SUCCESS++))
    else
        echo -e "[$KO]"
        ((TOTAL_FAILED++))
    fi
    
    sleep 1
done

echo ""
echo "Résultat stabilité : $TOTAL_SUCCESS/10 succès"
echo ""

echo "Répartition des codes HTTP :"
for code in "${!RESPONSE_COUNTS[@]}"; do
    count=${RESPONSE_COUNTS[$code]}
    echo "  HTTP $code : $count/10 requêtes"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC ET RECOMMANDATIONS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<DIAGNOSTIC

📊 Résumé :

Load Balancer 1 ($LB1_IP) : $LB1_STATUS ($LB1_SUCCESS/5 domaines)
Load Balancer 2 ($LB2_IP) : $LB2_STATUS ($LB2_SUCCESS/5 domaines)

DIAGNOSTIC

# Diagnostic global
if [ "$LB1_STATUS" = "OK" ] && [ "$LB2_STATUS" = "OK" ]; then
    cat <<SUCCESS
✅ EXCELLENT : Les 2 Load Balancers fonctionnent !

Configuration HA correcte :
  ✓ Redondance active
  ✓ Round-Robin DNS (TTL 60s)
  ✓ Les 2 LBs routent correctement

Si tu as encore des problèmes de stabilité, c'est probablement
au niveau des backends (services K3s) et pas des Load Balancers.

Prochaines étapes :
  1. Vérifier les services K3s ont des endpoints
  2. Tester les health checks sur les workers
  3. Vérifier les logs Ingress NGINX

SUCCESS

elif [ "$LB1_STATUS" = "OK" ] && [ "$LB2_STATUS" != "OK" ]; then
    cat <<LB2_PROBLEM
⚠️  PROBLÈME : Load Balancer 2 ne fonctionne pas correctement

Load Balancer 1 ($LB1_IP) : ✅ OK
Load Balancer 2 ($LB2_IP) : ❌ KO

Conséquence :
  → 50% des requêtes vont tomber sur LB2 et échouer
  → Les utilisateurs vont avoir des résultats aléatoires
  → La redondance ne fonctionne pas

SOLUTION IMMÉDIATE :
  
  Option A : Corriger LB2 (recommandé pour garder la HA)
  
    1. Console Hetzner : https://console.hetzner.cloud/
       → Load Balancers → LB2
    
    2. Vérifier TARGETS :
       ✓ 5 workers (10.0.0.110 à 114) ?
       ✓ IPs PRIVÉES (pas publiques) ?
       ✓ Status "Healthy" ?
    
    3. Vérifier SERVICES :
       ✓ HTTP : 80 → 31695
       ✓ Protocol : HTTP
    
    4. Vérifier HEALTH CHECKS :
       ✓ Protocol : HTTP
       ✓ Port : 31695
       ✓ Path : /healthz
    
    5. Vérifier NETWORKS :
       ✓ Attaché au réseau privé keybuzz-network ?
  
  Option B : Désactiver temporairement LB2 (perte de la HA)
  
    1. Retirer $LB2_IP du DNS pour tous les domaines
    2. Garder seulement $LB1_IP
    3. TTL va expirer en 60s
    4. Tous les utilisateurs iront sur LB1 (qui fonctionne)

LB2_PROBLEM

elif [ "$LB1_STATUS" != "OK" ] && [ "$LB2_STATUS" = "OK" ]; then
    cat <<LB1_PROBLEM
⚠️  PROBLÈME : Load Balancer 1 ne fonctionne pas correctement

Load Balancer 1 ($LB1_IP) : ❌ KO
Load Balancer 2 ($LB2_IP) : ✅ OK

Conséquence :
  → 50% des requêtes vont tomber sur LB1 et échouer
  → Les utilisateurs vont avoir des résultats aléatoires
  → La redondance ne fonctionne pas

SOLUTION IMMÉDIATE :
  
  Option A : Corriger LB1 (recommandé pour garder la HA)
  
    1. Console Hetzner : https://console.hetzner.cloud/
       → Load Balancers → LB1
    
    2. Vérifier TARGETS :
       ✓ 5 workers (10.0.0.110 à 114) ?
       ✓ IPs PRIVÉES (pas publiques) ?
       ✓ Status "Healthy" ?
    
    3. Vérifier SERVICES :
       ✓ HTTP : 80 → 31695
       ✓ Protocol : HTTP
    
    4. Vérifier HEALTH CHECKS :
       ✓ Protocol : HTTP
       ✓ Port : 31695
       ✓ Path : /healthz
    
    5. Vérifier NETWORKS :
       ✓ Attaché au réseau privé keybuzz-network ?
  
  Option B : Désactiver temporairement LB1 (perte de la HA)
  
    1. Retirer $LB1_IP du DNS pour tous les domaines
    2. Garder seulement $LB2_IP
    3. TTL va expirer en 60s
    4. Tous les utilisateurs iront sur LB2 (qui fonctionne)

LB1_PROBLEM

else
    cat <<BOTH_PROBLEM
❌ CRITIQUE : Les 2 Load Balancers ont des problèmes

Load Balancer 1 ($LB1_IP) : ❌ KO
Load Balancer 2 ($LB2_IP) : ❌ KO

Conséquence :
  → Tous les domaines sont inaccessibles depuis Internet
  → Le problème n'est probablement PAS au niveau des LBs
  → Le problème est probablement au niveau des workers

DIAGNOSTIC APPROFONDI REQUIS :

1. Vérifier les workers répondent aux health checks :
   
   ./14_test_health_checks.sh
   
   → Les workers doivent répondre HTTP 200 sur /healthz

2. Vérifier UFW n'a pas bloqué les Load Balancers :
   
   IP privée LB1 : $(dig +short lb-keybuzz-1.keybuzz.internal 2>/dev/null | head -n1)
   IP privée LB2 : $(dig +short lb-keybuzz-2.keybuzz.internal 2>/dev/null | head -n1)
   
   Les 2 LBs doivent être autorisés dans UFW (via 10.0.0.0/16)

3. Vérifier les pods Ingress NGINX :
   
   kubectl get pods -n ingress-nginx -o wide
   
   → 5 pods doivent être Running

BOTH_PROBLEM
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cat <<MAINTENANCE

📝 MAINTENANCE DES 2 LOAD BALANCERS

Pour maintenir la synchronisation entre LB1 et LB2 :

1. Checklist de configuration identique :
   
   ┌──────────────────────────────────────────────────┐
   │                    LB1        LB2                │
   ├──────────────────────────────────────────────────┤
   │ Targets (workers)  5          5                  │
   │ IPs workers        Identiques Identiques         │
   │ Service HTTP port  80→31695   80→31695          │
   │ Health check port  31695      31695             │
   │ Health check path  /healthz   /healthz          │
   │ Réseau privé       Attaché    Attaché           │
   └──────────────────────────────────────────────────┘

2. Vérifier périodiquement :
   
   # Lancer ce script chaque jour
   ./15_test_dual_loadbalancers.sh
   
   # Vérifier les targets sont "Healthy" sur les 2 LBs
   https://console.hetzner.cloud/ → Load Balancers

3. En cas de changement (ajout worker, changement port) :
   
   ⚠️  TOUJOURS appliquer le changement sur LES DEUX LBs
   
   Exemple : Ajouter k3s-worker-06
   → Ajouter dans LB1 : 10.0.0.115
   → Ajouter dans LB2 : 10.0.0.115

4. Test régulier :
   
   # Test quotidien automatique
   crontab -e
   
   # Ajouter cette ligne :
   0 */6 * * * /opt/keybuzz-installer/scripts/10_K3s_HA_Apps_Stack/15_test_dual_loadbalancers.sh > /var/log/lb-health-check.log 2>&1

MAINTENANCE

echo ""
