#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX SUPERSET - Image alternative avec psycopg2                 ║"
echo "║    Utilisation image amancevice/superset (drivers inclus)         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

# Charger PostgreSQL credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$WARN PostgreSQL credentials non trouvés"
    POSTGRES_PASSWORD="keybuzz2025"
fi

# Charger Redis credentials
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN Redis credentials non trouvés"
    REDIS_PASSWORD="keybuzz2025"
fi

echo ""
echo "Fix Superset - Image alternative"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Approche :"
echo "  → Utiliser amancevice/superset:latest"
echo "  → Cette image contient déjà psycopg2 et tous les drivers"
echo "  → Pas besoin d'installation au runtime"
echo ""

read -p "Appliquer ce fix ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Suppression DaemonSet actuel                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl delete daemonset superset -n superset"
echo "Attente suppression complète (15s)..."
sleep 15

echo -e "$OK DaemonSet supprimé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Déploiement avec image amancevice/superset           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Déploiement DaemonSet avec image alternative
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'DAEMONSET'
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
DAEMONSET

echo -e "$OK DaemonSet déployé avec image alternative"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Attente démarrage pods (120s)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for i in {1..12}; do
    echo -n "."
    sleep 10
    
    if [ $((i % 6)) -eq 0 ]; then
        echo ""
        echo "État à $((i*10))s :"
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset --no-headers | awk '{print \"  \" \$1 \": \" \$3}'"
        echo ""
    fi
done

echo ""
echo ""
echo "État final des pods :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset -o wide"

echo ""
echo "Test HTTP Superset :"
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.0.0.110:8088/health --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo -e "  $OK HTTP $HTTP_CODE - Superset accessible"
else
    echo -e "  $WARN HTTP $HTTP_CODE - En attente démarrage"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK FIX APPLIQUÉ (image alternative)"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Image utilisée : amancevice/superset:latest"
echo "  → Contient psycopg2 pré-installé"
echo "  → Démarrage plus rapide"
echo ""
echo "URL : http://superset.keybuzz.io"
echo "Credentials : admin / Admin123!"
echo ""
echo "Si les pods ne sont pas encore Ready :"
echo "  → Attendre 1-2 minutes supplémentaires"
echo "  → Vérifier : kubectl get pods -n superset"
echo "  → Logs : kubectl logs -n superset <pod-name>"
echo ""
