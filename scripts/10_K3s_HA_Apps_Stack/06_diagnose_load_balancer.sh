#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       Diagnostic Load Balancer Hetzner + Ingress NGINX            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification Ingress NGINX Controller ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Service Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" kubectl get svc -n ingress-nginx

echo ""
echo "→ Pods Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" kubectl get pods -n ingress-nginx

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test des NodePorts depuis les workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# NodePorts depuis le service
HTTP_NODEPORT=31695
HTTPS_NODEPORT=32720

WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    if [ -z "$ip" ]; then
        continue
    fi
    
    echo "→ Test $worker ($ip) :"
    
    # Test HTTP NodePort
    echo -n "  HTTP :$HTTP_NODEPORT ... "
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Test HTTPS NodePort
    echo -n "  HTTPS :$HTTPS_NODEPORT ... "
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTPS_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Test curl HTTP
    echo -n "  curl http://$ip:$HTTP_NODEPORT ... "
    response=$(ssh -o StrictHostKeyChecking=no root@"$ip" "curl -s -o /dev/null -w '%{http_code}' http://localhost:$HTTP_NODEPORT/healthz --max-time 3" 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        echo -e "$OK (HTTP $response)"
    else
        echo -e "$WARN (HTTP ${response:-timeout})"
    fi
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Vérification des Ingress (routes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" kubectl get ingress -A

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test des endpoints des applications ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tester depuis un worker
WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "Test depuis k3s-worker-01 ($WORKER_IP) :"
echo ""

test_ingress() {
    local host="$1"
    local path="${2:-/}"
    
    echo -n "  $host ... "
    
    response=$(ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" \
        "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $host' http://localhost:$HTTP_NODEPORT$path --max-time 10" 2>/dev/null)
    
    if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "401" ]; then
        echo -e "$OK (HTTP $response)"
    else
        echo -e "$WARN (HTTP ${response:-timeout})"
    fi
}

test_ingress "n8n.keybuzz.io"
test_ingress "chat.keybuzz.io"
test_ingress "llm.keybuzz.io"
test_ingress "qdrant.keybuzz.io" "/collections"
test_ingress "superset.keybuzz.io"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification UFW sur les workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    if [ -z "$ip" ]; then
        continue
    fi
    
    echo "→ $worker ($ip) :"
    
    # Vérifier que le port HTTP est ouvert
    echo -n "  UFW allow $HTTP_NODEPORT ... "
    if ssh -o StrictHostKeyChecking=no root@"$ip" "ufw status | grep -q $HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$WARN (port non autorisé dans UFW)"
    fi
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Diagnostic terminé ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Problèmes potentiels :"
echo "  1. Si NodePorts KO : Ingress NGINX ne répond pas → redémarrer"
echo "  2. Si UFW KO : Ports NodePort bloqués → ouvrir les ports"
echo "  3. Si Ingress routes KO : Routes non créées → créer les Ingress"
echo ""
echo "Solutions :"
echo "  ./06_fix_load_balancer.sh"
echo ""
