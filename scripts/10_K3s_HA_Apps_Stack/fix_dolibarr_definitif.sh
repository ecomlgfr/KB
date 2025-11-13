#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX DÉFINITIF Dolibarr - Correction Port + Configuration       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

echo ""
echo "Ce script corrige :"
echo "  1. Port DB incorrect (6432 → 4632 PgBouncer)"
echo "  2. Secrets DB avec bon port"
echo "  3. Configuration Dolibarr simplifiée"
echo "  4. Probes adaptées pour installation"
echo "  5. Resources adaptées"
echo ""

read -p "Appliquer le fix définitif ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Suppression de l'ancien déploiement ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete deployment dolibarr-web -n erp 2>/dev/null || true
sleep 5

echo -e "$OK Ancien déploiement supprimé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Vérification base de données (port 4632) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test connexion PgBouncer (port 4632) :"
PGPASSWORD="NEhobUmaJGdR7TL2MCXRB853" psql -h 10.0.0.10 -p 4632 -U dolibarr -d dolibarr -c "SELECT current_database(), version();" 2>&1 | head -5

if [ $? -eq 0 ]; then
    echo -e "$OK Base dolibarr accessible via PgBouncer (4632)"
else
    echo -e "$KO Impossible de se connecter à la base dolibarr"
    echo "   Vérifier que PgBouncer fonctionne sur 10.0.0.10:4632"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Recréation Secret avec BON port (4632) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete secret dolibarr-secrets -n erp 2>/dev/null || true

kubectl create secret generic dolibarr-secrets -n erp \
  --from-literal=DOLI_DB_TYPE='pgsql' \
  --from-literal=DOLI_DB_HOST='10.0.0.10' \
  --from-literal=DOLI_DB_PORT='4632' \
  --from-literal=DOLI_DB_NAME='dolibarr' \
  --from-literal=DOLI_DB_USER='dolibarr' \
  --from-literal=DOLI_DB_PASSWORD='NEhobUmaJGdR7TL2MCXRB853' \
  --from-literal=DOLI_ADMIN_LOGIN='admin' \
  --from-literal=DOLI_ADMIN_PASSWORD='KeyBuzz2025!' \
  --from-literal=DOLI_URL_ROOT='http://my.keybuzz.io'

echo -e "$OK Secret recréé avec port 4632"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Déploiement Dolibarr (config corrigée) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dolibarr-web
  namespace: erp
  labels:
    app: dolibarr
    component: web
spec:
  # DÉMARRER AVEC 1 SEUL POD (évite race condition install)
  replicas: 1
  strategy:
    type: Recreate
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
        # DB Configuration (PORT 4632 - PgBouncer)
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
        # Modules
        - name: DOLI_MODULES
          value: "modFacture,modPropale,modStripe,modAbonnement,modAPI"
        # PHP Config
        - name: PHP_INI_DATE_TIMEZONE
          value: "Europe/Paris"
        - name: PHP_MEMORY_LIMIT
          value: "512M"
        - name: PHP_MAX_EXECUTION_TIME
          value: "300"
        - name: PHP_UPLOAD_MAX_FILESIZE
          value: "50M"
        - name: PHP_POST_MAX_SIZE
          value: "50M"
        volumeMounts:
        - name: documents
          mountPath: /var/www/documents
        # PROBES TRÈS PERMISSIVES (installation peut prendre du temps)
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 180
          periodSeconds: 60
          timeoutSeconds: 30
          failureThreshold: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 30
          failureThreshold: 10
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2000m"
            memory: "2Gi"
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
  labels:
    app: dolibarr
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    name: http
  selector:
    app: dolibarr
    component: web
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dolibarr-ingress
  namespace: erp
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    # TIMEOUTS TRÈS LONGS pour installation
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "900"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "900"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "900"
    # Upload files
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "4"
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
echo "═══ 5. Attente démarrage (3 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente que le pod démarre..."
sleep 30

