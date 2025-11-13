#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              Correction finale - Suppression PVC n8n              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

MASTER_IP="10.0.0.100"

echo ""
echo "Problème identifié :"
echo "  → n8n : Le PVC contient une ancienne clé d'encryption"
echo "  → Chatwoot : Init container en cours (migrations DB)"
echo "  → Superset : Init container en cours (migrations DB)"
echo ""
echo "Solution :"
echo "  1. Supprimer le PVC n8n-data (anciennes données)"
echo "  2. Supprimer le déploiement n8n"
echo "  3. Recréer le déploiement n8n (PVC sera recréé propre)"
echo "  4. Attendre que Chatwoot et Superset terminent leurs migrations"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Correction n8n ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash <<'FIX_N8N'
set -u

echo "[$(date '+%F %T')] Suppression du déploiement n8n..."
kubectl delete deployment n8n -n n8n
echo "  ✓ Déploiement supprimé"

echo ""
echo "[$(date '+%F %T')] Suppression du PVC n8n-data (anciennes données)..."
kubectl delete pvc n8n-data -n n8n
echo "  ✓ PVC supprimé"

echo ""
echo "[$(date '+%F %T')] Recréation du déploiement n8n..."

# Récréer le PVC
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data
  namespace: n8n
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-path
EOF

echo "  ✓ PVC recréé"

# Récréer le déploiement
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  namespace: n8n
spec:
  replicas: 2
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      containers:
      - name: n8n
        image: n8nio/n8n:latest
        ports:
        - containerPort: 5678
          name: http
        env:
        - name: N8N_PORT
          value: "5678"
        - name: N8N_PROTOCOL
          value: "http"
        - name: N8N_HOST
          value: "n8n.keybuzz.io"
        envFrom:
        - secretRef:
            name: n8n-config
        volumeMounts:
        - name: data
          mountPath: /home/node/.n8n
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /
            port: 5678
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /
            port: 5678
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: n8n-data
EOF

echo "  ✓ Déploiement recréé"

FIX_N8N

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Attente et vérification (2 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente du démarrage des pods (120s)..."
sleep 120

echo ""
echo "État des pods :"
echo ""

ssh root@$MASTER_IP bash <<'CHECK'
for ns in n8n chatwoot litellm superset; do
    echo "━━━ $ns ━━━"
    kubectl get pods -n $ns -o wide
    echo ""
done
CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Correction appliquée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions effectuées :"
echo "  ✓ PVC n8n-data supprimé et recréé (propre)"
echo "  ✓ Déploiement n8n recréé"
echo "  ✓ Attente 2 minutes"
echo ""
echo "État attendu :"
echo "  → n8n : Doit être Running maintenant"
echo "  → Chatwoot : Migrations DB terminées → Running"
echo "  → Superset : Migrations DB terminées → Running"
echo "  → LiteLLM : Déjà Running ✓"
echo ""
echo "Si des pods sont toujours en Init ou Pending :"
echo "  kubectl logs -n <namespace> <pod-name> -c <init-container-name>"
echo ""
echo "Prochaine étape :"
echo "  ./apps_final_tests.sh"
echo ""

exit 0
