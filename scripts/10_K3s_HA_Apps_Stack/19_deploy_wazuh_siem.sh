#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Wazuh SIEM                                   ║"
echo "║    (Manager + Indexer + Dashboard en DaemonSet)                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/wazuh_deploy_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Déploiement Wazuh SIEM - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

echo -n "→ Cluster K3s ... "
if kubectl get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

echo ""
echo "⚠️  NOTE IMPORTANTE :"
echo "  Wazuh est une solution SIEM complexe qui nécessite :"
echo "  - 3 composants : Manager, Indexer (Elasticsearch), Dashboard"
echo "  - Ressources importantes (RAM/CPU/Stockage)"
echo "  - Configuration des agents sur chaque serveur"
echo ""
echo "Configuration :"
echo "  Manager Port    : 1514 (événements), 1515 (enrollment), 55000 (API)"
echo "  Indexer Port    : 9200"
echo "  Dashboard Port  : 443"
echo "  URL externe     : https://siem.keybuzz.io"
echo ""

read -p "Déployer Wazuh SIEM ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: CRÉATION NAMESPACE
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Création namespace                                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl create namespace wazuh 2>/dev/null || true
echo -e "$OK Namespace wazuh créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: CRÉATION SECRETS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Création secrets                                      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Générer les passwords
WAZUH_API_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
WAZUH_INDEXER_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
WAZUH_DASHBOARD_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

kubectl create secret generic wazuh-secrets -n wazuh \
  --from-literal=API_PASSWORD="$WAZUH_API_PASSWORD" \
  --from-literal=INDEXER_PASSWORD="$WAZUH_INDEXER_PASSWORD" \
  --from-literal=DASHBOARD_PASSWORD="$WAZUH_DASHBOARD_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secrets Wazuh créés"

# Sauvegarder les credentials
cat > "$CREDENTIALS_DIR/wazuh.env" <<ENVFILE
WAZUH_API_PASSWORD=$WAZUH_API_PASSWORD
WAZUH_INDEXER_PASSWORD=$WAZUH_INDEXER_PASSWORD
WAZUH_DASHBOARD_PASSWORD=$WAZUH_DASHBOARD_PASSWORD
WAZUH_API_USER=admin
WAZUH_INDEXER_USER=admin
WAZUH_DASHBOARD_USER=admin
ENVFILE

chmod 600 "$CREDENTIALS_DIR/wazuh.env"
echo -e "$OK Credentials sauvegardés dans $CREDENTIALS_DIR/wazuh.env"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: DÉPLOIEMENT WAZUH INDEXER (Elasticsearch)
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Déploiement Wazuh Indexer                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
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
        - sysctl
        - -w
        - vm.max_map_count=262144
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
          value: "-Xms1g -Xmx1g"
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
        volumeMounts:
        - name: data
          mountPath: /var/lib/wazuh-indexer
        resources:
          requests:
            memory: "2Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        readinessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
          initialDelaySeconds: 60
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
          initialDelaySeconds: 90
          periodSeconds: 30
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

# Attendre que l'indexer soit prêt
echo "Attente démarrage Indexer (90s)..."
sleep 90

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: DÉPLOIEMENT WAZUH MANAGER
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Déploiement Wazuh Manager                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wazuh-manager
  namespace: wazuh
  labels:
    app: wazuh-manager
