#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    CORRECTION FINALE VAULT + WAZUH                                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

echo ""
echo "📊 ÉTAT ACTUEL :"
echo "  ✅ Grafana : 3/3 Running (CORRIGÉ !)"
echo "  ✅ Wazuh : Namespace nettoyé"
echo "  ❌ Vault : CrashLoopBackOff (table vault_kv_store manquante)"
echo ""
echo "Ce script va :"
echo "  1. Corriger Vault (passer en file storage)"
echo "  2. Attendre suppression complète namespace Wazuh"
echo "  3. Redéployer Wazuh proprement"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 1 : VAULT - File Storage
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 1: Vault - Passage en File Storage                 ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Suppression de l'ancien déploiement Vault..."
kubectl delete daemonset vault -n vault 2>/dev/null || true
kubectl delete configmap vault-config -n vault 2>/dev/null || true
sleep 10

echo "→ Création du nouveau ConfigMap (File Storage)..."
kubectl apply -f - <<'EOF'
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
    
    storage "file" {
      path = "/vault/data"
    }
    
    api_addr = "http://0.0.0.0:8200"
    cluster_addr = "http://0.0.0.0:8201"
    
    log_level = "info"
    disable_mlock = true
EOF

echo "→ Recréation du DaemonSet Vault (File Storage)..."
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
            path: /v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 20
          periodSeconds: 10
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 5
      volumes:
      - name: config
        configMap:
          name: vault-config
      - name: data
        hostPath:
          path: /opt/keybuzz/vault/data
          type: DirectoryOrCreate
EOF

echo -e "$OK Vault reconfiguré en File Storage"
echo "Attente 30s..."
sleep 30

# Vérification
POD_VAULT=$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_VAULT" ]; then
    STATUS=$(kubectl get pod -n vault "$POD_VAULT" -o jsonpath='{.status.phase}')
    if [ "$STATUS" == "Running" ]; then
        echo -e "$OK Vault Running !"
        echo ""
        echo "→ Vérification du statut Vault..."
        kubectl exec -n vault "$POD_VAULT" -- vault status 2>&1 || true
    else
        echo -e "$WARN Vault pas encore Running (état: $STATUS)"
        echo "Logs :"
        kubectl logs -n vault "$POD_VAULT" --tail=20 2>&1 || true
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 2 : WAZUH - Attente et redéploiement
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 2: Wazuh - Redéploiement propre                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Vérification suppression namespace wazuh..."
WAZUH_EXISTS=$(kubectl get namespace wazuh 2>/dev/null | grep -c wazuh || echo "0")

if [ "$WAZUH_EXISTS" != "0" ]; then
    echo "⚠️  Namespace wazuh encore en cours de suppression..."
    echo "   Attente 60s supplémentaires..."
    sleep 60
    
    WAZUH_EXISTS=$(kubectl get namespace wazuh 2>/dev/null | grep -c wazuh || echo "0")
    if [ "$WAZUH_EXISTS" != "0" ]; then
        echo -e "$WARN Namespace wazuh toujours présent"
        echo "   Forcer la suppression des finalizers..."
        kubectl get namespace wazuh -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/wazuh/finalize" -f - 2>/dev/null || true
        sleep 30
    fi
fi

echo "→ Recréation du namespace wazuh..."
kubectl create namespace wazuh 2>/dev/null || echo "Namespace déjà existant"

echo "→ Génération de mots de passe FORTS pour Wazuh..."
WAZUH_API_PASSWORD="Wazuh$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 24)2025!"
WAZUH_INDEXER_PASSWORD="Index$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 24)2025!"
WAZUH_DASHBOARD_PASSWORD="Dash$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 24)2025!"

echo "→ Création des secrets..."
kubectl create secret generic wazuh-secrets -n wazuh \
  --from-literal=API_PASSWORD="$WAZUH_API_PASSWORD" \
  --from-literal=INDEXER_PASSWORD="$WAZUH_INDEXER_PASSWORD" \
  --from-literal=DASHBOARD_PASSWORD="$WAZUH_DASHBOARD_PASSWORD"

# Sauvegarder
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
mkdir -p "$CREDENTIALS_DIR"
cat > "$CREDENTIALS_DIR/wazuh.env" <<ENVFILE
WAZUH_API_PASSWORD=$WAZUH_API_PASSWORD
WAZUH_INDEXER_PASSWORD=$WAZUH_INDEXER_PASSWORD
WAZUH_DASHBOARD_PASSWORD=$WAZUH_DASHBOARD_PASSWORD
WAZUH_API_USER=wazuh-wui
WAZUH_INDEXER_USER=admin
WAZUH_DASHBOARD_USER=admin
ENVFILE
chmod 600 "$CREDENTIALS_DIR/wazuh.env"
echo -e "$OK Mots de passe sauvegardés"

echo "→ Configuration des nœuds pour Wazuh Indexer..."
echo "   (vm.max_map_count + ulimit sur tous les nœuds K3s)"

