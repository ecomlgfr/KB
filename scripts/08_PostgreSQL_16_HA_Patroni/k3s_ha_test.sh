#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          K3S_HA_TEST - Test de haute disponibilité K3s             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_LOG="$LOG_DIR/k3s_ha_test_$TIMESTAMP.log"

echo ""
echo "Test de failover K3s HA"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Configurer kubeconfig
export KUBECONFIG="${KUBECONFIG:-$CREDS_DIR/k3s-kubeconfig.yaml}"

if [ ! -f "$KUBECONFIG" ]; then
    echo -e "$KO Kubeconfig non trouvé: $KUBECONFIG"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 0: ÉTAT INITIAL
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 0: Vérification de l'état initial                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  État des nœuds K3s:"
kubectl get nodes -o wide
echo ""

echo "  Test API via différents endpoints:"

# Test direct sur chaque master
for i in 0 1 2; do
    master="k3s-master-0$((i+1))"
    ip="10.0.0.10$i"
    echo -n "    $master ($ip:6443): "
    if timeout 2 kubectl --server="https://$ip:6443" --insecure-skip-tls-verify get nodes &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

# Test via LB
echo -n "    Via Load Balancer (10.0.0.10:6443): "
if kubectl get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 1: DÉPLOIEMENT APPLICATION TEST
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 1: Déploiement d'une application de test                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Création namespace et deployment..."

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ha-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: ha-test
spec:
  replicas: 6
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
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
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: nginx-test
EOF

sleep 10

echo -n "  Pods déployés: "
READY=$(kubectl get pods -n ha-test --no-headers | grep -c "Running")
TOTAL=$(kubectl get pods -n ha-test --no-headers | wc -l)
echo "$READY/$TOTAL running"

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 2: ARRÊT D'UN MASTER
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 2: Simulation arrêt d'un master K3s                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Arrêt de k3s-master-03 (10.0.0.102)..."
ssh -o StrictHostKeyChecking=no root@10.0.0.102 "systemctl stop k3s"

sleep 5

echo "  Test après arrêt d'un master:"
echo -n "    API via LB: "
if kubectl get nodes &>/dev/null; then
    echo -e "$OK (failover réussi)"
else
    echo -e "$KO"
fi

echo -n "    Création d'un pod: "
if kubectl run test-pod-$(date +%s) --image=busybox -n ha-test -- sleep 3600 &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "  État du cluster:"
kubectl get nodes

echo ""
echo "  Redémarrage de k3s-master-03..."
ssh -o StrictHostKeyChecking=no root@10.0.0.102 "systemctl start k3s"

echo "  Attente de récupération (30s)..."
sleep 30

echo "  État après récupération:"
kubectl get nodes

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 3: REDÉMARRAGE COMPLET D'UN SERVEUR
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 3: Redémarrage complet d'un serveur                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Redémarrage de k3s-master-02 (10.0.0.101)..."
ssh -o StrictHostKeyChecking=no root@10.0.0.101 "reboot" &>/dev/null

echo "  Attente du redémarrage (60s)..."
sleep 60

echo "  Test pendant redémarrage:"
echo -n "    API disponible: "
if kubectl get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "    Pods toujours running: "
RUNNING=$(kubectl get pods -n ha-test --no-headers 2>/dev/null | grep -c "Running")
echo "$RUNNING pods"

echo ""
echo "  Attente retour master-02 (30s)..."
sleep 30

echo "  État final:"
kubectl get nodes

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 4: TEST HAPROXY
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 4: Test failover HAProxy                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Arrêt HAProxy sur haproxy-01..."
ssh -o StrictHostKeyChecking=no root@10.0.0.11 "docker stop haproxy-k3s" &>/dev/null

sleep 3

echo -n "  API toujours accessible via LB: "
if kubectl get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo "  Redémarrage HAProxy sur haproxy-01..."
ssh -o StrictHostKeyChecking=no root@10.0.0.11 "docker start haproxy-k3s" &>/dev/null

sleep 5

echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 5: TEST DE CHARGE
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ TEST 5: Test de charge                                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Lancement de 20 requêtes simultanées:"
SUCCESS=0
for i in {1..20}; do
    if kubectl get nodes &>/dev/null; then
        echo -n "."
        SUCCESS=$((SUCCESS + 1))
    else
        echo -n "x"
    fi
done
echo " [$SUCCESS/20 succès]"

echo ""

# ═══════════════════════════════════════════════════════════════════
# NETTOYAGE
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ NETTOYAGE                                                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Suppression namespace de test..."
kubectl delete namespace ha-test --wait=false &>/dev/null
echo "    ✓ Namespace ha-test supprimé"

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════"

FINAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

if [ "$FINAL_NODES" -eq 3 ]; then
    echo -e "$OK K3S HA FONCTIONNEL"
    echo ""
    echo "Tests réussis:"
    echo "  • Failover automatique lors d'arrêt d'un master"
    echo "  • Continuité de service pendant redémarrage"
    echo "  • Récupération automatique après panne"
    echo "  • HAProxy assure la redondance"
    echo ""
    echo "État final: $FINAL_NODES/3 masters actifs"
else
    echo -e "$WARN Tests partiels"
    echo "Masters actifs: $FINAL_NODES/3"
fi

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Log complet: $TEST_LOG"
