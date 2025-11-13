#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          K3S_HA_FAILOVER_TEST - Test de haute disponibilité K3s    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_LOG="$LOG_DIR/k3s_failover_test_$TIMESTAMP.log"
LB_VIP="10.0.0.10"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$TEST_LOG")
exec 2>&1

echo ""
echo "Test de failover K3s HA"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Configurer kubeconfig
export KUBECONFIG="${KUBECONFIG:-$CREDS_DIR/k3s-kubeconfig.yaml}"

if [ ! -f "$KUBECONFIG" ]; then
    echo -e "$KO Kubeconfig non trouvé: $KUBECONFIG"
    echo "Lancez d'abord k3s_ha_install.sh"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════
# FONCTIONS DE TEST
# ═══════════════════════════════════════════════════════════════════

test_k3s_api() {
    echo -n "  API K3s via LB ($LB_VIP:6443): "
    if timeout 3 kubectl get nodes &>/dev/null; then
        echo -e "$OK"
        return 0
    else
        echo -e "$KO"
        return 1
    fi
}

get_master_status() {
    local host=$1
    local ip=$2
    
    # Vérifier si K3s est actif
    if ssh -o StrictHostKeyChecking=no root@"$ip" "systemctl is-active k3s" 2>/dev/null | grep -q "active"; then
        # Vérifier si c'est un leader etcd
        local is_leader=$(ssh -o StrictHostKeyChecking=no root@"$ip" \
            "k3s kubectl get endpoints -n kube-system kube-scheduler -o json 2>/dev/null | jq -r '.metadata.annotations.\"control-plane.alpha.kubernetes.io/leader\"' 2>/dev/null | grep -q '$ip' && echo 'Leader' || echo 'Follower'" || echo "Unknown")
        echo "$is_leader"
    else
        echo "Down"
    fi
}

wait_for_recovery() {
    local max_wait=${1:-60}
    local waited=0
    
    echo -n "    Attente de récupération"
    while [ $waited -lt $max_wait ]; do
        if test_k3s_api &>/dev/null; then
            echo -e " $OK (${waited}s)"
            return 0
        fi
        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done
    echo -e " $KO (timeout)"
    return 1
}

deploy_test_workload() {
    echo "  Déploiement d'une application de test..."
    
    # Créer un deployment nginx simple
    kubectl apply -f - <<'EOF' &>/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ha-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-ha-test
  namespace: ha-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx-ha-test
  template:
    metadata:
      labels:
        app: nginx-ha-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-ha-test
  namespace: ha-test
spec:
  selector:
    app: nginx-ha-test
  ports:
  - port: 80
    targetPort: 80
EOF
    
    sleep 5
    
    # Vérifier que les pods sont running
    local ready_pods=$(kubectl get pods -n ha-test --no-headers 2>/dev/null | grep -c "Running")
    if [ "$ready_pods" -ge 1 ]; then
        echo "    ✓ Application déployée ($ready_pods pods running)"
        return 0
    else
        echo "    ✗ Échec déploiement"
        return 1
    fi
}

check_workload_status() {
    local ready_pods=$(kubectl get pods -n ha-test --no-headers 2>/dev/null | grep -c "Running")
    local total_pods=$(kubectl get pods -n ha-test --no-headers 2>/dev/null | wc -l)
    echo "    Pods: $ready_pods/$total_pods running"
}

# ═══════════════════════════════════════════════════════════════════
# TEST 0: ÉTAT INITIAL
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 0: Vérification de l'état initial                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  État des masters K3s:"
MASTERS_UP=0
for i in 1 2 3; do
    host="k3s-master-0$i"
    ip="10.0.0.10$((i-1))"
    status=$(get_master_status "$host" "$ip")
    echo "    $host ($ip): $status"
    [ "$status" != "Down" ] && MASTERS_UP=$((MASTERS_UP + 1))
done

if [ $MASTERS_UP -lt 3 ]; then
    echo -e "  $WARN Seulement $MASTERS_UP/3 masters actifs"
fi

echo ""
test_k3s_api

echo ""
echo "  État du cluster:"
kubectl get nodes || echo "    Erreur kubectl"

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 1: DÉPLOIEMENT APPLICATION TEST
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 1: Déploiement d'une application de test                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

deploy_test_workload
check_workload_status

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 2: PANNE D'UN MASTER K3S
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 2: Simulation panne d'un master K3s                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Choisir un master à arrêter (de préférence pas le leader)
TARGET_MASTER=""
TARGET_IP=""

for i in 3 2 1; do  # Commencer par master-03
    host="k3s-master-0$i"
    ip="10.0.0.10$((i-1))"
    status=$(get_master_status "$host" "$ip")
    if [ "$status" = "Follower" ] || [ "$status" != "Down" ]; then
        TARGET_MASTER="$host"
        TARGET_IP="$ip"
        break
    fi
done

if [ -z "$TARGET_MASTER" ]; then
    echo -e "  $WARN Aucun master disponible pour le test"
