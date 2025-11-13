#!/bin/bash
set -euo pipefail
LOG_DIR=/opt/keybuzz-installer/logs/fixes
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/fix_pod_network_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

WORKERS=(10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114)
MASTERS=(10.0.0.100 10.0.0.101 10.0.0.102)

log() {
  echo "[$(date +%F' '%T)] $*"
}

log "RedÃ©marrage des agents (workers)"
for host in "${WORKERS[@]}"; do
  log "- systemctl restart k3s-agent sur $host"
  ssh -o StrictHostKeyChecking=no root@$host 'systemctl restart k3s-agent'
  sleep 5
done

log "RedÃ©marrage des serveurs (masters)"
for host in "${MASTERS[@]}"; do
  log "- systemctl restart k3s sur $host"
  ssh -o StrictHostKeyChecking=no root@$host 'systemctl restart k3s'
  sleep 5
done

log "Attente stabilisation (120s)"
sleep 120

log "Etat des nÅ“uds"
kubectl get nodes

log "Test DNS (namespace connect)"
kubectl delete pod -n connect dnsdiag --ignore-not-found || true
if kubectl run -n connect dnsdiag --restart=Never --image=busybox:1.36 --command -- nslookup kubernetes.default.svc.cluster.local; then
  sleep 5
  kubectl logs -n connect dnsdiag || true
  kubectl delete pod -n connect dnsdiag --ignore-not-found || true
else
  log "Echec crÃ©ation pod dnsdiag"
fi

log "Test HTTP connect-api (localhost)"
kubectl exec -n connect deploy/connect-api -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1/health || true

log "Test HTTP connect-api (service)"
kubectl exec -n connect deploy/connect-api -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://connect-api.connect.svc.cluster.local/health || true

log "Fin script"