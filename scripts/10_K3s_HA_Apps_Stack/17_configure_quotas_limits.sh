#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Configuration ResourceQuotas & LimitRanges               ║"
echo "║    (Limitation et contrôle des ressources par namespace)          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script configure :"
echo "  1. ResourceQuotas (limites CPU/RAM par namespace)"
echo "  2. LimitRanges (limites par pod/container)"
echo ""
echo "Namespaces concernés :"
echo "  - monitoring  : 4 CPU / 8Gi RAM"
echo "  - connect     : 4 CPU / 8Gi RAM"
echo "  - erp         : 8 CPU / 16Gi RAM"
echo "  - etl         : 8 CPU / 16Gi RAM"
echo "  - logging     : 4 CPU / 8Gi RAM"
echo ""

read -p "Appliquer les quotas et limites ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Création des namespaces ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace monitoring 2>/dev/null || echo "  namespace monitoring existe déjà"
kubectl create namespace connect 2>/dev/null || echo "  namespace connect existe déjà"
kubectl create namespace erp 2>/dev/null || echo "  namespace erp existe déjà"
kubectl create namespace etl 2>/dev/null || echo "  namespace etl existe déjà"
kubectl create namespace logging 2>/dev/null || echo "  namespace logging existe déjà"

echo -e "$OK Namespaces créés/vérifiés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Application ResourceQuotas ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Monitoring : 4 CPU / 8Gi RAM
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: monitoring-quota
  namespace: monitoring
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    pods: "50"
    services: "20"
    persistentvolumeclaims: "10"
EOF

echo "  ✓ ResourceQuota monitoring"

# Connect : 4 CPU / 8Gi RAM
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: connect-quota
  namespace: connect
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    pods: "20"
    services: "10"
EOF

echo "  ✓ ResourceQuota connect"

# ERP : 8 CPU / 16Gi RAM
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: erp-quota
  namespace: erp
spec:
  hard:
    requests.cpu: "8"
    requests.memory: "16Gi"
    limits.cpu: "16"
    limits.memory: "32Gi"
    pods: "30"
    services: "15"
    persistentvolumeclaims: "5"
EOF

echo "  ✓ ResourceQuota erp"

# ETL : 8 CPU / 16Gi RAM
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: etl-quota
  namespace: etl
spec:
  hard:
    requests.cpu: "8"
    requests.memory: "16Gi"
    limits.cpu: "16"
    limits.memory: "32Gi"
    pods: "30"
    services: "15"
    persistentvolumeclaims: "10"
EOF

echo "  ✓ ResourceQuota etl"

# Logging : 4 CPU / 8Gi RAM
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: logging-quota
  namespace: logging
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    pods: "30"
    services: "10"
    persistentvolumeclaims: "5"
EOF

echo "  ✓ ResourceQuota logging"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Application LimitRanges ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# LimitRange commun pour tous les namespaces
for ns in monitoring connect erp etl logging; do
    kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: ${ns}-limits
  namespace: ${ns}
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "1Gi"
    defaultRequest:
      cpu: "100m"
      memory: "256Mi"
    max:
      cpu: "2"
      memory: "4Gi"
    min:
      cpu: "50m"
      memory: "128Mi"
  - type: Pod
    max:
      cpu: "4"
      memory: "8Gi"
    min:
      cpu: "50m"
      memory: "128Mi"
EOF
    echo "  ✓ LimitRange $ns"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Labellisation des workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Worker labels
kubectl label nodes k3s-worker-01 role=apps --overwrite 2>/dev/null || true
kubectl label nodes k3s-worker-02 role=apps --overwrite 2>/dev/null || true
kubectl label nodes k3s-worker-03 role=apps --overwrite 2>/dev/null || true
kubectl label nodes k3s-worker-04 role=analytics --overwrite 2>/dev/null || true
kubectl label nodes k3s-worker-05 role=background --overwrite 2>/dev/null || true

echo "  ✓ Labels appliqués sur les workers"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Namespaces :"
kubectl get ns | grep -E '(monitoring|connect|erp|etl|logging)'
echo ""

echo "ResourceQuotas :"
kubectl get resourcequota -A
echo ""

echo "LimitRanges :"
kubectl get limitrange -A
echo ""

echo "Node Labels :"
kubectl get nodes --show-labels | grep -E 'worker-0[1-5]' | awk '{print $1, $6}' | grep role
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK ResourceQuotas et LimitRanges configurés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Résumé :"
echo "  ✓ 5 namespaces créés"
echo "  ✓ 5 ResourceQuotas appliqués"
echo "  ✓ 5 LimitRanges appliqués"
echo "  ✓ 5 workers labellisés"
echo ""
echo "Prochaine étape :"
echo "  ./13_deploy_monitoring_stack.sh"
echo ""

exit 0