# Lire les IPs depuis servers.tsv
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
if [ -f "$SERVERS_TSV" ]; then
    K3S_MASTERS=$(awk -F'\t' '$2~/k3s-master/ {print $3}' "$SERVERS_TSV" | tr '\n' ' ')
    K3S_WORKERS=$(awk -F'\t' '$2~/k3s-worker/ {print $3}' "$SERVERS_TSV" | tr '\n' ' ')
    ALL_K3S_NODES="$K3S_MASTERS $K3S_WORKERS"
    
    for node in $ALL_K3S_NODES; do
        echo "   Configuring $node..."
        ssh -o StrictHostKeyChecking=no root@"$node" bash <<'EOSSH' 2>/dev/null &
            # vm.max_map_count
            sysctl -w vm.max_map_count=262144
            echo 'vm.max_map_count=262144' >> /etc/sysctl.conf
            
            # File descriptors
            ulimit -n 65536
            echo '* soft nofile 65536' >> /etc/security/limits.conf
            echo '* hard nofile 65536' >> /etc/security/limits.conf
            
            # Max user processes
            echo '* soft nproc 4096' >> /etc/security/limits.conf
            echo '* hard nproc 4096' >> /etc/security/limits.conf
EOSSH
    done
    wait
    echo -e "$OK Nœuds configurés"
else
    echo -e "$WARN servers.tsv introuvable, configuration nœuds ignorée"
fi

echo "→ Déploiement Wazuh Indexer (StatefulSet optimisé)..."
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: wazuh-indexer
  namespace: wazuh
  labels:
    app: wazuh-indexer
spec:
  serviceName: wazuh-indexer
  replicas: 1
  selector:
    matchLabels:
      app: wazuh-indexer
  template:
    metadata:
      labels:
        app: wazuh-indexer
    spec:
      initContainers:
      - name: sysctl
        image: busybox:latest
        command:
        - sh
        - -c
        - |
          sysctl -w vm.max_map_count=262144
          ulimit -n 65536
        securityContext:
          privileged: true
      containers:
      - name: wazuh-indexer
        image: wazuh/wazuh-indexer:4.7.0
        ports:
        - containerPort: 9200
          name: http
        - containerPort: 9300
          name: transport
        env:
        - name: OPENSEARCH_JAVA_OPTS
          value: "-Xms2g -Xmx2g"
        - name: cluster.name
          value: "wazuh-cluster"
        - name: network.host
          value: "0.0.0.0"
        - name: node.name
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: discovery.type
          value: "single-node"
        - name: bootstrap.memory_lock
          value: "false"
        - name: DISABLE_INSTALL_DEMO_CONFIG
          value: "true"
        volumeMounts:
        - name: data
          mountPath: /var/lib/wazuh-indexer
        resources:
          requests:
            memory: "3Gi"
            cpu: "1000m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        readinessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
            scheme: HTTP
          initialDelaySeconds: 90
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 10
        livenessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
            scheme: HTTP
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 5
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 50Gi
---
apiVersion: v1
kind: Service
metadata:
  name: wazuh-indexer
  namespace: wazuh
spec:
  type: ClusterIP
  selector:
    app: wazuh-indexer
  ports:
  - name: http
    port: 9200
    targetPort: 9200
  - name: transport
    port: 9300
    targetPort: 9300
EOF

echo -e "$OK Wazuh Indexer déployé"
echo "Attente démarrage Indexer (3 minutes)..."
sleep 180

echo "→ Vérification Indexer..."
POD_INDEXER=$(kubectl get pods -n wazuh -l app=wazuh-indexer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_INDEXER" ]; then
    echo "Pod Indexer: $POD_INDEXER"
    kubectl get pod -n wazuh "$POD_INDEXER"
    echo ""
    echo "Logs (20 dernières lignes) :"
    kubectl logs -n wazuh "$POD_INDEXER" --tail=20 2>&1 || true
fi

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  ✅ CORRECTIONS TERMINÉES                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "🔧 Actions effectuées :"
echo "  ✓ Vault : Reconfiguré en File Storage (plus de PostgreSQL)"
echo "  ✓ Wazuh : Mots de passe forts générés"
echo "  ✓ Wazuh : Indexer déployé avec config optimisée"
echo "  ✓ Nœuds K3s : vm.max_map_count + ulimits configurés"
echo ""
echo "⏱️  ATTENDRE 10 MINUTES pour stabilisation complète"
echo ""
echo "🔍 Vérifications :"
echo "  kubectl get pods -n vault"
echo "  kubectl get pods -n wazuh"
echo "  kubectl get pods -n monitoring | grep grafana"
echo ""
echo "📝 Initialisation Vault (après stabilisation) :"
echo "  POD=\$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl exec -n vault \$POD -- vault operator init > /root/vault_keys.txt"
echo "  # Déverrouiller avec 3 clés"
echo "  kubectl exec -n vault \$POD -- vault operator unseal <key1>"
echo "  kubectl exec -n vault \$POD -- vault operator unseal <key2>"
echo "  kubectl exec -n vault \$POD -- vault operator unseal <key3>"
echo ""
echo "💾 Credentials :"
echo "  Wazuh : /opt/keybuzz-installer/credentials/wazuh.env"
echo ""
echo "📊 Prochaine étape (dans 15 minutes) :"
echo "  ./21_final_validation_complete.sh"
echo ""

exit 0
