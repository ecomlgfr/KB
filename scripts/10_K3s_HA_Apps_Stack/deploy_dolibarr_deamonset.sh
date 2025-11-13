#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DOLIBARR - DaemonSet + hostNetwork (comme n8n/Chatwoot)        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'

echo ""
echo "Configuration EXACTE de n8n/LiteLLM/Qdrant/Chatwoot/Superset :"
echo "  ✅ DaemonSet (pas Deployment)"
echo "  ✅ hostNetwork: true"
echo "  ✅ Port fixe : 8090"
echo "  ✅ NodePort : 30090"
echo "  ❌ SANS volume persistent (pour l'instant)"
echo ""

read -p "Déployer Dolibarr ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Nettoyage ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete daemonset dolibarr -n erp --grace-period=0 --force 2>/dev/null || true
kubectl delete deployment dolibarr -n erp --grace-period=0 --force 2>/dev/null || true
kubectl delete service dolibarr -n erp 2>/dev/null || true
kubectl delete ingress dolibarr -n erp 2>/dev/null || true

sleep 10

echo -e "$OK Nettoyage terminé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Déploiement Dolibarr (DaemonSet + hostNetwork) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dolibarr
  namespace: erp
  labels:
    app: dolibarr
spec:
  selector:
    matchLabels:
      app: dolibarr
  template:
    metadata:
      labels:
        app: dolibarr
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        role: apps
      containers:
      - name: dolibarr
        image: tuxgasy/dolibarr:18.0.2
        ports:
        - containerPort: 8090
          hostPort: 8090
        env:
        - name: APACHE_RUN_PORT
          value: "8090"
        - name: DOLI_DB_TYPE
          value: "pgsql"
        - name: DOLI_DB_HOST
          value: "10.0.0.10"
        - name: DOLI_DB_PORT
          value: "4632"
        - name: DOLI_DB_NAME
          value: "dolibarr"
        - name: DOLI_DB_USER
          value: "dolibarr"
        - name: DOLI_DB_PASSWORD
          value: "NEhobUmaJGdR7TL2MCXRB853"
        - name: DOLI_ADMIN_LOGIN
          value: "admin"
        - name: DOLI_ADMIN_PASSWORD
          value: "KeyBuzz2025!"
        - name: DOLI_URL_ROOT
          value: "http://my.keybuzz.io"
        - name: PHP_MEMORY_LIMIT
          value: "512M"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
apiVersion: v1
kind: Service
metadata:
  name: dolibarr
  namespace: erp
spec:
  type: NodePort
  selector:
    app: dolibarr
  ports:
  - port: 8090
    targetPort: 8090
    nodePort: 30090
EOF

echo -e "$OK Dolibarr déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Configuration Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dolibarr
  namespace: erp
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: my.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: dolibarr
            port:
              number: 8090
EOF

echo -e "$OK Ingress configuré"

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

echo "Pods Dolibarr :"
kubectl get pods -n erp -l app=dolibarr -o wide
echo ""

PODS_RUNNING=$(kubectl get pods -n erp -l app=dolibarr --no-headers 2>/dev/null | grep Running | wc -l)
echo "Pods Running : $PODS_RUNNING/3 (workers role=apps)"
echo ""

echo "Service :"
kubectl get svc -n erp dolibarr
echo ""

echo "Ingress :"
kubectl get ingress -n erp dolibarr
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Tests HTTP ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Test 1 : Direct sur un worker
WORKER_IP=$(kubectl get nodes -l role=apps -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Test 1 : Direct sur worker ($WORKER_IP:8090)"
HTTP_WORKER=$(curl -s -o /dev/null -w "%{http_code}" http://$WORKER_IP:8090 --max-time 10 2>/dev/null || echo "000")
echo "  HTTP Code : $HTTP_WORKER"
echo ""

# Test 2 : Via Service NodePort
echo "Test 2 : Via Service NodePort ($WORKER_IP:30090)"
HTTP_NODEPORT=$(curl -s -o /dev/null -w "%{http_code}" http://$WORKER_IP:30090 --max-time 10 2>/dev/null || echo "000")
echo "  HTTP Code : $HTTP_NODEPORT"
echo ""

# Test 3 : Via Ingress
echo "Test 3 : Via Ingress (my.keybuzz.io)"
HTTP_INGRESS=$(curl -s -o /dev/null -w "%{http_code}" http://my.keybuzz.io --max-time 10 2>/dev/null || echo "000")
echo "  HTTP Code : $HTTP_INGRESS"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Déploiement terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 Accès Dolibarr :"
echo "  URL : http://my.keybuzz.io"
echo "  Port : 8090 (hostNetwork)"
echo "  NodePort : 30090"
echo ""
echo "⚙️ Architecture (EXACTE de n8n/Chatwoot) :"
echo "  Type : DaemonSet"
echo "  hostNetwork : true"
echo "  Pods : $PODS_RUNNING sur workers role=apps"
echo ""

if [ "$HTTP_INGRESS" = "200" ] || [ "$HTTP_INGRESS" = "302" ]; then
    echo "✅ SUCCÈS - Dolibarr accessible"
    echo ""
    echo "Ouvrir : http://my.keybuzz.io"
    echo "Login : admin / KeyBuzz2025!"
elif [ "$HTTP_INGRESS" = "202" ]; then
    echo "⚠️  HTTP 202 - Installation manuelle requise"
    echo ""
    echo "1. Ouvrir : http://my.keybuzz.io/install/"
    echo "2. DB : 10.0.0.10:4632 / dolibarr / dolibarr / NEhobUmaJGdR7TL2MCXRB853"
elif [ "$HTTP_WORKER" = "200" ] || [ "$HTTP_WORKER" = "202" ]; then
    echo "⚠️  Dolibarr répond sur worker mais Ingress KO"
    echo ""
    echo "Accès direct : http://$WORKER_IP:8090"
    echo "ou : http://$WORKER_IP:30090"
else
    echo "❌ Dolibarr ne répond pas"
    echo ""
    echo "Logs :"
    echo "  kubectl logs -n erp -l app=dolibarr --tail=50"
fi

echo ""

exit 0
