#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    CORRECTION COMPLÈTE - Tous les problèmes détectés              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

echo ""
echo "Ce script va corriger :"
echo "  1. Vault (CrashLoopBackOff)"
echo "  2. Wazuh Dashboard (non créé)"
echo "  3. Wazuh Manager (CrashLoopBackOff)"
echo "  4. Scripts de backup (credentials manquants)"
echo "  5. Grafana (CrashLoopBackOff)"
echo ""

read -p "Lancer les corrections ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 1 : VAULT
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 1: Vault                                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Charger credentials PostgreSQL
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO Credentials PostgreSQL introuvables"
    exit 1
fi

DB_PASSWORD="${POSTGRES_PASSWORD:-keybuzz2025}"

echo "→ Suppression de l'ancien déploiement Vault..."
kubectl delete daemonset vault -n vault 2>/dev/null || true
kubectl delete configmap vault-config -n vault 2>/dev/null || true
sleep 5

echo "→ Création du nouveau ConfigMap Vault (corrigé)..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: vault
data:
  vault.hcl: |
    ui = true
    
    listener "tcp" {
      address = "0.0.0.0:8200"
      tls_disable = 1
    }
    
    storage "postgresql" {
      connection_url = "postgresql://vault:${DB_PASSWORD}@10.0.0.10:5432/vault?sslmode=disable"
      ha_enabled = "true"
      max_parallel = "128"
    }
    
    api_addr = "http://0.0.0.0:8200"
    cluster_addr = "http://0.0.0.0:8201"
    
    log_level = "info"
    disable_mlock = true
EOF

echo "→ Recréation du DaemonSet Vault..."
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vault
  namespace: vault
  labels:
    app: vault
spec:
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: vault
        image: hashicorp/vault:1.16
        ports:
        - containerPort: 8200
          hostPort: 8200
          name: http
        - containerPort: 8201
          hostPort: 8201
          name: cluster
        env:
        - name: SKIP_SETCAP
          value: "true"
        - name: VAULT_ADDR
          value: "http://0.0.0.0:8200"
        - name: VAULT_API_ADDR
          value: "http://0.0.0.0:8200"
        - name: VAULT_CLUSTER_ADDR
          value: "http://0.0.0.0:8201"
        command:
        - vault
        - server
        - -config=/vault/config/vault.hcl
        volumeMounts:
        - name: config
          mountPath: /vault/config
        - name: data
          mountPath: /vault/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        readinessProbe:
          httpGet:
            path: /v1/sys/health?standbyok=true
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 2
        livenessProbe:
          httpGet:
            path: /v1/sys/health?standbyok=true
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 3
      volumes:
      - name: config
        configMap:
          name: vault-config
      - name: data
        emptyDir: {}
EOF

echo -e "$OK Vault corrigé, attente 30s..."
sleep 30

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 2 : WAZUH DASHBOARD
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 2: Wazuh Dashboard                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Création du Wazuh Dashboard (ports corrigés)..."
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wazuh-dashboard
  namespace: wazuh
  labels:
    app: wazuh-dashboard
spec:
  selector:
    matchLabels:
      app: wazuh-dashboard
  template:
    metadata:
      labels:
        app: wazuh-dashboard
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: wazuh-dashboard
        image: wazuh/wazuh-dashboard:4.7.0
        ports:
        - containerPort: 443
          hostPort: 443
          name: https
        env:
        - name: INDEXER_URL
          value: "https://wazuh-indexer.wazuh.svc:9200"
        - name: WAZUH_API_URL
          value: "https://wazuh-manager.wazuh.svc:55000"
        - name: API_USERNAME
          value: "wazuh-wui"
        - name: API_PASSWORD
          valueFrom:
            secretKeyRef:
              name: wazuh-secrets
              key: API_PASSWORD
        - name: OPENSEARCH_HOSTS
          value: "https://wazuh-indexer.wazuh.svc:9200"
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        readinessProbe:
          httpGet:
            path: /app/wazuh
            port: 443
            scheme: HTTPS
          initialDelaySeconds: 60
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /app/wazuh
            port: 443
            scheme: HTTPS
          initialDelaySeconds: 90
          periodSeconds: 30
EOF

