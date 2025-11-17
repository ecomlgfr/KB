#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Vérification des prérequis K3s avant déploiement applications
###############################################################################

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.k3s_apps}"

# Load environment
if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${KO} Fichier $ENV_FILE introuvable!"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

###############################################################################
# CHECK KUBECTL
###############################################################################

check_kubectl() {
    log "${INFO} Vérification de kubectl..."

    if ! command -v kubectl &> /dev/null; then
        log "${KO} kubectl n'est pas installé"
        return 1
    fi

    # Export KUBECONFIG
    export KUBECONFIG="$KUBECONFIG_PATH"

    # Test connexion cluster
    if ! kubectl cluster-info &> /dev/null; then
        log "${KO} Impossible de se connecter au cluster K3s"
        log "Vérifier: export KUBECONFIG=$KUBECONFIG_PATH"
        return 1
    fi

    log "${OK} kubectl opérationnel"
    return 0
}

###############################################################################
# CHECK K3S CLUSTER
###############################################################################

check_k3s_cluster() {
    log "${INFO} Vérification du cluster K3s..."

    # Nombre de nœuds
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)

    if [[ "$total_nodes" -ne 8 ]]; then
        log "${WARN} Nombre de nœuds: $total_nodes (attendu: 8)"
    else
        log "${OK} Nombre de nœuds: $total_nodes"
    fi

    if [[ "$ready_nodes" -ne 8 ]]; then
        log "${WARN} Nœuds Ready: $ready_nodes/8"
        kubectl get nodes
    else
        log "${OK} Tous les nœuds Ready: $ready_nodes/8"
    fi

    # Vérifier les masters
    local masters=$(kubectl get nodes -l node-role.kubernetes.io/master=true --no-headers 2>/dev/null | wc -l)
    if [[ "$masters" -ne 3 ]]; then
        log "${WARN} Masters: $masters (attendu: 3)"
    else
        log "${OK} Masters: $masters"
    fi

    # Vérifier les workers
    local workers=$(kubectl get nodes -l '!node-role.kubernetes.io/master' --no-headers 2>/dev/null | wc -l)
    if [[ "$workers" -ne 5 ]]; then
        log "${WARN} Workers: $workers (attendu: 5)"
    else
        log "${OK} Workers: $workers"
    fi

    return 0
}

###############################################################################
# CHECK NETWORK CONNECTIVITY
###############################################################################

check_network() {
    log "${INFO} Vérification de la connectivité réseau..."

    # Test connexion vers lb-haproxy
    if kubectl run test-db --image=busybox --rm -it --restart=Never -- nc -zv "$DB_HOST" "$DB_PORT_WRITE" &>/dev/null; then
        log "${OK} Connexion DB (lb-haproxy:$DB_PORT_WRITE)"
    else
        log "${WARN} Connexion DB échouée (lb-haproxy:$DB_PORT_WRITE)"
    fi

    # Test Redis
    if kubectl run test-redis --image=busybox --rm -it --restart=Never -- nc -zv "$REDIS_HOST" "$REDIS_PORT" &>/dev/null; then
        log "${OK} Connexion Redis (lb-haproxy:$REDIS_PORT)"
    else
        log "${WARN} Connexion Redis échouée (lb-haproxy:$REDIS_PORT)"
    fi

    # Test RabbitMQ
    if kubectl run test-rabbitmq --image=busybox --rm -it --restart=Never -- nc -zv "$RABBITMQ_HOST" "$RABBITMQ_PORT" &>/dev/null; then
        log "${OK} Connexion RabbitMQ (lb-haproxy:$RABBITMQ_PORT)"
    else
        log "${WARN} Connexion RabbitMQ échouée (lb-haproxy:$RABBITMQ_PORT)"
    fi

    return 0
}

###############################################################################
# CHECK UFW RULES
###############################################################################

