#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Ingress NGINX en DaemonSet                   ║"
echo "║    (Solution hostNetwork - Pas de Helm)                           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

echo ""
echo "IMPORTANT :"
echo "  ❌ Ne PAS utiliser Helm pour Ingress NGINX"
echo "  ✅ Déployer en DaemonSet avec hostNetwork"
echo ""
echo "Raison :"
echo "  VXLAN bloqué sur Hetzner → hostNetwork requis"
echo ""

read -p "Déployer Ingress NGINX en DaemonSet ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Nettoyage Ingress NGINX existant (si présent) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Vérifier si le namespace existe
if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
    echo "→ Namespace ingress-nginx existe, nettoyage..."
    
    # Supprimer le Helm release si existe
    if command -v helm &>/dev/null; then
        helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
    fi
    
    # Supprimer toutes les ressources du namespace
    echo "  → Suppression des ressources..."
    kubectl delete all --all -n ingress-nginx --timeout=10s 2>/dev/null || true
    kubectl delete daemonset --all -n ingress-nginx --timeout=10s 2>/dev/null || true
    kubectl delete deployment --all -n ingress-nginx --timeout=10s 2>/dev/null || true
    kubectl delete configmap --all -n ingress-nginx --timeout=10s 2>/dev/null || true
    kubectl delete secret --all -n ingress-nginx --timeout=10s 2>/dev/null || true
    
    # Forcer la suppression du namespace (sans attendre les finalizers)
    echo "  → Suppression forcée du namespace..."
    kubectl delete namespace ingress-nginx --timeout=10s 2>/dev/null || {
        # Si bloqué par finalizers, forcer
        kubectl get namespace ingress-nginx -o json 2>/dev/null | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw /api/v1/namespaces/ingress-nginx/finalize -f - 2>/dev/null || true
    }
    
    # Attendre max 20 secondes
    echo "  → Attente suppression (max 20s)..."
    for i in {1..20}; do
        if ! kubectl get namespace ingress-nginx >/dev/null 2>&1; then
            echo -e "  $OK Namespace supprimé"
            break
        fi
        sleep 1
    done
    
    # Si toujours présent après 20s, continuer quand même
    if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
        echo -e "  $WARN Namespace toujours présent, mais on continue..."
    fi
else
    echo "→ Namespace ingress-nginx n'existe pas (installation propre)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création namespace + ServiceAccount ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Recréer le namespace (peut échouer si toujours en cours de suppression)
kubectl create namespace ingress-nginx 2>/dev/null || {
    echo -e "$WARN Namespace existe déjà ou en cours de suppression, on patiente 30s..."
    sleep 30
    kubectl create namespace ingress-nginx 2>/dev/null || echo -e "$WARN Namespace toujours présent"
}

kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingress-nginx
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
data:
  allow-snippet-annotations: "true"
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
  use-proxy-protocol: "false"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
rules:
  - apiGroups: [""]
    resources: ["configmaps", "endpoints", "nodes", "pods", "secrets", "namespaces"]
    verbs: ["list", "watch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["list", "watch"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses/status"]
    verbs: ["update"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingressclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["list", "watch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ingress-nginx
subjects:
  - kind: ServiceAccount
    name: ingress-nginx
    namespace: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ingress-nginx
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps", "pods", "secrets", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses/status"]
    verbs: ["update"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingressclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    resourceNames: ["ingress-nginx-leader"]
    verbs: ["get", "update"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["list", "watch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ingress-nginx
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ingress-nginx
subjects:
  - kind: ServiceAccount
    name: ingress-nginx
    namespace: ingress-nginx
EOF

echo -e "$OK RBAC créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Déploiement DaemonSet Ingress NGINX ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
      app.kubernetes.io/instance: ingress-nginx
      app.kubernetes.io/component: controller
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/component: controller
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: ingress-nginx
      terminationGracePeriodSeconds: 300
      containers:
      - name: controller
        image: registry.k8s.io/ingress-nginx/controller:v1.9.4
        args:
          - /nginx-ingress-controller
          - --election-id=ingress-nginx-leader
          - --controller-class=k8s.io/ingress-nginx
          - --ingress-class=nginx
          - --configmap=$(POD_NAMESPACE)/ingress-nginx-controller
          - --http-port=31695
          - --https-port=32720
          - --healthz-port=10254
          - --publish-status-address=localhost
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
            containerPort: 31695
            hostPort: 31695
            protocol: TCP
          - name: https
            containerPort: 32720
            hostPort: 32720
            protocol: TCP
          - name: healthz
            containerPort: 10254
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
          allowPrivilegeEscalation: true
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - ALL
          runAsUser: 101
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
spec:
  type: NodePort
  ports:
    - name: http
      port: 80
      targetPort: 31695
      nodePort: 31695
      protocol: TCP
    - name: https
      port: 443
      targetPort: 32720
      nodePort: 32720
      protocol: TCP
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/component: controller
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ingress-nginx
spec:
  controller: k8s.io/ingress-nginx
EOF

echo -e "$OK DaemonSet créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Attente démarrage (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -n ingress-nginx
echo ""
kubectl get daemonset -n ingress-nginx
echo ""
kubectl get svc -n ingress-nginx

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Ingress NGINX déployé en DaemonSet"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "NodePorts :"
echo "  HTTP  : 31695"
echo "  HTTPS : 32720"
echo ""
echo "Test rapide :"
WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")
if [ -n "$WORKER_IP" ]; then
    echo -n "  → Test port 31695 sur $WORKER_IP... "
    if timeout 3 bash -c "</dev/tcp/$WORKER_IP/31695" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO (attendre 30s de plus)"
    fi
fi
echo ""
echo "Prochaine étape :"
echo "  ./10_deploy_apps_hostnetwork.sh"
echo ""
