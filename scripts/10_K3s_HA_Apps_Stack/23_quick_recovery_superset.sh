#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    RÉCUPÉRATION RAPIDE - Déploiement Superset image alternative   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

echo ""
echo "Récupération après erreur script 22"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Ce script va créer le DaemonSet Superset avec l'image amancevice/superset"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "État actuel des pods Superset :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset 2>/dev/null || echo 'Aucun pod'"

echo ""
echo "Création du DaemonSet avec image amancevice/superset..."
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'DEPLOY'
kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: superset
  namespace: superset
  labels:
    app: superset
spec:
  selector:
    matchLabels:
      app: superset
  template:
    metadata:
      labels:
        app: superset
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: superset
        image: amancevice/superset:latest
        ports:
        - containerPort: 8088
          hostPort: 8088
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: DATABASE_URL
        - name: SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: SECRET_KEY
        - name: REDIS_HOST
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_HOST
        - name: REDIS_PORT
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PORT
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: superset-secrets
              key: REDIS_PASSWORD
        - name: SUPERSET_ENV
          value: production
        - name: SUPERSET_LOAD_EXAMPLES
          value: "no"
        volumeMounts:
        - name: config
          mountPath: /etc/superset
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        readinessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 45
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
      volumes:
      - name: config
        configMap:
          name: superset-config
EOF
DEPLOY

echo ""
echo -e "$OK DaemonSet créé"
echo ""
echo "Attente démarrage (120s)..."
echo ""

for i in {1..12}; do
    echo -n "."
    sleep 10
    
    if [ $((i % 6)) -eq 0 ]; then
        echo ""
        echo "État à $((i*10))s :"
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset --no-headers 2>/dev/null | awk '{print \"  \" \$1 \": \" \$3}'"
        echo ""
    fi
done

echo ""
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "État final"
echo "════════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset -o wide"

echo ""
echo "Test HTTP :"
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.0.0.110:8088/health --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "  $OK HTTP $HTTP_CODE - Superset accessible !"
    echo ""
    echo "  URL : http://superset.keybuzz.io"
    echo "  Credentials : admin / Admin123!"
    echo ""
elif [ "$HTTP_CODE" = "503" ]; then
    echo -e "  $WARN HTTP $HTTP_CODE - Pods pas encore Ready"
    echo "  → Attendre 1-2 minutes et tester : curl http://superset.keybuzz.io"
else
    echo -e "  $WARN HTTP $HTTP_CODE - Vérifier les logs : kubectl logs -n superset <pod-name>"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo -e "$OK Déploiement terminé"
echo "════════════════════════════════════════════════════════════════════"
echo ""