check_ufw_rules() {
    log "${INFO} Vérification des règles UFW sur les workers..."

    # Check via SSH sur un worker
    local worker_ip="$K3S_WORKER_01_IP"

    if ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${worker_ip}" "ufw status | grep -q $INGRESS_HTTP_NODEPORT" 2>/dev/null; then
        log "${OK} UFW: NodePort HTTP $INGRESS_HTTP_NODEPORT ouvert"
    else
        log "${WARN} UFW: NodePort HTTP $INGRESS_HTTP_NODEPORT peut ne pas être ouvert"
    fi

    if ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${worker_ip}" "ufw status | grep -q $INGRESS_HTTPS_NODEPORT" 2>/dev/null; then
        log "${OK} UFW: NodePort HTTPS $INGRESS_HTTPS_NODEPORT ouvert"
    else
        log "${WARN} UFW: NodePort HTTPS $INGRESS_HTTPS_NODEPORT peut ne pas être ouvert"
    fi

    return 0
}

###############################################################################
# CHECK EXISTING DEPLOYMENTS
###############################################################################

check_existing_deployments() {
    log "${INFO} Vérification des déploiements existants..."

    # List namespaces
    local namespaces=$(kubectl get namespaces --no-headers 2>/dev/null | awk '{print $1}')

    log "Namespaces existants:"
    for ns in $namespaces; do
        local pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        if [[ "$pods" -gt 0 ]]; then
            echo "  - $ns: $pods pods"
        fi
    done

    # Check if Ingress NGINX already exists
    if kubectl get namespace "$INGRESS_NAMESPACE" &>/dev/null; then
        local ingress_pods=$(kubectl get pods -n "$INGRESS_NAMESPACE" --no-headers 2>/dev/null | wc -l)
        if [[ "$ingress_pods" -gt 0 ]]; then
            log "${WARN} Ingress NGINX déjà déployé ($ingress_pods pods)"
        fi
    fi

    # Check cert-manager
    if kubectl get namespace cert-manager &>/dev/null; then
        local cm_pods=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | wc -l)
        if [[ "$cm_pods" -gt 0 ]]; then
            log "${WARN} cert-manager déjà déployé ($cm_pods pods)"
        fi
    fi

    return 0
}

###############################################################################
# DISPLAY SUMMARY
###############################################################################

display_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "          VÉRIFICATION PRÉREQUIS K3S - RÉSUMÉ"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    log "${OK} Cluster K3s opérationnel"
    log "${OK} kubectl configuré"
    log "${INFO} Prêt pour le déploiement des applications"

    echo ""
    echo "Configuration:"
    echo "  • Ingress HTTP NodePort: $INGRESS_HTTP_NODEPORT"
    echo "  • Ingress HTTPS NodePort: $INGRESS_HTTPS_NODEPORT"
    echo "  • Database: $DB_HOST:$DB_PORT_WRITE"
    echo "  • Redis: $REDIS_HOST:$REDIS_PORT"
    echo "  • RabbitMQ: $RABBITMQ_HOST:$RABBITMQ_PORT"
    echo ""
    echo "Applications à déployer:"
    echo "  1. Ingress NGINX (DaemonSet)"
    echo "  2. cert-manager"
    echo "  3. n8n ($N8N_DOMAIN)"
    echo "  4. LiteLLM ($LITELLM_DOMAIN)"
    echo "  5. Qdrant ($QDRANT_DOMAIN)"
    echo "  6. Chatwoot ($CHATWOOT_DOMAIN)"
    echo "  7. Superset ($SUPERSET_DOMAIN)"
    echo "  8. ERPNext ($ERPNEXT_DOMAIN)"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
}

###############################################################################
# MAIN
###############################################################################

main() {
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║  VÉRIFICATION PRÉREQUIS K3S - DÉPLOIEMENT APPLICATIONS       ║"
    log "╚═══════════════════════════════════════════════════════════════╝"

    check_kubectl
    check_k3s_cluster
    check_network
    check_ufw_rules
    check_existing_deployments

    display_summary

    log "${OK} Vérification terminée"
}

main "$@"
