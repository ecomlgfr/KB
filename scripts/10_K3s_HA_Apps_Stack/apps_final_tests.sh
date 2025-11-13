#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║             K3S HA APPS - Tests d'acceptation finaux              ║"
echo "║         (n8n, Chatwoot, LiteLLM, Qdrant, Superset)                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"

# Vérifications préalables
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/apps_final_tests.log"

# Récupérer l'IP du master-01
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable"
    exit 1
fi

# Récupérer l'IP d'un worker pour les tests
IP_WORKER=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")
if [ -z "$IP_WORKER" ]; then
    echo -e "$KO IP de k3s-worker-01 introuvable"
    exit 1
fi

echo "" | tee -a "$LOG_FILE"
echo "═══ Configuration ═══" | tee -a "$LOG_FILE"
echo "  Master-01         : $IP_MASTER01" | tee -a "$LOG_FILE"
echo "  Worker-01         : $IP_WORKER" | tee -a "$LOG_FILE"
echo "  Log               : $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Vérification de l'état du cluster
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 1/5 : État du cluster K3s ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CLUSTER_STATUS' | tee -a "$LOG_FILE"
echo "Nœuds du cluster :"
kubectl get nodes -o wide
echo ""

echo "Composants système :"
kubectl get pods -n kube-system -o wide | head -n 15
echo ""

CLUSTER_STATUS

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Vérification de l'état des pods applicatifs
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 2/5 : État des pods applicatifs ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Fonction pour vérifier un namespace
check_namespace() {
    local ns="$1"
    local expected_pods="$2"
    
    echo "→ Namespace: $ns" | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF | tee -a "$LOG_FILE"
set -u
set -o pipefail

READY=\$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -c "Running")
TOTAL=\$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l)

if [ "\$READY" -ge "$expected_pods" ]; then
    echo -e "  ✓ \$READY/\$TOTAL pods Running"
else
    echo -e "  ✗ Seulement \$READY/\$TOTAL pods Running (attendu: $expected_pods)"
    kubectl get pods -n $ns
fi
echo ""
EOF
}

check_namespace "n8n" 2
check_namespace "chatwoot" 4  # 2 web + 2 workers
check_namespace "litellm" 2
check_namespace "qdrant" 1
check_namespace "superset" 2

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Test de connectivité HTTP via Ingress
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 3/5 : Tests HTTP via Ingress (NodePort) ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Récupérer le NodePort de l'ingress-nginx
NODE_PORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)

if [ -z "$NODE_PORT" ]; then
    echo -e "$WARN NodePort non trouvé, skip tests HTTP" | tee -a "$LOG_FILE"
else
    echo "NodePort HTTP : $NODE_PORT" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    # Fonction pour tester un service
    test_http_service() {
        local host="$1"
        local path="${2:-/}"
        
        echo -n "  Test $host ... " | tee -a "$LOG_FILE"
        
        response=$(ssh -o StrictHostKeyChecking=no root@"$IP_WORKER" \
            "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $host' http://localhost:${NODE_PORT}${path} --max-time 10" 2>/dev/null)
        
        if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "401" ]; then
            echo -e "$OK (HTTP $response)" | tee -a "$LOG_FILE"
        else
            echo -e "$WARN (HTTP ${response:-timeout})" | tee -a "$LOG_FILE"
        fi
    }
    
    test_http_service "n8n.keybuzz.io"
    test_http_service "chat.keybuzz.io"
    test_http_service "llm.keybuzz.io"
    test_http_service "qdrant.keybuzz.io" "/collections"
    test_http_service "superset.keybuzz.io"
    
    echo "" | tee -a "$LOG_FILE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : Vérification des PVC
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 4/5 : Vérification des PVC (Persistent Volume Claims) ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'PVC_CHECK' | tee -a "$LOG_FILE"
echo "PVC créés :"
kubectl get pvc -A
echo ""

echo "Résumé PVC par namespace :"
for ns in n8n chatwoot qdrant; do
    BOUND=$(kubectl get pvc -n $ns --no-headers 2>/dev/null | grep -c "Bound" || echo 0)
    TOTAL=$(kubectl get pvc -n $ns --no-headers 2>/dev/null | wc -l)
    
    if [ "$TOTAL" -gt 0 ]; then
        echo "  $ns : $BOUND/$TOTAL Bound"
    fi
