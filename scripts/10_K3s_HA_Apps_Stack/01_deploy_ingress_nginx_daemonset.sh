#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Déploiement Ingress NGINX en DaemonSet avec hostNetwork
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

export KUBECONFIG="$KUBECONFIG_PATH"

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

###############################################################################
# CREATE NAMESPACE
###############################################################################

create_namespace() {
    log "${INFO} Création du namespace $INGRESS_NAMESPACE..."

    kubectl create namespace "$INGRESS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    log "${OK} Namespace créé"
}

###############################################################################
# DEPLOY INGRESS NGINX DAEMONSET
###############################################################################

deploy_ingress_nginx() {
    log "${INFO} Déploiement d'Ingress NGINX en DaemonSet..."

    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-configuration
  namespace: $INGRESS_NAMESPACE
  labels:
    app.kubernetes.io/name: ingress-nginx
data:
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
  use-proxy-protocol: "false"
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: $INGRESS_NAMESPACE
  labels:
    app.kubernetes.io/name: ingress-nginx
spec:
  type: NodePort
  ports:
  - name: http
    port: 80
    targetPort: 80
    nodePort: $INGRESS_HTTP_NODEPORT
    protocol: TCP
  - name: https
    port: 443
    targetPort: 443
    nodePort: $INGRESS_HTTPS_NODEPORT
    protocol: TCP
  selector:
    app.kubernetes.io/name: ingress-nginx
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ingress-nginx-controller
  namespace: $INGRESS_NAMESPACE
  labels:
    app.kubernetes.io/name: ingress-nginx
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ingress-nginx
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: ingress-nginx
      nodeSelector:
        node-role.kubernetes.io/worker: "true"
      containers:
      - name: controller
        image: registry.k8s.io/ingress-nginx/controller:v1.9.5
        args:
        - /nginx-ingress-controller
        - --election-id=ingress-controller-leader
        - --controller-class=k8s.io/ingress-nginx
        - --ingress-class=nginx
        - --configmap=\$(POD_NAMESPACE)/nginx-configuration
        - --http-port=80
        - --https-port=443
        - --publish-service=\$(POD_NAMESPACE)/ingress-nginx-controller
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: LD_PRELOAD
          value: /usr/local/lib/libmimalloc.so
        ports:
        - name: http
          containerPort: 80
          hostPort: 80
          protocol: TCP
        - name: https
          containerPort: 443
          hostPort: 443
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: 10254
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 1
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /healthz
            port: 10254
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 1
          successThreshold: 1
          failureThreshold: 3
        resources:
          requests:
            cpu: 100m
            memory: 90Mi
        securityContext:
          runAsUser: 101
          allowPrivilegeEscalation: true
          capabilities:
            drop:
            - ALL
            add:
            - NET_BIND_SERVICE
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingress-nginx
  namespace: $INGRESS_NAMESPACE
  labels:
    app.kubernetes.io/name: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  - endpoints
  - nodes
  - pods
  - secrets
  - namespaces
  verbs:
  - list
  - watch
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - services
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses/status
  verbs:
  - update
- apiGroups:
  - networking.k8s.io
  resources:
  - ingressclasses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ingress-nginx
subjects:
- kind: ServiceAccount
  name: ingress-nginx
  namespace: $INGRESS_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ingress-nginx
  namespace: $INGRESS_NAMESPACE
  labels:
    app.kubernetes.io/name: ingress-nginx
rules:
- apiGroups:
  - ""
  resources:
  - namespaces
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - configmaps
  - pods
  - secrets
  - endpoints
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - services
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses/status
  verbs:
  - update
- apiGroups:
  - networking.k8s.io
  resources:
  - ingressclasses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  resourceNames:
  - ingress-controller-leader
  verbs:
  - get
  - update
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - create
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ingress-nginx
  namespace: $INGRESS_NAMESPACE
  labels:
    app.kubernetes.io/name: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ingress-nginx
subjects:
- kind: ServiceAccount
  name: ingress-nginx
  namespace: $INGRESS_NAMESPACE
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
spec:
  controller: k8s.io/ingress-nginx
EOF

    log "${OK} Ingress NGINX déployé"
}

###############################################################################
# LABEL WORKERS
###############################################################################

label_workers() {
    log "${INFO} Labellisation des workers..."

    # Label tous les workers
    for ip in "$K3S_WORKER_01_IP" "$K3S_WORKER_02_IP" "$K3S_WORKER_03_IP" "$K3S_WORKER_04_IP" "$K3S_WORKER_05_IP"; do
        local node_name=$(kubectl get nodes -o wide | grep "$ip" | awk '{print $1}')
        if [[ -n "$node_name" ]]; then
            kubectl label node "$node_name" node-role.kubernetes.io/worker=true --overwrite >/dev/null 2>&1
            log "  ✓ Worker labelisé: $node_name ($ip)"
        fi
    done

    log "${OK} Workers labelisés"
}

###############################################################################
# WAIT FOR READY
###############################################################################

wait_for_ready() {
    log "${INFO} Attente du démarrage d'Ingress NGINX..."

    local max_wait=$WAIT_INGRESS_READY
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local ready_pods=$(kubectl get pods -n "$INGRESS_NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || true)
        local expected_pods=5  # 5 workers

        if [[ "$ready_pods" -eq "$expected_pods" ]]; then
            log "${OK} Ingress NGINX opérationnel ($ready_pods/$expected_pods pods)"
            return 0
        fi

        sleep 5
        waited=$((waited + 5))
    done

    log "${WARN} Timeout atteint, vérifier l'état des pods"
    kubectl get pods -n "$INGRESS_NAMESPACE"
}

###############################################################################
# VERIFY DEPLOYMENT
###############################################################################

verify_deployment() {
    log "${INFO} Vérification du déploiement..."

    echo ""
    echo "État des pods Ingress NGINX:"
    kubectl get pods -n "$INGRESS_NAMESPACE" -o wide
    echo ""

    echo "Service Ingress NGINX:"
    kubectl get svc -n "$INGRESS_NAMESPACE"
    echo ""

    log "${OK} Vérification terminée"
}

###############################################################################
# MAIN
###############################################################################

main() {
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║  DÉPLOIEMENT INGRESS NGINX DAEMONSET                         ║"
    log "╚═══════════════════════════════════════════════════════════════╝"

    create_namespace
    label_workers
    deploy_ingress_nginx
    wait_for_ready
    verify_deployment

    log "${OK} Ingress NGINX DaemonSet déployé avec succès"
    log "${INFO} NodePorts: HTTP=$INGRESS_HTTP_NODEPORT, HTTPS=$INGRESS_HTTPS_NODEPORT"
}

main "$@"
