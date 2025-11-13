#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Redéploiement Ingress NGINX en DaemonSet                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "Problème identifié :"
echo "  → Ingress NGINX déployé avec 1 seul replica (Deployment)"
echo "  → Le pod ne tourne que sur k3s-worker-02"
echo "  → Les autres workers ne peuvent pas répondre sur les NodePorts"
echo ""
echo "Solution :"
echo "  → Redéployer Ingress NGINX en DaemonSet"
echo "  → 1 pod sur chaque worker = tous les workers peuvent répondre"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 1/4 : Sauvegarde de la configuration actuelle ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'BACKUP'
set -u

mkdir -p /opt/keybuzz-installer/backups/ingress-nginx

echo "→ Sauvegarde du déploiement actuel..."
kubectl get deployment ingress-nginx-controller -n ingress-nginx -o yaml > \
    /opt/keybuzz-installer/backups/ingress-nginx/deployment-$(date +%Y%m%d-%H%M%S).yaml

echo "→ Sauvegarde du service..."
kubectl get svc ingress-nginx-controller -n ingress-nginx -o yaml > \
    /opt/keybuzz-installer/backups/ingress-nginx/service-$(date +%Y%m%d-%H%M%S).yaml

echo "✓ Sauvegarde terminée"
BACKUP

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 2/4 : Suppression du Deployment actuel ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'DELETE'
set -u

echo "→ Suppression du Deployment ingress-nginx-controller..."
kubectl delete deployment ingress-nginx-controller -n ingress-nginx

echo "✓ Deployment supprimé"
DELETE

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 3/4 : Déploiement en DaemonSet ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'DAEMONSET'
set -u

echo "→ Création du DaemonSet Ingress NGINX..."

cat <<'EOF' | kubectl apply -f -
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
      # Déployer uniquement sur les workers (pas les masters)
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
      
      # Tolérer les taints
      tolerations:
      - operator: Exists
      
      serviceAccountName: ingress-nginx
      terminationGracePeriodSeconds: 300
      
      containers:
      - name: controller
        image: registry.k8s.io/ingress-nginx/controller:v1.9.4
        imagePullPolicy: IfNotPresent
        
        args:
        - /nginx-ingress-controller
        - --election-id=ingress-nginx-leader
        - --controller-class=k8s.io/ingress-nginx
        - --ingress-class=nginx
        - --configmap=$(POD_NAMESPACE)/ingress-nginx-controller
        - --validating-webhook=:8443
        - --validating-webhook-certificate=/usr/local/certificates/cert
        - --validating-webhook-key=/usr/local/certificates/key
        - --watch-ingress-without-class=false
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
          containerPort: 80
          protocol: TCP
        - name: https
          containerPort: 443
          protocol: TCP
        - name: webhook
          containerPort: 8443
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
          limits:
            memory: 500Mi
        
        securityContext:
          allowPrivilegeEscalation: true
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - ALL
          runAsUser: 101
        
        volumeMounts:
        - name: webhook-cert
          mountPath: /usr/local/certificates/
          readOnly: true
      
      volumes:
      - name: webhook-cert
        secret:
          secretName: ingress-nginx-admission
EOF

echo "✓ DaemonSet créé"
DAEMONSET

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 4/4 : Vérification du déploiement ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 30s pour le démarrage des pods..."
sleep 30

echo ""
echo "→ État des pods Ingress NGINX :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o wide"

echo ""
echo "→ État du DaemonSet :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get daemonset -n ingress-nginx ingress-nginx-controller"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST DE CONNECTIVITÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

# Récupérer les NodePorts
HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)

echo "Test des NodePorts sur tous les workers :"
echo ""

SUCCESS=0
FAILED=0

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker ($ip:$HTTP_NODEPORT) ... "
    
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
        ((FAILED++))
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Résultat : $SUCCESS/$((SUCCESS+FAILED)) workers fonctionnels"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ $SUCCESS -ge 3 ]; then
    echo -e "$OK Ingress NGINX DaemonSet opérationnel"
    echo ""
    echo "Prochaines étapes :"
    echo "  1. Configurer le Load Balancer Hetzner"
    echo "  2. Tester les applications"
    echo ""
    exit 0
else
    echo -e "$WARN Certains workers ne répondent pas encore"
    echo ""
    echo "Attendre 1-2 minutes que les pods démarrent complètement."
    echo "Puis relancer le test : ./08_fix_ufw_nodeports_urgent.sh"
    echo ""
    exit 1
fi
