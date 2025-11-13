#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Test Health Checks (simulation Load Balancer)                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)

echo ""
echo "Configuration détectée :"
echo "  NodePort HTTP : $HTTP_NODEPORT"
echo "  Path health   : /healthz"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Test Health Check sur chaque worker ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test GET http://<worker>:$HTTP_NODEPORT/healthz"
echo "(C'est exactement ce que fait le Load Balancer Hetzner)"
echo ""

HEALTHY=0
UNHEALTHY=0

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "→ $worker ($ip)"
    echo ""
    
    # Test avec timeout comme le LB
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 \
        "http://$ip:$HTTP_NODEPORT/healthz" 2>/dev/null)
    
    echo -n "  HTTP Status : $response "
    
    if [ "$response" = "200" ]; then
        echo -e "[$OK]"
        ((HEALTHY++))
        
        # Vérifier le body
        body=$(curl -s --connect-timeout 3 --max-time 10 "http://$ip:$HTTP_NODEPORT/healthz" 2>/dev/null)
        echo "  Body        : $body"
        
    elif [ "$response" = "000" ] || [ -z "$response" ]; then
        echo -e "[$KO] - TIMEOUT"
        ((UNHEALTHY++))
        echo "  Problème    : Le worker ne répond pas"
        echo "  Cause       : UFW bloque OU service down OU port incorrect"
        
    else
        echo -e "[$KO] - Code HTTP inattendu"
        ((UNHEALTHY++))
        echo "  Attendu     : HTTP 200"
        echo "  Reçu        : HTTP $response"
    fi
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "Résultat : $HEALTHY/$((HEALTHY+UNHEALTHY)) workers Healthy"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$HEALTHY" -eq 0 ]; then
    cat <<CRITICAL
❌ CRITIQUE : Aucun worker ne répond au health check

Le Load Balancer Hetzner va marquer tous les targets comme "Unhealthy"
et ne pourra pas router le trafic.

Causes possibles :

1. UFW bloque les connexions sur le port $HTTP_NODEPORT
   → Vérifier : ssh root@10.0.0.110 "ufw status | grep $HTTP_NODEPORT"
   → Corriger : ufw allow $HTTP_NODEPORT/tcp comment "Ingress NodePort"

2. Ingress NGINX pods non démarrés
   → Vérifier : kubectl get pods -n ingress-nginx
   → Corriger : kubectl rollout restart daemonset -n ingress-nginx ingress-nginx-controller

3. Port NodePort incorrect
   → Vérifier : kubectl get svc -n ingress-nginx ingress-nginx-controller
   → Le "NodePort" doit correspondre au Destination Port du LB

CRITICAL

elif [ "$HEALTHY" -lt 3 ]; then
    cat <<WARNING
⚠️  WARNING : Moins de 3 workers Healthy

Le Load Balancer fonctionnera mais avec une capacité réduite.
Il est recommandé d'avoir au moins 3 workers healthy pour la HA.

Investiguer les workers qui échouent pour identifier le problème.

WARNING

else
    cat <<SUCCESS
✅ OK : $HEALTHY workers Healthy

Le Load Balancer Hetzner devrait marquer ces targets comme "Healthy"
et router le trafic correctement.

Si le Load Balancer affiche toujours "Unhealthy" dans la console,
vérifier la configuration du Health Check :

Hetzner Console → Load Balancers → lb-keybuzz-1 → Health Checks :
  - Protocol : HTTP
  - Port     : $HTTP_NODEPORT (même que NodePort K3s)
  - Path     : /healthz
  - Interval : 15 seconds
  - Timeout  : 10 seconds
  - Retries  : 3
  - HTTP Status Codes : 200

SUCCESS
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test routes Ingress via Host header ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Prendre un worker qui marche
WORKING_WORKER_IP=""
for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 \
        "http://$ip:$HTTP_NODEPORT/healthz" 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        WORKING_WORKER_IP="$ip"
        break
    fi
done

if [ -z "$WORKING_WORKER_IP" ]; then
    echo "❌ Aucun worker disponible pour tester les routes Ingress"
else
    echo "Test des routes Ingress via $WORKING_WORKER_IP:"
    echo ""
    
    DOMAINS=("n8n.keybuzz.io" "chat.keybuzz.io" "llm.keybuzz.io" "qdrant.keybuzz.io" "superset.keybuzz.io")
    
    for domain in "${DOMAINS[@]}"; do
        echo -n "  $domain ... "
        
        response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 \
            -H "Host: $domain" "http://$WORKING_WORKER_IP:$HTTP_NODEPORT/" 2>/dev/null)
        
        case "$response" in
            200|302)
                echo -e "$OK (HTTP $response - App fonctionne)"
                ;;
            404)
                echo -e "$WARN (HTTP $response - Ingress route manquante)"
                ;;
            503)
                echo -e "$WARN (HTTP $response - Backend indisponible)"
                ;;
            000|"")
                echo -e "$KO (Timeout - Problème backend)"
                ;;
            *)
                echo -e "$WARN (HTTP $response)"
                ;;
        esac
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Vérification configuration Ingress NGINX ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "État des pods Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pods -n ingress-nginx -o wide" 2>/dev/null

echo ""
echo "Service Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller" 2>/dev/null

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSUMÉ POUR HETZNER CONSOLE ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<HETZNER_CONFIG

Pour configurer le Load Balancer Hetzner : https://console.hetzner.cloud/

┌─────────────────────────────────────────────────────────────────┐
│ SERVICES                                                         │
├─────────────────────────────────────────────────────────────────┤
│ HTTP Service :                                                   │
│   Listen Port      : 80                                          │
│   Destination Port : $HTTP_NODEPORT                                         │
│   Protocol         : HTTP                                        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ HEALTH CHECK                                                     │
├─────────────────────────────────────────────────────────────────┤
│   Protocol         : HTTP                                        │
│   Port             : $HTTP_NODEPORT                                         │
│   Path             : /healthz                                    │
│   Interval         : 15 seconds                                  │
│   Timeout          : 10 seconds                                  │
│   Retries          : 3                                           │
│   HTTP Status      : 200                                         │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ TARGETS (IPs PRIVÉES)                                           │
├─────────────────────────────────────────────────────────────────┤
HETZNER_CONFIG

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    # Tester si healthy
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 \
        "http://$ip:$HTTP_NODEPORT/healthz" 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        status="✅ Healthy"
    else
        status="❌ Unhealthy"
    fi
    
    printf "│   %-20s : %-15s %-15s │\n" "$worker" "$ip" "$status"
done

cat <<END_CONFIG
└─────────────────────────────────────────────────────────────────┘

END_CONFIG

echo ""
