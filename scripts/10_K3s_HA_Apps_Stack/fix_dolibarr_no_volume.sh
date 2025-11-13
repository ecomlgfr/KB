#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX URGENT Dolibarr - SANS Volume (Test)                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'

echo ""
echo "⚠️  ATTENTION : Ce script déploie Dolibarr SANS volume persistent"
echo "   C'est uniquement pour TESTER si le problème vient du PVC"
echo "   Les documents seront perdus au redémarrage du pod"
echo ""
echo "Ce script :"
echo "  1. Supprime tout (deployment, service, ingress, PVC)"
echo "  2. Redéploie Dolibarr SANS volume"
echo "  3. Teste si ça fonctionne"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Nettoyage COMPLET (avec PVC) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete deployment dolibarr -n erp --grace-period=0 --force 2>/dev/null || true
kubectl delete service dolibarr -n erp 2>/dev/null || true
kubectl delete ingress dolibarr -n erp 2>/dev/null || true
kubectl delete pvc dolibarr-documents -n erp 2>/dev/null || true

echo "Attente suppression (30s)..."
sleep 30

echo -e "$OK Nettoyage complet terminé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Déploiement SANS volume ═══"
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
        resources:
          requests:
            cpu: "200m"
            memory: "512Mi"
          limits:
            cpu: "1000m"
            memory: "1Gi"
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

echo -e "$OK Déploiement créé (SANS volume)"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Attente démarrage (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pod :"
kubectl get pods -n erp -l app=dolibarr -o wide
echo ""

POD=$(kubectl get pod -n erp -l app=dolibarr -o name | head -1)
POD_STATUS=$(kubectl get pod -n erp -l app=dolibarr --no-headers 2>/dev/null | awk '{print $3}')

if [ "$POD_STATUS" = "Running" ]; then
    echo -e "$OK Pod Running"
elif [ "$POD_STATUS" = "Pending" ]; then
    echo -e "$KO Pod toujours Pending - Problème n'est PAS le volume"
    echo ""
    echo "Events du pod :"
    kubectl describe $POD -n erp | grep -A 20 "Events:"
    exit 1
else
    echo -e "$KO Pod status : $POD_STATUS"
fi

echo ""
echo "Service et Endpoints :"
kubectl get svc -n erp dolibarr
kubectl get endpoints -n erp dolibarr
echo ""

echo "Logs (20 lignes) :"
kubectl logs -n erp $POD --tail=20
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Tests HTTP ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test 1 : Depuis le pod"
kubectl exec -n erp $POD -- curl -I http://localhost:80 --max-time 5 2>&1 | head -5
echo ""

echo "Test 2 : Via Service"
SVC_IP=$(kubectl get svc -n erp dolibarr -o jsonpath='{.spec.clusterIP}')
kubectl run test --image=curlimages/curl --restart=Never -n erp --rm -i -- \
  curl -I http://$SVC_IP:80 --max-time 10 2>&1 | head -10
echo ""

echo "Test 3 : Via Ingress"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://my.keybuzz.io --max-time 15 2>/dev/null || echo "000")
echo "HTTP Code : $HTTP"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Tests terminés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
    echo "✅ SUCCÈS - Dolibarr accessible SANS volume"
    echo ""
    echo "Le problème était le PVC dolibarr-documents"
    echo ""
    echo "⚠️  ATTENTION : Configuration actuelle SANS volume persistent"
    echo "   Les documents seront perdus au redémarrage"
    echo ""
    echo "Pour ajouter un volume persistent :"
    echo "  1. Créer un nouveau PVC :"
    echo "     kubectl apply -f - <<EEOF"
    echo "     apiVersion: v1"
    echo "     kind: PersistentVolumeClaim"
    echo "     metadata:"
    echo "       name: dolibarr-documents"
    echo "       namespace: erp"
    echo "     spec:"
    echo "       accessModes:"
    echo "       - ReadWriteOnce"
    echo "       resources:"
    echo "         requests:"
    echo "           storage: 10Gi"
    echo "     EEOF"
    echo ""
    echo "  2. Ajouter le volume au deployment :"
    echo "     kubectl edit deployment -n erp dolibarr"
    echo ""
elif [ "$HTTP" = "202" ]; then
    echo "⚠️  HTTP 202 - Installation manuelle requise"
    echo ""
    echo "Accéder au wizard : http://my.keybuzz.io/install/"
else
    echo "❌ HTTP $HTTP - Toujours un problème"
fi

echo ""

exit 0
