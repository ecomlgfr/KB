#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX SIMPLE Dolibarr - Config identique à Chatwoot              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'

echo ""
echo "Ce script :"
echo "  1. Copie EXACTEMENT la config de Chatwoot (qui fonctionne)"
echo "  2. Deployment simple 1 replica"
echo "  3. Service ClusterIP standard"
echo "  4. SANS probes (pour debug)"
echo "  5. Port standard 80"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Nettoyage complet ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete deployment dolibarr-web -n erp 2>/dev/null || true
kubectl delete service dolibarr -n erp 2>/dev/null || true
kubectl delete ingress dolibarr-ingress -n erp 2>/dev/null || true
sleep 10

echo -e "$OK Nettoyage terminé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Déploiement ULTRA-SIMPLE ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dolibarr
  namespace: erp
  labels:
    app: dolibarr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dolibarr
  template:
    metadata:
      labels:
        app: dolibarr
    spec:
      nodeSelector:
        role: apps
      containers:
      - name: dolibarr
        image: tuxgasy/dolibarr:18.0.2
        ports:
        - containerPort: 80
        env:
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
        volumeMounts:
        - name: documents
          mountPath: /var/www/documents
        resources:
          requests:
            cpu: "200m"
            memory: "512Mi"
          limits:
            cpu: "1000m"
            memory: "1Gi"
      volumes:
      - name: documents
        persistentVolumeClaim:
          claimName: dolibarr-documents
---
apiVersion: v1
kind: Service
metadata:
  name: dolibarr
  namespace: erp
spec:
  selector:
    app: dolibarr
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dolibarr
  namespace: erp
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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
              number: 80
EOF

echo -e "$OK Déploiement créé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Attente (90s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 90

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pod :"
kubectl get pod -n erp -l app=dolibarr -o wide
echo ""

echo "Service :"
kubectl get svc -n erp dolibarr
echo ""

echo "Endpoints :"
kubectl get endpoints -n erp dolibarr
echo ""

echo "Ingress :"
kubectl get ingress -n erp dolibarr
echo ""

POD=$(kubectl get pod -n erp -l app=dolibarr -o name | head -1)
if [ -n "$POD" ]; then
    echo "Logs (20 dernières lignes) :"
    kubectl logs -n erp $POD --tail=20
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Tests HTTP ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Test 1 : Depuis le pod lui-même
echo "Test 1 : HTTP depuis le pod lui-même"
if [ -n "$POD" ]; then
    kubectl exec -n erp $POD -- curl -I http://localhost:80 --max-time 5 2>&1 | head -5
else
    echo "Pas de pod"
fi
echo ""

# Test 2 : Via ClusterIP
echo "Test 2 : HTTP via ClusterIP Service"
SVC_IP=$(kubectl get svc -n erp dolibarr -o jsonpath='{.spec.clusterIP}')
echo "Service IP : $SVC_IP"
kubectl run test-svc --image=curlimages/curl --restart=Never -n erp --rm -i -- \
  curl -I http://$SVC_IP:80 --max-time 10 2>&1 | head -10
echo ""

# Test 3 : Via Ingress
echo "Test 3 : HTTP via Ingress"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://my.keybuzz.io --max-time 15 2>/dev/null || echo "000")
echo "HTTP Code : $HTTP"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Tests terminés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
    echo "✅ SUCCÈS - Dolibarr accessible"
    echo ""
    echo "Ouvrir : http://my.keybuzz.io"
elif [ "$HTTP" = "202" ]; then
    echo "⚠️  HTTP 202 - Installation manuelle requise"
    echo ""
    echo "Accéder au wizard : http://my.keybuzz.io/install/"
    echo ""
    echo "Utiliser :"
    echo "  DB Host : 10.0.0.10"
    echo "  DB Port : 4632"
    echo "  DB Name : dolibarr"
    echo "  DB User : dolibarr"
    echo "  DB Password : NEhobUmaJGdR7TL2MCXRB853"
else
    echo "❌ HTTP $HTTP - Problème réseau"
    echo ""
    echo "Diagnostic approfondi :"
    echo "  ./diagnostic_network_dolibarr.sh"
    echo ""
    echo "Port-forward direct :"
    echo "  kubectl port-forward -n erp $POD 8090:80 &"
    echo "  curl http://localhost:8090"
fi

echo ""

exit 0