echo -e "$OK Wazuh Dashboard corrigé"

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 3 : WAZUH MANAGER (problème Indexer URL)
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 3: Wazuh Manager                                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Vérification Wazuh Manager..."
POD_MANAGER=$(kubectl get pods -n wazuh -l app=wazuh-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$POD_MANAGER" ]; then
    echo "→ Logs du Manager :"
    kubectl logs -n wazuh "$POD_MANAGER" --tail=20 2>/dev/null || echo "Pas de logs disponibles"
    
    echo ""
    echo "⚠️  Wazuh Manager nécessite que l'Indexer soit opérationnel"
    echo "   Attente de la stabilisation de l'Indexer (60s)..."
    sleep 60
    
    echo "→ Redémarrage des pods Manager..."
    kubectl rollout restart daemonset/wazuh-manager -n wazuh
else
    echo -e "$WARN Aucun pod Manager trouvé"
fi

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 4 : SCRIPTS DE BACKUP
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 4: Scripts de backup                                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Récupérer les IPs
IP_DB_MASTER=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
IP_REDIS01=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
IP_MINIO=$(awk -F'\t' '$2=="minio-01" {print $3}' "$SERVERS_TSV")

# Charger credentials
source "$CREDENTIALS_DIR/postgres.env"
source "$CREDENTIALS_DIR/redis.env"

if [ -f "$CREDENTIALS_DIR/secrets.json" ]; then
    MINIO_ACCESS_KEY=$(jq -r '.minio.root_user' "$CREDENTIALS_DIR/secrets.json")
    MINIO_SECRET_KEY=$(jq -r '.minio.root_password' "$CREDENTIALS_DIR/secrets.json")
else
    echo -e "$KO Credentials MinIO introuvables"
    exit 1
fi

echo "→ Correction script backup PostgreSQL..."
ssh -o StrictHostKeyChecking=no root@"$IP_DB_MASTER" bash <<EOSSH
cat > /opt/keybuzz/scripts/backup_postgresql.sh <<'PGBACKUP'
#!/usr/bin/env bash
set -u
set -o pipefail

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/pg_backup_\$TIMESTAMP"
MINIO_BUCKET="keybuzz-backups/postgresql"

mkdir -p "\$BACKUP_DIR"

# Backup toutes les bases
DATABASES="postgres n8n chatwoot litellm superset qdrant vault"

for DB in \$DATABASES; do
    echo "Backup \$DB..."
    PGPASSWORD="\$POSTGRES_PASSWORD" pg_dump -h localhost -U postgres -d "\$DB" | gzip > "\$BACKUP_DIR/\${DB}_\${TIMESTAMP}.sql.gz"
done

# Backup globals
PGPASSWORD="\$POSTGRES_PASSWORD" pg_dumpall -h localhost -U postgres --globals-only | gzip > "\$BACKUP_DIR/globals_\${TIMESTAMP}.sql.gz"

# Upload vers MinIO
mc alias set keybuzz http://${IP_MINIO}:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
mc cp -r "\$BACKUP_DIR/" keybuzz/\$MINIO_BUCKET/

# Nettoyer
rm -rf "\$BACKUP_DIR"

echo "✓ Backup PostgreSQL terminé : \$TIMESTAMP"
PGBACKUP

chmod +x /opt/keybuzz/scripts/backup_postgresql.sh

# Créer le fichier credentials s'il n'existe pas
if [ ! -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    mkdir -p /opt/keybuzz-installer/credentials
    cat > /opt/keybuzz-installer/credentials/postgres.env <<ENVFILE
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
ENVFILE
fi

echo "✓ Script PostgreSQL corrigé"
EOSSH

echo "→ Correction script backup Redis..."
ssh -o StrictHostKeyChecking=no root@"$IP_REDIS01" bash <<EOSSH
cat > /opt/keybuzz/scripts/backup_redis.sh <<'REDISBACKUP'
#!/usr/bin/env bash
set -u
set -o pipefail

# Charger les credentials
source /opt/keybuzz-installer/credentials/redis.env

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/redis_backup_\$TIMESTAMP"
MINIO_BUCKET="keybuzz-backups/redis"

mkdir -p "\$BACKUP_DIR"

# Trigger BGSAVE
redis-cli -a "\$REDIS_PASSWORD" BGSAVE

# Attendre que le BGSAVE soit terminé
sleep 5

# Copier le RDB
cp /var/lib/redis/dump.rdb "\$BACKUP_DIR/dump_\${TIMESTAMP}.rdb" 2>/dev/null || cp /var/lib/redis/6379/dump.rdb "\$BACKUP_DIR/dump_\${TIMESTAMP}.rdb"

# Compresser
gzip "\$BACKUP_DIR/dump_\${TIMESTAMP}.rdb"

# Upload vers MinIO
mc alias set keybuzz http://${IP_MINIO}:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
mc cp "\$BACKUP_DIR/dump_\${TIMESTAMP}.rdb.gz" keybuzz/\$MINIO_BUCKET/

# Nettoyer
rm -rf "\$BACKUP_DIR"

echo "✓ Backup Redis terminé : \$TIMESTAMP"
REDISBACKUP

chmod +x /opt/keybuzz/scripts/backup_redis.sh

# Créer le fichier credentials s'il n'existe pas
if [ ! -f /opt/keybuzz-installer/credentials/redis.env ]; then
    mkdir -p /opt/keybuzz-installer/credentials
    cat > /opt/keybuzz-installer/credentials/redis.env <<ENVFILE
REDIS_PASSWORD=${REDIS_PASSWORD}
ENVFILE
fi

echo "✓ Script Redis corrigé"
EOSSH

echo "→ Correction script backup K3s..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOSSH
cat > /opt/keybuzz/scripts/backup_k3s.sh <<'K3SBACKUP'
#!/usr/bin/env bash
set -u
set -o pipefail

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/k3s_backup_\$TIMESTAMP"
MINIO_BUCKET="keybuzz-backups/k3s-resources"

mkdir -p "\$BACKUP_DIR"

echo "Backup resources K8s..."

# Backup des resources
kubectl get all --all-namespaces -o yaml > "\$BACKUP_DIR/all-resources.yaml"
kubectl get secrets --all-namespaces -o yaml > "\$BACKUP_DIR/secrets.yaml"
kubectl get configmaps --all-namespaces -o yaml > "\$BACKUP_DIR/configmaps.yaml"
kubectl get pvc --all-namespaces -o yaml > "\$BACKUP_DIR/pvc.yaml"
kubectl get ingress --all-namespaces -o yaml > "\$BACKUP_DIR/ingress.yaml"
kubectl get svc --all-namespaces -o yaml > "\$BACKUP_DIR/services.yaml"

# Compresser
cd "\$BACKUP_DIR" && tar -czf "k3s_resources_\${TIMESTAMP}.tar.gz" *.yaml

# Upload vers MinIO
mc alias set keybuzz http://${IP_MINIO}:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
mc cp "k3s_resources_\${TIMESTAMP}.tar.gz" keybuzz/\$MINIO_BUCKET/

# Nettoyer
cd / && rm -rf "\$BACKUP_DIR"

echo "✓ Backup K3s terminé : \$TIMESTAMP"
K3SBACKUP

chmod +x /opt/keybuzz/scripts/backup_k3s.sh
echo "✓ Script K3s corrigé"
EOSSH

echo -e "$OK Scripts de backup corrigés"

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 5 : GRAFANA
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 5: Grafana                                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Analyse du problème Grafana..."
POD_GRAFANA=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$POD_GRAFANA" ]; then
    echo "→ Logs Grafana :"
    kubectl logs -n monitoring "$POD_GRAFANA" -c grafana --tail=30 2>/dev/null || echo "Pas de logs Grafana"
    
    echo ""
    echo "→ Suppression du pod Grafana pour le recréer..."
    kubectl delete pod "$POD_GRAFANA" -n monitoring
    
    echo "Attente 30s..."
    sleep 30
else
    echo -e "$WARN Aucun pod Grafana trouvé"
fi

# ═══════════════════════════════════════════════════════════════════
# VÉRIFICATION FINALE
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ VÉRIFICATION FINALE                                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Attente stabilisation (60s)..."
sleep 60

echo ""
echo "→ État des pods Vault :"
kubectl get pods -n vault
echo ""

echo "→ État des pods Wazuh :"
kubectl get pods -n wazuh
echo ""

echo "→ État Grafana :"
kubectl get pods -n monitoring | grep grafana
echo ""

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  ✅ CORRECTIONS TERMINÉES                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "🔧 Actions effectuées :"
echo "  ✓ Vault : ConfigMap recréé avec credentials"
echo "  ✓ Wazuh Dashboard : Ports corrigés (443:443)"
echo "  ✓ Wazuh Manager : Redémarrage"
echo "  ✓ Scripts backup : Credentials ajoutés"
echo "  ✓ Grafana : Pod recréé"
echo ""
echo "⏱️  Attendre 5-10 minutes pour la stabilisation complète"
echo ""
echo "🔍 Vérifications recommandées :"
echo "  kubectl get pods -n vault"
echo "  kubectl get pods -n wazuh"
echo "  kubectl logs -n vault <vault-pod>"
echo "  kubectl logs -n wazuh <wazuh-manager-pod>"
echo ""
echo "📝 Initialisation Vault (si pods OK) :"
echo "  POD=\$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl exec -n vault \$POD -- vault operator init"
echo ""

exit 0
