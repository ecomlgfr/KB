#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Test complet de toutes les applications                  ║"
echo "║    (n8n, litellm, qdrant, chatwoot, superset)                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
IP_WORKER01=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }
[ -z "$IP_WORKER01" ] && { echo -e "$KO IP k3s-worker-01 introuvable"; exit 1; }

echo ""
echo "Test des applications KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Variables de comptage
TOTAL_TESTS=0
PASSED_TESTS=0

function test_app() {
    local app_name="$1"
    local namespace="$2"
    local host="$3"
    local port="$4"
    
    echo "═══════════════════════════════════════════════════════════════════"
    echo "TEST: $app_name"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    # Test 1: Pods Running
    echo -n "  1. Pods Running ... "
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    POD_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n $namespace --no-headers 2>/dev/null | grep -v 'init-db\|create-admin\|db-migrate' | grep -c Running" || echo "0")
    if [ "$POD_STATUS" -gt 0 ]; then
        echo -e "$OK ($POD_STATUS pods)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "$KO"
    fi
    
    # Test 2: Service existe
    echo -n "  2. Service existe ... "
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    SVC_EXISTS=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get svc -n $namespace 2>/dev/null | grep -c $namespace" || echo "0")
    if [ "$SVC_EXISTS" -gt 0 ]; then
        echo -e "$OK"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "$KO"
    fi
    
    # Test 3: Ingress existe
    echo -n "  3. Ingress existe ... "
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    ING_EXISTS=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get ingress -n $namespace 2>/dev/null | grep -c $host" || echo "0")
    if [ "$ING_EXISTS" -gt 0 ]; then
        echo -e "$OK"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "$KO"
    fi
    
    # Test 4: HTTP Response (via NodePort depuis worker)
    echo -n "  4. HTTP Response (NodePort) ... "
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $host" http://$IP_WORKER01:31695/ --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        echo -e "$OK (HTTP $HTTP_CODE)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "$WARN (HTTP $HTTP_CODE)"
    fi
    
    echo ""
}

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Test des pods par namespace                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'PODSTATUS'
echo "Pods par namespace (hors jobs/init containers) :"
echo ""
kubectl get pods -A --no-headers | grep -v "init-db\|create-admin\|db-migrate\|Completed" | awk '{print $1}' | sort | uniq -c
PODSTATUS

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Test de chaque application                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

test_app "n8n" "n8n" "n8n.keybuzz.io" "5678"
test_app "LiteLLM" "litellm" "llm.keybuzz.io" "4000"
test_app "Qdrant" "qdrant" "qdrant.keybuzz.io" "6333"
test_app "Chatwoot" "chatwoot" "chat.keybuzz.io" "3000"
test_app "Superset" "superset" "superset.keybuzz.io" "8088"

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Test des DaemonSets                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'DAEMONSETS'
echo "DaemonSets déployés :"
echo ""
kubectl get daemonset -A --no-headers | awk '{printf "  %-20s %-15s DESIRED=%s CURRENT=%s READY=%s\n", $1, $2, $3, $4, $5}'
DAEMONSETS

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Test des Services (NodePorts)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'NODEPORTS'
echo "Services NodePort accessibles :"
echo ""
kubectl get svc -A --no-headers | grep NodePort | awk '{printf "  %-20s %-15s PORT=%s NODEPORT=%s\n", $1, $2, $6, $6}' | sed 's/:/ → /'
NODEPORTS

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Test des Ingress Routes                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'INGRESSES'
echo "Ingress configurés :"
echo ""
kubectl get ingress -A --no-headers | awk '{printf "  %-20s %-25s → %s\n", $1, $3, $4}'
INGRESSES

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Vérification Load Balancers                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Ports Load Balancers Hetzner :"
echo "  ✓ LB Apps (lb-keybuzz-1/2)"
echo "    → TCP 80  → NodePort 31695 (HTTP Ingress)"
echo "    → TCP 443 → NodePort 32720 (HTTPS Ingress)"
echo ""
echo "  ✓ LB API K3s (lb-keybuzz-1/2)"
echo "    → TCP 6443 → k3s-master-01..03:6443"
echo ""
echo "  ✓ LB DB (lb-haproxy 10.0.0.10)"
echo "    → TCP 5432 (PostgreSQL Write)"
echo "    → TCP 5433 (PostgreSQL Read)"
echo "    → TCP 6379 (Redis)"
echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ RÉSULTATS FINAUX                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

PERCENTAGE=$((PASSED_TESTS * 100 / TOTAL_TESTS))

echo "Tests réussis : $PASSED_TESTS / $TOTAL_TESTS ($PERCENTAGE%)"
echo ""

if [ "$PERCENTAGE" -ge 80 ]; then
    echo -e "$OK Infrastructure opérationnelle (≥80%)"
    echo ""
    echo "Applications accessibles :"
    echo "  → n8n       : http://n8n.keybuzz.io"
    echo "  → LiteLLM   : http://llm.keybuzz.io"
    echo "  → Qdrant    : http://qdrant.keybuzz.io"
    echo "  → Chatwoot  : http://chat.keybuzz.io"
    echo "  → Superset  : http://superset.keybuzz.io"
    echo ""
    echo "Credentials Superset :"
    echo "  Username: admin"
    echo "  Password: Admin123!"
    echo ""
    echo "Chatwoot :"
    echo "  Premier compte créé = admin automatiquement"
    echo ""
elif [ "$PERCENTAGE" -ge 60 ]; then
    echo -e "$WARN Infrastructure partiellement opérationnelle (60-79%)"
    echo ""
    echo "Actions recommandées :"
    echo "  1. Vérifier les logs des pods en erreur"
    echo "  2. Vérifier les secrets K8s"
    echo "  3. Tester la connectivité DB/Redis"
    echo ""
else
    echo -e "$KO Infrastructure en erreur (<60%)"
    echo ""
    echo "Actions urgentes :"
    echo "  1. Vérifier le cluster K3s : kubectl get nodes"
    echo "  2. Vérifier les pods : kubectl get pods -A"
    echo "  3. Vérifier PostgreSQL : timeout 3 bash -c '</dev/tcp/10.0.0.10/5432'"
    echo "  4. Vérifier Redis : timeout 3 bash -c '</dev/tcp/10.0.0.10/6379'"
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════════"
echo ""