echo "État du pod :"
kubectl get pods -n erp -l app=dolibarr -o wide

echo ""
echo "Attente supplémentaire (2min30) pour initialisation Dolibarr..."
sleep 150

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Vérification finale ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods :"
kubectl get pods -n erp -o wide
echo ""

POD=$(kubectl get pod -n erp -l app=dolibarr -o name | head -1)

echo "Logs (30 dernières lignes) :"
kubectl logs -n erp $POD --tail=30
echo ""

echo "Test HTTP direct (ClusterIP) :"
SVC_IP=$(kubectl get svc -n erp dolibarr -o jsonpath='{.spec.clusterIP}')
kubectl run test-http --image=curlimages/curl --restart=Never -n erp --rm -i -- \
  curl -I http://$SVC_IP:80 --max-time 10 2>&1 | head -10
echo ""

echo "Test HTTP via Ingress :"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://my.keybuzz.io --max-time 15 2>/dev/null || echo "000")
echo "Code HTTP : $HTTP_CODE"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK FIX TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📱 Accès Dolibarr :"
echo "  URL : http://my.keybuzz.io"
echo "  Login : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "🔐 Configuration DB :"
echo "  Host : 10.0.0.10"
echo "  Port : 4632 (PgBouncer SCRAM-SHA-256) ✓"
echo "  Database : dolibarr"
echo "  User : dolibarr"
echo ""
echo "⚙️ Changements appliqués :"
echo "  ✓ Port DB : 6432 → 4632 (PgBouncer)"
echo "  ✓ Replicas : 1 (évite race condition)"
echo "  ✓ Strategy : Recreate (pas RollingUpdate)"
echo "  ✓ Liveness : 180s initial, 60s period"
echo "  ✓ Readiness : 120s initial, 30s period"
echo "  ✓ Ingress timeouts : 900s (15 minutes)"
echo "  ✓ Resources : 500m/512Mi → 2000m/2Gi"
echo "  ✓ PHP : memory 512M, execution 300s"
echo ""

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo -e "$OK HTTP $HTTP_CODE - Dolibarr accessible !"
    echo ""
    echo "🎉 SUCCÈS - Prochaines étapes :"
    echo "  1. Ouvrir http://my.keybuzz.io"
    echo "  2. Si wizard : suivre l'installation"
    echo "  3. Configurer modules (Stripe, API, etc.)"
    echo "  4. Une fois stable, scaler à 2 replicas :"
    echo "     kubectl scale deployment dolibarr-web -n erp --replicas=2"
elif [ "$HTTP_CODE" = "202" ]; then
    echo -e "$WARN HTTP 202 - Dolibarr en cours d'installation"
    echo ""
    echo "⏳ Dolibarr s'initialise, attendez 2-3 minutes puis :"
    echo "  curl -I http://my.keybuzz.io"
    echo ""
    echo "Si toujours 202 après 5 minutes :"
    echo "  kubectl logs -n erp $POD --tail=50"
elif [ "$HTTP_CODE" = "504" ]; then
    echo -e "$KO HTTP 504 - Gateway Timeout persiste"
    echo ""
    echo "Diagnostic approfondi :"
    echo "  ./diagnostic_dolibarr_deep.sh"
    echo ""
    echo "Vérifier :"
    echo "  1. Base de données accessible :"
    echo "     PGPASSWORD='NEhobUmaJGdR7TL2MCXRB853' psql -h 10.0.0.10 -p 4632 -U dolibarr -d dolibarr -c 'SELECT 1;'"
    echo "  2. Logs pod :"
    echo "     kubectl logs -n erp $POD"
    echo "  3. Ressources suffisantes :"
    echo "     kubectl top pod -n erp"
else
    echo -e "$WARN HTTP $HTTP_CODE - Statut inattendu"
    echo ""
    echo "Vérifier :"
    echo "  kubectl describe pod -n erp $POD"
    echo "  kubectl logs -n erp $POD --tail=100"
fi

echo ""

exit 0
