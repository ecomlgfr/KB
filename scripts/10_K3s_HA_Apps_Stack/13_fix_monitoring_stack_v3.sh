#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Correction Monitoring Stack V3                           ║"
echo "║    (Fix avec attente complète suppression namespace)              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script corrige :"
echo "  1. Suppression complète du namespace monitoring"
echo "  2. ATTENTE que le namespace soit réellement supprimé"
echo "  3. Configuration Grafana SANS conflit datasource"
echo "  4. Prometheus sans PVC volumeClaimTemplate"
echo "  5. Loki en mode SingleBinary"
echo ""

read -p "Corriger le monitoring stack V3 ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Suppression des releases Helm ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || echo "  kube-prometheus-stack déjà absent"
helm uninstall loki -n monitoring 2>/dev/null || echo "  loki déjà absent"
helm uninstall promtail -n monitoring 2>/dev/null || echo "  promtail déjà absent"

echo -e "$OK Releases Helm supprimées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Suppression du namespace monitoring ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Vérifier si le namespace existe
if kubectl get namespace monitoring >/dev/null 2>&1; then
    echo "Suppression du namespace monitoring..."
    kubectl delete namespace monitoring --timeout=120s 2>/dev/null &
    
    # Attendre que le namespace soit vraiment supprimé
    echo "Attente de la suppression complète du namespace..."
    TIMEOUT=180
    ELAPSED=0
    
    while kubectl get namespace monitoring >/dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo -e "$KO Timeout : le namespace n'a pas été supprimé après 3 minutes"
            echo ""
            echo "Le namespace est peut-être bloqué par des finalizers."
            echo "Actions à effectuer manuellement :"
            echo ""
            echo "  # Forcer la suppression :"
            echo "  kubectl get namespace monitoring -o json > /tmp/monitoring-ns.json"
            echo "  # Éditer et supprimer la section 'finalizers' dans le JSON"
            echo "  kubectl replace --raw \"/api/v1/namespaces/monitoring/finalize\" -f /tmp/monitoring-ns.json"
            echo ""
            exit 1
        fi
        
        echo "  Namespace encore en cours de suppression... ($ELAPSED/$TIMEOUT secondes)"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    
    echo -e "$OK Namespace complètement supprimé"
else
    echo "  Namespace monitoring déjà absent"
fi

echo ""
echo "Attente sécurité supplémentaire (10s)..."
sleep 10

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Création du nouveau namespace monitoring ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tentative de création avec retry
MAX_RETRY=5
RETRY=0

while [ $RETRY -lt $MAX_RETRY ]; do
    if kubectl create namespace monitoring 2>/dev/null; then
        echo -e "$OK Namespace monitoring créé"
        break
    else
        RETRY=$((RETRY + 1))
        if [ $RETRY -lt $MAX_RETRY ]; then
            echo "  Tentative $RETRY/$MAX_RETRY échouée, nouvelle tentative dans 10s..."
            sleep 10
        else
            echo -e "$KO Impossible de créer le namespace après $MAX_RETRY tentatives"
            exit 1
        fi
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Création values kube-prometheus-stack CORRIGÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/monitoring

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-v3.yaml <<'EOF'
# kube-prometheus-stack values V3
prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec: {}
    
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    
    additionalScrapeConfigs:
      - job_name: 'patroni'
        static_configs:
          - targets:
            - '10.0.0.120:8008'
            - '10.0.0.121:8008'
            - '10.0.0.122:8008'
      
      - job_name: 'haproxy'
        static_configs:
          - targets:
            - '10.0.0.11:8404'
            - '10.0.0.12:8405'
      
      - job_name: 'redis-sentinel'
        static_configs:
          - targets:
            - '10.0.0.123:26379'
            - '10.0.0.124:26379'
            - '10.0.0.125:26379'
      
      - job_name: 'rabbitmq'
        static_configs:
          - targets:
            - '10.0.0.126:15692'
            - '10.0.0.127:15692'
            - '10.0.0.128:15692'

grafana:
  enabled: true
  adminPassword: "KeyBuzz2025!"
  
  persistence:
    enabled: true
    size: 10Gi
  
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
  
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - monitor.keybuzz.io
    path: /
    pathType: Prefix
  
  # CRITICAL: UNE SEULE datasource par défaut
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
          access: proxy
          isDefault: true
          editable: true
  
  # Désactiver sidecars datasources pour éviter conflit
  sidecar:
    datasources:
      enabled: false
    dashboards:
      enabled: true

alertmanager:
  enabled: true
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1Gi

prometheusOperator:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true

kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
EOF

echo -e "$OK Values Prometheus créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Déploiement kube-prometheus-stack ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Installation en cours (timeout 15 minutes)..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-v3.yaml \
  --timeout 15m \
  --wait

if [ $? -eq 0 ]; then
    echo -e "$OK kube-prometheus-stack déployé"
else
    echo -e "$KO Échec du déploiement"
    echo ""
    kubectl get pods -n monitoring
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Attente stabilisation Grafana (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Déploiement Loki ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-v3.yaml <<'EOF'
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: 2024-01-01
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 30Gi
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi

backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0

monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false

test:
  enabled: false

gateway:
  enabled: true
  replicas: 1
EOF

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-v3.yaml \
  --timeout 10m \
  --wait

if [ $? -eq 0 ]; then
    echo -e "$OK Loki déployé"
else
    echo -e "$WARN Loki peut nécessiter plus de temps"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Déploiement Promtail ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-v3.yaml <<'EOF'
config:
  clients:
    - url: http://loki-gateway.monitoring.svc/loki/api/v1/push

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

daemonset:
  enabled: true
EOF

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-v3.yaml \
  --timeout 5m \
  --wait

echo -e "$OK Promtail déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. Ajout datasource Loki dans Grafana ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-loki
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki-gateway.monitoring.svc:80
        isDefault: false
        editable: true
        jsonData:
          maxLines: 1000
EOF

echo -e "$OK Datasource Loki ajoutée"

echo ""
echo "Redémarrage Grafana..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana
kubectl rollout status deployment -n monitoring kube-prometheus-stack-grafana --timeout=120s

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10. Configuration alertes ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: keybuzz-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: keybuzz.infrastructure
      interval: 30s
      rules:
        - alert: IngressHighErrorRate
          expr: rate(nginx_ingress_controller_requests{status=~"5.."}[5m]) > 10
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Taux d'erreurs 5xx élevé"
        
        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod en crash loop"
EOF

echo -e "$OK Alertes configurées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 11. Vérification finale ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods monitoring :"
kubectl get pods -n monitoring -o wide
echo ""

echo "Services :"
kubectl get svc -n monitoring
echo ""

echo "Ingress :"
kubectl get ingress -n monitoring
echo ""

# Test Grafana
echo "Test accès Grafana..."
GRAFANA_SVC=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
sleep 10
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$GRAFANA_SVC --max-time 10 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo -e "  Grafana : $OK (HTTP $HTTP_CODE)"
else
    echo -e "  Grafana : $WARN (HTTP $HTTP_CODE)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Monitoring Stack V3 déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Accès Grafana :"
echo "  URL      : http://monitor.keybuzz.io"
echo "  Username : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "🔍 Vérifications :"
echo "  kubectl get pods -n monitoring"
echo "  curl -I http://monitor.keybuzz.io"
echo ""
echo "📈 Datasources :"
echo "  ✓ Prometheus (default)"
echo "  ✓ Loki"
echo ""
echo "Prochaine étape :"
echo "  ./14_deploy_connect_api.sh"
echo ""

exit 0
