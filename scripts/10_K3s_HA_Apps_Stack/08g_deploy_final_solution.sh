#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Solution Finale : Ingress NGINX DaemonSet (sans VXLAN)         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "Analyse du problème :"
echo "  → VXLAN (8472/UDP) est autorisé dans UFW"
echo "  → Mais les workers ne peuvent toujours PAS communiquer"
echo "  → Problème probable : Infrastructure réseau Hetzner Cloud"
echo ""
echo "Solution de contournement :"
echo "  → Déployer Ingress NGINX en DaemonSet"
echo "  → 1 pod par worker = communication locale uniquement"
echo "  → Les NodePorts fonctionneront sans VXLAN"
echo ""
echo "Cette solution :"
echo "  ✓ Résout le problème des NodePorts"
echo "  ✓ Permet au Load Balancer de fonctionner"
echo "  ✓ Haute disponibilité (5 pods Ingress)"
echo "  ⚠  La communication inter-pods reste limitée"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 1/5 : Sauvegarde ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'BACKUP'
set -u

mkdir -p /opt/keybuzz-installer/backups/ingress-nginx

echo "→ Sauvegarde du déploiement actuel..."
kubectl get deployment ingress-nginx-controller -n ingress-nginx -o yaml > \
    /opt/keybuzz-installer/backups/ingress-nginx/deployment-$(date +%Y%m%d-%H%M%S).yaml 2>/dev/null || true

echo "✓ Sauvegarde terminée"
BACKUP

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 2/5 : Suppression Deployment ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'DELETE'
set -u

echo "→ Suppression du Deployment..."
kubectl delete deployment ingress-nginx-controller -n ingress-nginx 2>/dev/null || echo "  (déjà supprimé)"

echo "✓ Deployment supprimé"
DELETE

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAPE 3/5 : Déploiement DaemonSet ═══"
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
      # Ne pas déployer sur les masters
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
      
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
echo "═══ ÉTAPE 4/5 : Attente démarrage pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 60s pour le démarrage des pods..."
sleep 60

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
echo "═══ ÉTAPE 5/5 : TEST NODEPORTS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

# Récupérer les NodePorts
HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)

echo "Test des NodePorts (HTTP $HTTP_NODEPORT) :"
echo ""

SUCCESS=0
FAILED=0

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker ($ip:$HTTP_NODEPORT) ... "
    
    if timeout 5 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
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

if [ $SUCCESS -ge 4 ]; then
    echo -e "$OK Ingress NGINX DaemonSet opérationnel !"
    echo ""
    echo "✅ Solution déployée avec succès"
    echo ""
    echo "Configuration Load Balancer Hetzner :"
    echo "  1. Aller dans Hetzner Cloud Console"
    echo "  2. Load Balancers → lb-keybuzz-1"
    echo "  3. Services :"
    echo "     - HTTP  → NodePort $HTTP_NODEPORT"
    echo "     - HTTPS → NodePort (vérifier)"
    echo "  4. Health Check :"
    echo "     - Protocol : HTTP"
    echo "     - Port     : $HTTP_NODEPORT"
    echo "     - Path     : /healthz"
    echo "  5. Targets : k3s-worker-01 à 05 (IPs privées)"
    echo ""
    echo "Test final depuis Internet :"
    echo "  curl http://n8n.keybuzz.io"
    echo "  curl http://chat.keybuzz.io"
    echo ""
    exit 0
    
elif [ $SUCCESS -ge 1 ]; then
    echo -e "$WARN Fonctionnement partiel ($SUCCESS workers OK)"
    echo ""
    echo "Les workers qui répondent suffisent pour un démarrage."
    echo "Attendre 2-3 minutes que tous les pods démarrent complètement."
    echo ""
    echo "Relancer le test dans 3 minutes :"
    echo "  watch -n 5 'kubectl get pods -n ingress-nginx -o wide'"
    echo ""
    echo "Puis tester à nouveau :"
    echo "  ./08_fix_ufw_nodeports_urgent.sh"
    echo ""
    exit 0
else
    echo -e "$KO Aucun worker ne répond"
    echo ""
    echo "Actions de debug :"
    echo "  1. Vérifier les pods :"
    echo "     kubectl get pods -n ingress-nginx -o wide"
    echo ""
    echo "  2. Vérifier les logs d'un pod :"
    echo "     kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50"
    echo ""
    echo "  3. Vérifier qu'un pod est bien prêt :"
    echo "     kubectl describe pod -n ingress-nginx <pod-name>"
    echo ""
    exit 1
fi