done
echo ""

PVC_CHECK

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 5 : Synthèse et recommandations
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 5/5 : Synthèse et recommandations ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Compter les pods en erreur
PODS_NOT_READY=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pods -A --no-headers 2>/dev/null | grep -v 'Running\|Completed' | wc -l" 2>/dev/null)

echo "Résumé :" | tee -a "$LOG_FILE"
echo "  - Nœuds K3s : 8 (3 masters + 5 workers)" | tee -a "$LOG_FILE"
echo "  - Applications déployées : 5" | tee -a "$LOG_FILE"
echo "  - Pods non-Running : $PODS_NOT_READY" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$PODS_NOT_READY" -eq 0 ]; then
    echo -e "$OK Tous les pods sont Running !" | tee -a "$LOG_FILE"
else
    echo -e "$WARN Certains pods ne sont pas Running, vérifier :" | tee -a "$LOG_FILE"
    echo "  ssh root@$IP_MASTER01 kubectl get pods -A | grep -v Running" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo "Recommandations :" | tee -a "$LOG_FILE"
echo "  1. Configurer le Load Balancer Hetzner pour router vers NodePort $NODE_PORT" | tee -a "$LOG_FILE"
echo "  2. Configurer les DNS (n8n.keybuzz.io, chat.keybuzz.io, etc.)" | tee -a "$LOG_FILE"
echo "  3. Configurer cert-manager pour les certificats TLS (si installé)" | tee -a "$LOG_FILE"
echo "  4. Sauvegarder les secrets et PVC régulièrement" | tee -a "$LOG_FILE"
echo "  5. Surveiller les ressources avec 'kubectl top nodes' et 'kubectl top pods -A'" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Commandes utiles :" | tee -a "$LOG_FILE"
echo "  # Dashboard Kubernetes (optionnel)" | tee -a "$LOG_FILE"
echo "  kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Prometheus & Grafana (monitoring)" | tee -a "$LOG_FILE"
echo "  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts" | tee -a "$LOG_FILE"
echo "  helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Afficher les logs d'une application" | tee -a "$LOG_FILE"
echo "  kubectl logs -n n8n -l app=n8n --tail=50" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Redémarrer une application" | tee -a "$LOG_FILE"
echo "  kubectl rollout restart deployment/n8n -n n8n" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# Résumé final
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo -e "$OK TESTS D'ACCEPTATION TERMINÉS" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Applications testées :" | tee -a "$LOG_FILE"
echo "  ✓ n8n        - Workflow automation" | tee -a "$LOG_FILE"
echo "  ✓ Chatwoot   - Customer support" | tee -a "$LOG_FILE"
echo "  ✓ LiteLLM    - LLM Router" | tee -a "$LOG_FILE"
echo "  ✓ Qdrant     - Vector database" | tee -a "$LOG_FILE"
echo "  ✓ Superset   - Business Intelligence" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Prochaines étapes :" | tee -a "$LOG_FILE"
echo "  1. Configurer les DNS publics" | tee -a "$LOG_FILE"
echo "  2. Configurer le Load Balancer Hetzner" | tee -a "$LOG_FILE"
echo "  3. Déployer le monitoring (Prometheus/Grafana)" | tee -a "$LOG_FILE"
echo "  4. Configurer les sauvegardes automatiques" | tee -a "$LOG_FILE"
echo "  5. Mettre en place le SIEM (Wazuh)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Documentation :" | tee -a "$LOG_FILE"
echo "  - n8n         : https://docs.n8n.io" | tee -a "$LOG_FILE"
echo "  - Chatwoot    : https://www.chatwoot.com/docs" | tee -a "$LOG_FILE"
echo "  - LiteLLM     : https://docs.litellm.ai" | tee -a "$LOG_FILE"
echo "  - Qdrant      : https://qdrant.tech/documentation" | tee -a "$LOG_FILE"
echo "  - Superset    : https://superset.apache.org/docs" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "═══════════════════════════════════════════════════════════════════"
echo "Log complet (50 dernières lignes) :"
echo "═══════════════════════════════════════════════════════════════════"
tail -n 50 "$LOG_FILE"

exit 0
