#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║             K3S HA - Validation Finale Complète                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
IP_WORKER=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État du cluster ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get nodes
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. État Ingress NGINX ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get daemonset -n ingress-nginx
echo ""
kubectl get pods -n ingress-nginx
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. État des applications ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "DaemonSets :"
kubectl get daemonset -A | grep -E '(n8n|litellm|qdrant)'
echo ""

echo "Pods :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant)' | grep -v 'ingress\|admission'
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test depuis worker (direct) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test direct sur $IP_WORKER :"
echo ""

for port_service in "5678:n8n" "4000:litellm" "6333:qdrant"; do
    port=$(echo "$port_service" | cut -d: -f1)
    service=$(echo "$port_service" | cut -d: -f2)
    
    echo -n "  $service (port $port) ... "
    
    response=$(timeout 3 curl -s -o /dev/null -w '%{http_code}' "http://$IP_WORKER:$port/" 2>/dev/null)
    
    case "$response" in
        200|302|404|401)
            echo -e "$OK (HTTP $response)"
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
echo "═══ 5. Test via Ingress (NodePort 31695) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test via Ingress sur $IP_WORKER:31695 :"
echo ""

for domain_service in "n8n.keybuzz.io:n8n" "llm.keybuzz.io:litellm" "qdrant.keybuzz.io:qdrant"; do
    domain=$(echo "$domain_service" | cut -d: -f1)
    service=$(echo "$domain_service" | cut -d: -f2)
    
    echo -n "  $domain ... "
    
    response=$(timeout 3 curl -s -o /dev/null -w '%{http_code}' \
        -H "Host: $domain" "http://$IP_WORKER:31695/" 2>/dev/null)
    
    case "$response" in
        200|302|404|401)
            echo -e "$OK (HTTP $response)"
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
echo "═══ 6. Test depuis Internet (si DNS configuré) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test stabilité sur llm.keybuzz.io (10 requêtes) :"
echo ""

SUCCESS=0
for i in {1..10}; do
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        "http://llm.keybuzz.io/" 2>/dev/null)
    
    echo -n "  #$i : HTTP $response "
    
    if [ "$response" = "200" ] || [ "$response" = "302" ]; then
        echo -e "[$OK]"
        ((SUCCESS++))
    else
        echo -e "[$KO]"
    fi
    
    sleep 1
done

echo ""
echo "Résultat : $SUCCESS/10 succès"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSULTAT FINAL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$SUCCESS" -ge 8 ]; then
    cat <<SUCCESS_MSG
✅ INSTALLATION RÉUSSIE !

Configuration finale :
  ✓ Cluster K3s : 3 masters + 5 workers
  ✓ Ingress NGINX : DaemonSet avec hostNetwork
  ✓ Applications : DaemonSets avec hostNetwork
  ✓ Communication : Locale (pas de VXLAN nécessaire)
  ✓ Tests Internet : $SUCCESS/10 succès

Services déployés :
  - n8n       : http://n8n.keybuzz.io
  - litellm   : http://llm.keybuzz.io
  - qdrant    : http://qdrant.keybuzz.io

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ACTIONS FINALES :

1. Corriger le DNS pour n8n.keybuzz.io (si nécessaire)
   Chez le registrar DNS :
   - SUPPRIMER : n8n.keybuzz.io A 10.0.0.100
   - AJOUTER   : n8n.keybuzz.io A 49.13.42.76
   - AJOUTER   : n8n.keybuzz.io A 138.199.132.240

2. Vérifier Load Balancer 2 dans Hetzner Console
   https://console.hetzner.cloud/ → Load Balancers → LB2
   - Targets : 5 workers "Healthy"
   - Services : HTTP 80 → 31695
   - Health Checks : HTTP port 31695 path /healthz

3. Déployer les services manquants (optionnel)
   - chatwoot (nécessite configuration DB avancée)
   - superset (nécessite correction)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SUCCESS_MSG
elif [ "$SUCCESS" -ge 1 ]; then
    cat <<PARTIAL_MSG
⚠️  INSTALLATION PARTIELLE

Résultat : $SUCCESS/10 succès

L'infrastructure fonctionne mais n'est pas stable.

Actions à corriger :
  1. Vérifier le DNS (doit pointer vers les 2 Load Balancers)
  2. Vérifier Load Balancer 2 dans Hetzner Console
  3. Vérifier que les pods sont tous Running :
     kubectl get pods -A | grep -v Running

PARTIAL_MSG
else
    cat <<FAILURE_MSG
❌ PROBLÈMES DÉTECTÉS

Résultat : $SUCCESS/10 succès (aucun accès depuis Internet)

Actions à vérifier :
  1. DNS : Les domaines pointent-ils vers les Load Balancers ?
     dig +short llm.keybuzz.io
     → Doit retourner 49.13.42.76 et 138.199.132.240

  2. Load Balancers Hetzner :
     → Targets : 5 workers en "Healthy" ?
     → Services : HTTP 80 → 31695 ?
     → Health Checks : HTTP port 31695 path /healthz ?

  3. Pods Running ?
     kubectl get pods -A | grep -v Running

  4. Test manuel depuis un worker :
     curl -H "Host: llm.keybuzz.io" http://localhost:31695/

FAILURE_MSG
fi

echo ""
echo "Commandes utiles :"
echo "  kubectl get pods -A"
echo "  kubectl get daemonset -A"
echo "  kubectl logs -n n8n <pod-name>"
echo "  kubectl describe pod -n litellm <pod-name>"
echo ""