spec:
  selector:
    matchLabels:
      app: wazuh-manager
  template:
    metadata:
      labels:
        app: wazuh-manager
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: wazuh-manager
        image: wazuh/wazuh-manager:4.7.0
        ports:
        - containerPort: 1514
          hostPort: 1514
          protocol: UDP
          name: agents-events
        - containerPort: 1515
          hostPort: 1515
          protocol: TCP
          name: agents-enroll
        - containerPort: 55000
          hostPort: 55000
          protocol: TCP
          name: api
        env:
        - name: INDEXER_URL
          value: "https://wazuh-indexer.wazuh.svc:9200"
        - name: INDEXER_USERNAME
          value: "admin"
        - name: INDEXER_PASSWORD
          valueFrom:
            secretKeyRef:
              name: wazuh-secrets
              key: INDEXER_PASSWORD
        - name: FILEBEAT_SSL_VERIFICATION_MODE
          value: "none"
        - name: API_USERNAME
          value: "wazuh-wui"
        - name: API_PASSWORD
          valueFrom:
            secretKeyRef:
              name: wazuh-secrets
              key: API_PASSWORD
        volumeMounts:
        - name: config
          mountPath: /wazuh-config-mount/etc/ossec.conf
          subPath: ossec.conf
        - name: data
          mountPath: /var/ossec/data
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        livenessProbe:
          exec:
            command:
            - /var/ossec/bin/wazuh-control
            - status
          initialDelaySeconds: 60
          periodSeconds: 30
      volumes:
      - name: config
        configMap:
          name: wazuh-manager-conf
      - name: data
        emptyDir: {}
---
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

echo -e "$OK Wazuh Manager déployé"

# Attendre le Manager
echo "Attente démarrage Manager (60s)..."
sleep 60

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: DÉPLOIEMENT WAZUH DASHBOARD
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Déploiement Wazuh Dashboard                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
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
          hostPort: 8443
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
---
apiVersion: v1
kind: Service
metadata:
  name: wazuh-dashboard
  namespace: wazuh
spec:
  type: NodePort
  selector:
    app: wazuh-dashboard
  ports:
  - name: https
    port: 443
    targetPort: 443
    nodePort: 30443
    protocol: TCP
EOF

echo -e "$OK Wazuh Dashboard déployé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: CRÉATION INGRESS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Création Ingress                                      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wazuh
  namespace: wazuh
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: siem.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: wazuh-dashboard
            port:
              number: 443
EOF

echo -e "$OK Ingress Wazuh créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 7: VÉRIFICATION
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 7: Attente et vérification (90s)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

sleep 90

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods Wazuh :"
kubectl get pods -n wazuh -o wide
echo ""

echo "Services :"
kubectl get svc -n wazuh
echo ""

echo "Ingress :"
kubectl get ingress -n wazuh
echo ""

echo "StatefulSets :"
kubectl get statefulset -n wazuh
echo ""

echo "DaemonSets :"
kubectl get daemonset -n wazuh
echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║             ✅ Wazuh SIEM déployé avec succès                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Accès :"
echo "  Dashboard URL : https://siem.keybuzz.io"
echo "  Username      : admin"
echo "  Password      : $WAZUH_DASHBOARD_PASSWORD"
echo ""
echo "🔧 API :"
echo "  URL           : https://wazuh-manager.wazuh.svc:55000"
echo "  Username      : wazuh-wui"
echo "  Password      : $WAZUH_API_PASSWORD"
echo ""
echo "📡 Agents :"
echo "  Manager IP    : <worker_node_ip>"
echo "  Events Port   : 31514 (UDP)"
echo "  Enroll Port   : 31515 (TCP)"
echo ""
echo "⚠️  INSTALLATION DES AGENTS :"
echo ""
echo "Sur chaque serveur à monitorer, installer l'agent :"
echo ""
echo "  # Ubuntu/Debian"
echo "  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && chmod 644 /usr/share/keyrings/wazuh.gpg"
echo "  echo \"deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main\" | tee -a /etc/apt/sources.list.d/wazuh.list"
echo "  apt-get update"
echo "  WAZUH_MANAGER='<worker_node_ip>' apt-get install wazuh-agent"
echo "  systemctl daemon-reload"
echo "  systemctl enable wazuh-agent"
echo "  systemctl start wazuh-agent"
echo ""
echo "📚 Documentation :"
echo "  https://documentation.wazuh.com/"
echo ""
echo "Prochaine étape :"
echo "  ./20_configure_backups.sh (à créer)"
echo ""

exit 0
