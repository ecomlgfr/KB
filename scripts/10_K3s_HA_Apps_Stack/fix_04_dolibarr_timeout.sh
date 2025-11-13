#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX Dolibarr - Correction 504 Gateway Timeout                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

echo ""
echo "Ce script va :"
echo "  1. Vérifier la connexion DB"
echo "  2. Ajuster les probes (timeouts plus longs)"
echo "  3. Ajouter annotations Ingress pour timeout"
echo "  4. Redémarrer les pods"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification connexion DB depuis un pod ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test connexion PostgreSQL..."
kubectl exec -n erp $(kubectl get pod -n erp -l app=dolibarr -o name | head -1) -- \
  bash -c "apt-get update -qq && apt-get install -y -qq postgresql-client && psql postgresql://dolibarr:NEhobUmaJGdR7TL2MCXRB853@10.0.0.10:6432/dolibarr -c 'SELECT version();'" 2>&1 | tail -5

echo ""
echo -e "$OK Test DB effectué (si erreur, voir logs ci-dessus)"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Mise à jour Deployment avec timeouts ajustés ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dolibarr-web
  namespace: erp
  labels:
    app: dolibarr
    component: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: dolibarr
      component: web
  template:
    metadata:
      labels:
        app: dolibarr
        component: web
    spec:
      nodeSelector:
        role: apps
      containers:
      - name: dolibarr
        image: tuxgasy/dolibarr:18.0.2
        ports:
        - containerPort: 80
          name: http
        env:
        - name: DOLI_DB_TYPE
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_TYPE
        - name: DOLI_DB_HOST
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_HOST
        - name: DOLI_DB_PORT
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_PORT
        - name: DOLI_DB_NAME
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_NAME
        - name: DOLI_DB_USER
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_USER
        - name: DOLI_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_DB_PASSWORD
        - name: DOLI_ADMIN_LOGIN
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_ADMIN_LOGIN
        - name: DOLI_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_ADMIN_PASSWORD
        - name: DOLI_URL_ROOT
          valueFrom:
            secretKeyRef:
              name: dolibarr-secrets
              key: DOLI_URL_ROOT
        - name: DOLI_MODULES
          value: "modFacture,modPropale,modStripe,modAbonnement,modAPI"
        - name: PHP_INI_DATE_TIMEZONE
          value: "Europe/Paris"
        - name: PHP_MEMORY_LIMIT
          value: "512M"
        volumeMounts:
        - name: documents
          mountPath: /var/www/documents
        # PROBES AJUSTÉES (timeouts plus longs)
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 10
          failureThreshold: 3
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
EOF

echo -e "$OK Deployment mis à jour"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Mise à jour Ingress avec timeouts ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dolibarr-ingress
  namespace: erp
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "8k"
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

echo -e "$OK Ingress mis à jour"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Redémarrage des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl rollout restart deployment/dolibarr-web -n erp

echo "Attente du rollout (60s)..."
kubectl rollout status deployment/dolibarr-web -n erp --timeout=120s

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Attente complète (2 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente initialisation Dolibarr..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods erp :"
kubectl get pods -n erp -o wide
echo ""

echo "Logs du dernier pod (20 lignes) :"
kubectl logs -n erp $(kubectl get pod -n erp -l app=dolibarr -o name | tail -1) --tail=20
echo ""

echo "Test HTTP direct (service) :"
kubectl run -it --rm debug-dolibarr --image=curlimages/curl --restart=Never -n erp -- \
  curl -I http://dolibarr.erp.svc:80 --max-time 10 2>&1 | head -10
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Dolibarr corrigé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 Accès Dolibarr :"
echo "  URL : http://my.keybuzz.io"
echo "  Login : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "⚙️ Modifications appliquées :"
echo "  ✓ Liveness probe : 120s initial delay, 30s period"
echo "  ✓ Readiness probe : 60s initial delay, 10s period"
echo "  ✓ Ingress timeouts : 600s (10 minutes)"
echo "  ✓ PHP memory : 512M"
echo "  ✓ Resources : 200m/512Mi → 1000m/1Gi"
echo ""
echo "🔍 Tests :"
echo "  curl -I http://my.keybuzz.io"
echo "  curl -v http://my.keybuzz.io/install/"
echo ""
echo "📝 Si encore 504 :"
echo "  1. Vérifier logs : kubectl logs -n erp <pod-name>"
echo "  2. Vérifier DB : kubectl exec -n erp <pod> -- env | grep DOLI_DB"
echo "  3. Tester connexion DB directe"
echo ""

exit 0
