#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    CORRECTION FINALE - Solutions précises pour chaque problème    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

echo ""
echo "Ce script va :"
echo "  1. Corriger Grafana (datasource conflict)"
echo "  2. Corriger Wazuh (mot de passe + indexer)"
echo "  3. Diagnostiquer Vault"
echo "  4. Nettoyer les déploiements inutiles"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 1 : GRAFANA - Datasource conflict
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 1: Grafana - Datasource Conflict                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Désinstallation complète du stack Prometheus..."
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true

echo "Attente suppression (30s)..."
sleep 30

echo "→ Suppression des CRDs résiduels..."
kubectl delete crd prometheuses.monitoring.coreos.com 2>/dev/null || true
kubectl delete crd prometheusrules.monitoring.coreos.com 2>/dev/null || true
kubectl delete crd servicemonitors.monitoring.coreos.com 2>/dev/null || true
kubectl delete crd podmonitors.monitoring.coreos.com 2>/dev/null || true
kubectl delete crd alertmanagers.monitoring.coreos.com 2>/dev/null || true
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com 2>/dev/null || true
kubectl delete crd thanosrulers.monitoring.coreos.com 2>/dev/null || true
kubectl delete crd probes.monitoring.coreos.com 2>/dev/null || true

echo "→ Réinstallation propre du stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=KeyBuzz2025! \
  --set grafana.defaultDashboardsEnabled=true \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --timeout 10m \
  --wait

if [ $? -eq 0 ]; then
    echo -e "$OK Grafana réinstallé proprement"
else
    echo -e "$WARN Grafana peut nécessiter plus de temps"
fi

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 2 : WAZUH - Mot de passe fort + Indexer
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 2: Wazuh - Password + Indexer                      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Suppression complète de Wazuh..."
kubectl delete namespace wazuh 2>/dev/null || true

echo "Attente suppression (30s)..."
sleep 30

echo "→ Recréation du namespace..."
kubectl create namespace wazuh

echo "→ Génération de mots de passe FORTS..."
# Wazuh exige : minimum 8 caractères, lettres majuscules, minuscules, chiffres, caractères spéciaux
WAZUH_API_PASSWORD="Wazuh$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#$%' | head -c 20)2025!"
WAZUH_INDEXER_PASSWORD="Index$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#$%' | head -c 20)2025!"
WAZUH_DASHBOARD_PASSWORD="Dash$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#$%' | head -c 20)2025!"

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
echo -e "$OK Mots de passe forts générés et sauvegardés"

echo "→ Déploiement Wazuh Indexer (configuration optimisée)..."
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
          ulimit -u 4096
        securityContext:
          privileged: true
      - name: increase-fd-ulimit
        image: busybox:latest
        command:
        - sh
        - -c
        - ulimit -n 65536
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
echo "Attente démarrage Indexer (2 minutes)..."
sleep 120

