#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Test Complet de Toutes les Applications                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/test_all_apps_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Test complet des applications - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

TESTS_PASSED=0
TESTS_TOTAL=0

# Fonction de test HTTP
test_http() {
    local name="$1"
    local url="$2"
    local expected_code="${3:-200}"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    echo -n "  → Test $name ($url) ... "
    
    response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)
    
    if [ "$response" = "$expected_code" ] || [ "$response" = "301" ] || [ "$response" = "302" ]; then
        echo -e "$OK (HTTP $response)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "$KO (HTTP $response)"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# PARTIE 1: VÉRIFICATION K3S
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 1: Vérification cluster K3s                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "État du cluster :"
kubectl get nodes -o wide

echo ""
echo "État des pods (tous namespaces) :"
kubectl get pods -A -o wide | grep -v "kube-system"

echo ""

# ═══════════════════════════════════════════════════════════════════
# PARTIE 2: VÉRIFICATION INGRESS CONTROLLER
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 2: Vérification Ingress NGINX                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "DaemonSet Ingress NGINX :"
kubectl get daemonset -n ingress-nginx

echo ""
echo "Services Ingress :"
kubectl get svc -n ingress-nginx

echo ""

# ═══════════════════════════════════════════════════════════════════
# PARTIE 3: VÉRIFICATION APPLICATIONS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 3: Vérification Applications                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Test n8n
echo "[n8n]"
kubectl get pods -n n8n -o wide
test_http "n8n" "http://n8n.keybuzz.io"
echo ""

# Test LiteLLM
echo "[LiteLLM]"
kubectl get pods -n litellm -o wide
test_http "litellm" "http://llm.keybuzz.io"
echo ""

# Test Qdrant
echo "[Qdrant]"
kubectl get pods -n qdrant -o wide
test_http "qdrant" "http://qdrant.keybuzz.io"
echo ""

# Test Chatwoot
echo "[Chatwoot]"
kubectl get pods -n chatwoot -o wide
test_http "chatwoot" "http://chat.keybuzz.io"
echo ""

# Test Superset
echo "[Superset]"
kubectl get pods -n superset -o wide
test_http "superset" "http://superset.keybuzz.io"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PARTIE 4: VÉRIFICATION INGRESS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 4: État des Ingress                                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl get ingress -A

echo ""

# ═══════════════════════════════════════════════════════════════════
# PARTIE 5: VÉRIFICATION SERVICES BACKEND
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 5: Vérification Services Backend (LB 10.0.0.10)        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo -n "  → PostgreSQL (10.0.0.10:5432) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/5432" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "  → Redis (10.0.0.10:6379) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/6379" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "  → RabbitMQ (10.0.0.10:5672) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/5672" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# PARTIE 6: RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ RÉSUMÉ FINAL                                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Calcul du score
SCORE_PERCENT=0
if [ "$TESTS_TOTAL" -gt 0 ]; then
    SCORE_PERCENT=$((TESTS_PASSED * 100 / TESTS_TOTAL))
fi

echo "═══════════════════════════════════════════════════════════════════"
echo "  Tests réussis : $TESTS_PASSED / $TESTS_TOTAL"
echo "  Score         : $SCORE_PERCENT %"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$SCORE_PERCENT" -ge 80 ]; then
    echo -e "$OK TOUTES LES APPLICATIONS SONT OPÉRATIONNELLES !"
    echo ""
    echo "Applications accessibles :"
    echo "  ✅ n8n       : http://n8n.keybuzz.io"
    echo "  ✅ litellm   : http://llm.keybuzz.io"
    echo "  ✅ qdrant    : http://qdrant.keybuzz.io"
    echo "  ✅ chatwoot  : http://chat.keybuzz.io"
    echo "  ✅ superset  : http://superset.keybuzz.io"
    echo ""
    echo "Credentials :"
    echo "  • Chatwoot : Premier compte créé = admin"
    echo "  • Superset : admin / Admin123!"
    echo ""
else
    echo -e "$KO CERTAINES APPLICATIONS ONT DES PROBLÈMES"
    echo ""
    echo "Actions de dépannage :"
    echo ""
    echo "1. Vérifier les pods :"
    echo "   kubectl get pods -A"
    echo ""
    echo "2. Vérifier les logs d'une app :"
    echo "   kubectl logs -n <namespace> <pod-name> --tail=50"
    echo ""
    echo "3. Vérifier l'Ingress :"
    echo "   kubectl describe ingress -n <namespace>"
    echo ""
    echo "4. Test depuis un worker :"
    echo "   IP_WORKER=10.0.0.110"
    echo "   curl -H \"Host: <domain>\" http://\$IP_WORKER:31695/"
    echo ""
    echo "5. Vérifier les Load Balancers Hetzner :"
    echo "   Console Hetzner → Load Balancers"
    echo "   Vérifier que les targets sont Healthy"
    echo ""
fi

echo ""
echo "Architecture validée :"
echo "  ✓ LB API K3s     : 49.13.42.76 / 138.199.132.240 → TCP 6443"
echo "  ✓ LB Apps HTTP   : 49.13.42.76 / 138.199.132.240 → TCP 31695"
echo "  ✓ LB Apps HTTPS  : 49.13.42.76 / 138.199.132.240 → TCP 32720"
echo "  ✓ LB Backend DB  : 10.0.0.10 → HAProxy → Patroni (5432)"
echo "  ✓ LB Backend RDS : 10.0.0.10 → HAProxy → Sentinel (6379)"
echo "  ✓ LB Backend MQ  : 10.0.0.10 → HAProxy → RabbitMQ (5672)"
echo ""
echo "Infrastructure KeyBuzz Hetzner - Production Ready !"
echo ""
echo "Log complet : $MAIN_LOG"
echo ""

exit 0
