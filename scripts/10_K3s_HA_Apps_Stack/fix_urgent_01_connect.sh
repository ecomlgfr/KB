#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX URGENT Connect API - Correction ErrImageNeverPull          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

echo ""
echo "Problème détecté : ErrImageNeverPull"
echo "Cause : Le tag d'image ne correspond pas entre build et import"
echo ""
echo "Solution : Supprimer imagePullPolicy: Never"
echo ""

read -p "Appliquer le fix ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Suppression des pods actuels ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete deployment connect-api -n connect

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Nouveau déploiement SANS imagePullPolicy ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connect-api
  namespace: connect
  labels:
    app: connect-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: connect-api
  template:
    metadata:
      labels:
        app: connect-api
    spec:
      nodeSelector:
        role: apps
      containers:
      - name: connect-api
        image: keybuzz-connect:1.0.0
        # PAS de imagePullPolicy - laisse K3s décider
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: connect-db-secret
              key: DATABASE_URL
        - name: REDIS_URL
          value: "redis://10.0.0.10:6379/0"
        - name: ENVIRONMENT
          value: "production"
        livenessProbe:
          httpGet:
            path: /live
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
EOF

echo -e "$OK Deployment recréé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Attente démarrage (30s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 30

kubectl get pods -n connect -o wide

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Si toujours en erreur, vérifier que l'image existe :"
echo "  ssh k3s-worker-01 'ctr -n k8s.io images ls | grep connect'"
echo ""
echo "Test HTTP :"
echo "  curl http://connect.keybuzz.io/health"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

exit 0