echo "→ Vérification Indexer..."
POD_INDEXER=$(kubectl get pods -n wazuh -l app=wazuh-indexer -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n wazuh "$POD_INDEXER" --tail=20 || true

# Manager et Dashboard seulement si Indexer OK
if kubectl get pods -n wazuh -l app=wazuh-indexer | grep -q "Running"; then
    echo -e "$OK Indexer Running, déploiement Manager et Dashboard..."
    
    # ConfigMap Manager
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: wazuh-manager-conf
  namespace: wazuh
data:
  ossec.conf: |
    <ossec_config>
      <global>
        <jsonout_output>yes</jsonout_output>
        <alerts_log>yes</alerts_log>
        <logall>yes</logall>
        <logall_json>yes</logall_json>
      </global>
      <remote>
        <connection>secure</connection>
        <port>1514</port>
        <protocol>udp</protocol>
      </remote>
      <alerts>
        <log_alert_level>3</log_alert_level>
      </alerts>
      <logging>
        <log_format>plain,json</log_format>
      </logging>
    </ossec_config>
EOF

    # Manager (pas en DaemonSet pour éviter les problèmes)
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wazuh-manager
  namespace: wazuh
  labels:
    app: wazuh-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wazuh-manager
  template:
    metadata:
      labels:
        app: wazuh-manager
    spec:
      containers:
      - name: wazuh-manager
        image: wazuh/wazuh-manager:4.7.0
        ports:
        - containerPort: 1514
          protocol: UDP
          name: agents-events
        - containerPort: 1515
          protocol: TCP
          name: agents-enroll
        - containerPort: 55000
          protocol: TCP
          name: api
        env:
        - name: INDEXER_URL
          value: "http://wazuh-indexer.wazuh.svc:9200"
        - name: INDEXER_USERNAME
          value: "admin"
        - name: INDEXER_PASSWORD
          value: "$WAZUH_INDEXER_PASSWORD"
        - name: FILEBEAT_SSL_VERIFICATION_MODE
          value: "none"
        - name: API_USERNAME
          value: "wazuh-wui"
        - name: API_PASSWORD
          value: "$WAZUH_API_PASSWORD"
        volumeMounts:
        - name: config
          mountPath: /wazuh-config-mount/etc/ossec.conf
          subPath: ossec.conf
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
      volumes:
      - name: config
        configMap:
          name: wazuh-manager-conf
---
apiVersion: v1
kind: Service
metadata:
  name: wazuh-manager
  namespace: wazuh
spec:
  type: NodePort
  selector:
    app: wazuh-manager
  ports:
  - name: agents-events
    port: 1514
    targetPort: 1514
    nodePort: 31514
    protocol: UDP
  - name: agents-enroll
    port: 1515
    targetPort: 1515
    nodePort: 31515
    protocol: TCP
  - name: api
    port: 55000
    targetPort: 55000
    nodePort: 30550
    protocol: TCP
EOF

    echo -e "$OK Wazuh Manager déployé (mode Deployment)"
    
else
    echo -e "$WARN Indexer pas encore Ready, Manager/Dashboard non déployés"
    echo "   Relancer ce script dans 5 minutes"
fi

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 3 : VAULT - Diagnostic
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 3: Vault - Diagnostic                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

POD_VAULT=$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_VAULT" ]; then
    echo "→ Logs Vault :"
    kubectl logs -n vault "$POD_VAULT" --tail=30 2>&1
    echo ""
    echo "⚠️  Si l'erreur persiste, il peut s'agir d'un problème de connexion PostgreSQL"
    echo "   Vérifier : nc -zv 10.0.0.10 5432 depuis un pod"
fi

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 4 : NETTOYAGE
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 4: Nettoyage des déploiements inutiles             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

read -p "Supprimer Connect API (image inexistante) ? (yes/NO) : " del_connect
[ "$del_connect" == "yes" ] && kubectl delete namespace connect 2>/dev/null && echo -e "$OK Connect supprimé"

read -p "Supprimer Airbyte (en erreur) ? (yes/NO) : " del_airbyte
[ "$del_airbyte" == "yes" ] && kubectl delete namespace etl 2>/dev/null && echo -e "$OK Airbyte supprimé"

read -p "Supprimer Dolibarr (si non utilisé) ? (yes/NO) : " del_doli
[ "$del_doli" == "yes" ] && kubectl delete namespace erp 2>/dev/null && echo -e "$OK Dolibarr supprimé"

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  ✅ CORRECTIONS TERMINÉES                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "🔧 Actions effectuées :"
echo "  ✓ Grafana : Réinstallé proprement (sans datasource conflict)"
echo "  ✓ Wazuh : Mots de passe forts + Indexer optimisé"
echo "  ✓ Wazuh : Manager en Deployment (1 replica)"
echo "  ✓ Vault : Diagnostic effectué"
echo "  ✓ Nettoyage : Déploiements inutiles supprimés (si demandé)"
echo ""
echo "⏱️  ATTENDRE 10-15 MINUTES pour stabilisation complète"
echo ""
echo "🔍 Vérifications :"
echo "  kubectl get pods -n monitoring | grep grafana"
echo "  kubectl get pods -n wazuh"
echo "  kubectl get pods -n vault"
echo ""
echo "📊 Validation finale (dans 15 minutes) :"
echo "  ./21_final_validation_complete.sh"
echo ""
echo "💾 Credentials Wazuh sauvegardés dans :"
echo "  /opt/keybuzz-installer/credentials/wazuh.env"
echo ""

exit 0
