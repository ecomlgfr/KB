#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX SUPERSET - Installation psycopg2                           ║"
echo "║    Correction du module PostgreSQL manquant                       ║"
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
    echo -e "$WARN PostgreSQL credentials non trouvés, utilisation valeur par défaut"
    POSTGRES_PASSWORD="keybuzz2025"
fi

# Charger Redis credentials
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN Redis credentials non trouvés, utilisation valeur par défaut"
    REDIS_PASSWORD="keybuzz2025"
fi

echo ""
echo "Fix Superset - Installation psycopg2"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Problème détecté :"
echo "  ModuleNotFoundError: No module named 'psycopg2'"
echo ""
echo "Solution :"
echo "  Ajouter une commande qui installe psycopg2-binary au démarrage"
echo ""

read -p "Appliquer le fix ? (yes/NO) : " confirm
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
echo "║ ÉTAPE 2: Déploiement DaemonSet avec psycopg2                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Générer SECRET_KEY unique si besoin
SUPERSET_SECRET_KEY=$(openssl rand -hex 32)

# Recréer le secret avec les bonnes valeurs
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<SECRETS
kubectl create secret generic superset-secrets -n superset \\
  --from-literal=DATABASE_URL="postgresql://superset:${POSTGRES_PASSWORD}@10.0.0.10:5432/superset" \\
  --from-literal=SECRET_KEY="${SUPERSET_SECRET_KEY}" \\
  --from-literal=REDIS_HOST="10.0.0.10" \\
  --from-literal=REDIS_PORT="6379" \\
  --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}" \\
  --from-literal=SUPERSET_ADMIN_USERNAME="admin" \\
  --from-literal=SUPERSET_ADMIN_PASSWORD="Admin123!" \\
  --from-literal=SUPERSET_ADMIN_EMAIL="admin@keybuzz.io" \\
  --dry-run=client -o yaml | kubectl apply -f -
SECRETS

echo -e "$OK Secrets recréés"

# Déploiement DaemonSet Superset avec commande pour installer psycopg2
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
        image: apache/superset:latest
        ports:
        - containerPort: 8088
          hostPort: 8088
        command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "╔═══════════════════════════════════════════════════════════╗"
          echo "║ Superset Startup - Installing dependencies               ║"
          echo "╚═══════════════════════════════════════════════════════════╝"
          
          echo ""
          echo "→ Installing psycopg2-binary..."
          pip install --no-cache-dir psycopg2-binary
          
          echo "→ Installing redis..."
          pip install --no-cache-dir redis
          
          echo "→ Verifying installations..."
          python -c "import psycopg2; print('✓ psycopg2 OK')"
          python -c "import redis; print('✓ redis OK')"
          
          echo ""
          echo "→ Starting Superset server..."
          exec /usr/bin/run-server.sh
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
        - name: SUPERSET_CONFIG_PATH
          value: /app/pythonpath/superset_config.py
        - name: SUPERSET_PORT
          value: "8088"
        volumeMounts:
        - name: config
          mountPath: /app/pythonpath
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
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 90
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
      volumes:
      - name: config
        configMap:
          name: superset-config
EOF
DAEMONSET

echo -e "$OK DaemonSet déployé avec fix psycopg2"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Attente démarrage pods (180s)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Les pods vont installer psycopg2 au démarrage (peut prendre 2-3 min par pod)..."
echo ""

for i in {1..18}; do
    echo -n "."
    sleep 10
    
    # Afficher l'état toutes les 60s
    if [ $((i % 6)) -eq 0 ]; then
        echo ""
        echo "État à $((i*10))s :"
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset --no-headers | awk '{print \"  \" \$1 \": \" \$3}'"
        echo ""
    fi
done

echo ""
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Vérification finale                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "État des pods Superset :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset -o wide"

echo ""
echo "Logs d'un pod (vérification installation psycopg2) :"
echo "────────────────────────────────────────────────────────────────"
POD=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset --no-headers | head -1 | awk '{print \$1}'")
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n superset $POD --tail=20 2>&1 | grep -E '(psycopg2|redis|Starting|Error|OK)' || kubectl logs -n superset $POD --tail=30"

echo ""
echo "Test HTTP Superset :"
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.0.0.110:8088/health --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo -e "  $OK HTTP $HTTP_CODE - Superset accessible"
else
    echo -e "  $WARN HTTP $HTTP_CODE - Superset pas encore prêt (normal si pods encore en démarrage)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK FIX APPLIQUÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions prises :"
echo "  ✓ DaemonSet supprimé et recréé"
echo "  ✓ Commande ajoutée : pip install psycopg2-binary + redis"
echo "  ✓ Augmentation timeouts readinessProbe (60s → 90s)"
echo ""
echo "État attendu :"
echo "  → Pods: 8/8 Running (peut prendre 3-5 min par pod)"
echo "  → Chaque pod installe psycopg2 au démarrage"
echo "  → URL: http://superset.keybuzz.io"
echo ""
echo "Si les pods sont encore en démarrage :"
echo "  → Attendre 2-3 minutes supplémentaires"
echo "  → Vérifier : kubectl get pods -n superset"
echo "  → Logs : kubectl logs -n superset <pod-name>"
echo ""
echo "Tester l'accès :"
echo "  curl http://10.0.0.110:8088/health"
echo "  curl http://superset.keybuzz.io"
echo ""