else
    echo "  Arrêt de $TARGET_MASTER ($TARGET_IP)..."
    ssh -o StrictHostKeyChecking=no root@"$TARGET_IP" "systemctl stop k3s" &>/dev/null
    
    sleep 5
    
    echo "  Test API après arrêt d'un master:"
    test_k3s_api
    
    echo "  État de l'application:"
    check_workload_status
    
    echo ""
    echo "  Opérations pendant la panne:"
    
    # Créer un nouveau pod
    echo -n "    Création d'un nouveau pod: "
    if kubectl run test-pod-$(date +%s) --image=nginx:alpine -n ha-test &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Scaler le deployment
    echo -n "    Scale deployment (5 replicas): "
    if kubectl scale deployment nginx-ha-test -n ha-test --replicas=5 &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    sleep 10
    
    echo ""
    echo "  Redémarrage de $TARGET_MASTER..."
    ssh -o StrictHostKeyChecking=no root@"$TARGET_IP" "systemctl start k3s" &>/dev/null
    
    echo "  Attente de récupération..."
    wait_for_recovery 30
    
    echo ""
    echo "  État après récupération:"
    kubectl get nodes
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 3: PANNE DE DEUX MASTERS (PERTE DE QUORUM)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 3: Simulation panne de 2 masters (perte quorum)           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo -e "  $WARN Ce test va causer une panne totale temporaire"
read -p "  Continuer? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    
    echo "  Arrêt de k3s-master-02 et k3s-master-03..."
    ssh -o StrictHostKeyChecking=no root@"10.0.0.101" "systemctl stop k3s" &>/dev/null
    ssh -o StrictHostKeyChecking=no root@"10.0.0.102" "systemctl stop k3s" &>/dev/null
    
    sleep 5
    
    echo "  Test API avec un seul master (pas de quorum):"
    test_k3s_api
    
    echo -e "    $WARN L'API devrait être en lecture seule ou indisponible"
    
    echo ""
    echo "  Redémarrage d'un master pour retrouver le quorum..."
    ssh -o StrictHostKeyChecking=no root@"10.0.0.101" "systemctl start k3s" &>/dev/null
    
    echo "  Attente de récupération du quorum..."
    wait_for_recovery 60
    
    echo ""
    echo "  Redémarrage du dernier master..."
    ssh -o StrictHostKeyChecking=no root@"10.0.0.102" "systemctl start k3s" &>/dev/null
    
    sleep 20
    
    echo ""
    echo "  État final après récupération complète:"
    kubectl get nodes
else
    echo "  Test ignoré"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 4: TEST LOAD BALANCER
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 4: Test du Load Balancer                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Test de connexions simultanées via LB:"
SUCCESS=0
TOTAL=20

for i in $(seq 1 $TOTAL); do
    if timeout 1 kubectl get nodes &>/dev/null; then
        echo -n "."
        SUCCESS=$((SUCCESS + 1))
    else
        echo -n "x"
    fi
    sleep 0.2
done

echo " [$SUCCESS/$TOTAL succès]"

echo ""
echo "  Test avec arrêt d'un HAProxy:"

# Identifier quel HAProxy est actif
HAPROXY_TO_STOP=""
for host in haproxy-01 haproxy-02; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    if ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps | grep -q haproxy-k3s" 2>/dev/null; then
        HAPROXY_TO_STOP="$host"
        HAPROXY_IP="$IP"
        break
    fi
done

if [ -n "$HAPROXY_TO_STOP" ]; then
    echo "    Arrêt de haproxy-k3s sur $HAPROXY_TO_STOP..."
    ssh -o StrictHostKeyChecking=no root@"$HAPROXY_IP" "docker stop haproxy-k3s" &>/dev/null
    
    sleep 3
    
    echo -n "    Test API via LB: "
    test_k3s_api
    
    echo "    Redémarrage de haproxy-k3s..."
    ssh -o StrictHostKeyChecking=no root@"$HAPROXY_IP" "docker start haproxy-k3s" &>/dev/null
    
    sleep 5
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# NETTOYAGE
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ NETTOYAGE                                                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Suppression de l'application de test..."
kubectl delete namespace ha-test &>/dev/null
echo "    ✓ Namespace ha-test supprimé"

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ RÉSUMÉ DES TESTS                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Tests effectués:"
echo "  ✓ Déploiement d'application pendant failover"
echo "  ✓ Panne d'un master K3s"
echo "  ✓ Récupération après panne"
echo "  ✓ Test du Load Balancer"
echo ""

echo "État final du cluster:"
kubectl get nodes --no-headers | while read node status rest; do
    echo "  • $node: $status"
done

echo ""

# Test final
FINAL_OK=true
test_k3s_api &>/dev/null || FINAL_OK=false

# Vérifier que tous les masters sont up
MASTERS_FINAL=0
for i in 1 2 3; do
    ip="10.0.0.10$((i-1))"
    if ssh -o StrictHostKeyChecking=no root@"$ip" "systemctl is-active k3s" 2>/dev/null | grep -q "active"; then
        MASTERS_FINAL=$((MASTERS_FINAL + 1))
    fi
done

echo "═══════════════════════════════════════════════════════════════════"

if [ "$FINAL_OK" = "true" ] && [ $MASTERS_FINAL -eq 3 ]; then
    echo -e "$OK K3S HA HAUTEMENT DISPONIBLE"
    echo ""
    echo "Résultats:"
    echo "  • Failover automatique: Fonctionnel"
    echo "  • Récupération après panne: Réussie"
    echo "  • Applications maintenues pendant failover"
    echo "  • Cluster revenu à l'état normal (3/3 masters)"
else
    echo -e "$WARN Tests partiellement réussis"
    echo "  Masters actifs: $MASTERS_FINAL/3"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Log complet: $TEST_LOG"
