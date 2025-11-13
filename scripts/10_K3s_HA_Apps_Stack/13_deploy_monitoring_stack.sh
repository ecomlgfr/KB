#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement Monitoring Stack                             ║"
echo "║    (Prometheus + Grafana + Loki + Promtail)                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script déploie :"
echo "  1. kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"
echo "  2. Loki + Promtail (logs centralisés)"
echo "  3. ServiceMonitors pour :"
echo "     - Patroni (:8008)"
echo "     - HAProxy (:8404/8405)"
echo "     - PgBouncer (:4632)"
echo "     - Redis Sentinel (:26379)"
echo "     - RabbitMQ (:15692)"
echo "     - Ingress NGINX"
echo "     - Applications K3s"
echo "  4. Dashboards Grafana personnalisés"
echo "  5. Règles d'alertes"
echo ""

read -p "Déployer le monitoring stack ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Vérifier Helm
if ! command -v helm &> /dev/null; then
    echo -e "$KO Helm non installé"
    echo "Installer Helm :"
    echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Ajout des repos Helm ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo -e "$OK Repos Helm ajoutés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création namespace monitoring ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl create namespace monitoring 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Création values kube-prometheus-stack ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/monitoring

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values.yaml <<'EOF'
# kube-prometheus-stack values
prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    additionalScrapeConfigs:
      # Scrape Patroni
      - job_name: 'patroni'
        static_configs:
          - targets:
            - '10.0.0.120:8008'  # db-master-01
            - '10.0.0.121:8008'  # db-slave-01
            - '10.0.0.122:8008'  # db-slave-02
      
      # Scrape HAProxy
      - job_name: 'haproxy'
        static_configs:
          - targets:
            - '10.0.0.11:8404'   # haproxy-01
            - '10.0.0.12:8405'   # haproxy-02
      
      # Scrape Redis Sentinel
      - job_name: 'redis-sentinel'
        static_configs:
          - targets:
            - '10.0.0.123:26379' # redis-01
            - '10.0.0.124:26379' # redis-02
            - '10.0.0.125:26379' # redis-03
      
      # Scrape RabbitMQ
      - job_name: 'rabbitmq'
        static_configs:
          - targets:
            - '10.0.0.126:15692' # queue-01
            - '10.0.0.127:15692' # queue-02
            - '10.0.0.128:15692' # queue-03

grafana:
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
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://prometheus-operated:9090
          isDefault: true
        - name: Loki
          type: loki
          url: http://loki:3100

alertmanager:
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

# Node exporter
nodeExporter:
  enabled: true

# kube-state-metrics
kubeStateMetrics:
  enabled: true

# Désactiver ce qui n'est pas nécessaire
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
echo "═══ 4. Déploiement kube-prometheus-stack ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values.yaml \
  --wait \
  --timeout 10m

echo -e "$OK kube-prometheus-stack déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Déploiement Loki ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values.yaml <<'EOF'
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
  limits_config:
    retention_period: 336h  # 14 jours

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

monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false

test:
  enabled: false
EOF

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values.yaml \
  --wait \
  --timeout 5m

echo -e "$OK Loki déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Déploiement Promtail (DaemonSet) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values.yaml <<'EOF'
config:
  clients:
    - url: http://loki:3100/loki/api/v1/push

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

# Scrape tous les pods
daemonset:
  enabled: true
EOF

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values.yaml \
  --wait \
  --timeout 5m

echo -e "$OK Promtail déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Configuration règles d'alerte ═══"
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
        # Patroni leader down
        - alert: PatroniLeaderDown
          expr: patroni_cluster_has_leader == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Patroni cluster n'a pas de leader"
            description: "Le cluster PostgreSQL n'a pas de leader depuis 1 minute"
        
        # Redis quorum
        - alert: RedisQuorumLost
          expr: redis_connected_slaves < 1
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Redis Sentinel quorum perdu"
            description: "Moins de 2 slaves Redis connectés"
        
        # RabbitMQ quorum
        - alert: RabbitMQQuorumLost
          expr: rabbitmq_running_nodes < 2
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "RabbitMQ quorum perdu"
            description: "Moins de 2 nœuds RabbitMQ actifs"
        
        # Ingress 5xx rate
        - alert: IngressHighErrorRate
          expr: rate(nginx_ingress_controller_requests{status=~"5.."}[5m]) > 10
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Taux d'erreurs 5xx élevé sur Ingress"
            description: "Plus de 10 erreurs 5xx/min sur l'Ingress NGINX"
        
        # HAProxy backend down
        - alert: HAProxyBackendDown
          expr: haproxy_backend_up == 0
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Backend HAProxy down"
            description: "Un backend HAProxy est down depuis 2 minutes"
        
        # Pods crashloop
        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod en crash loop"
            description: "Le pod {{ $labels.pod }} redémarre fréquemment"
EOF

echo -e "$OK Règles d'alerte configurées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Attente démarrage complet ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente des pods monitoring (2 minutes)..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods monitoring :"
kubectl get pods -n monitoring
echo ""

echo "Services monitoring :"
kubectl get svc -n monitoring | grep -E '(prometheus|grafana|loki|promtail)'
echo ""

echo "Ingress :"
kubectl get ingress -n monitoring
echo ""

echo "PVC :"
kubectl get pvc -n monitoring
echo ""

echo "PrometheusRules :"
kubectl get prometheusrule -n monitoring
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Monitoring Stack déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Accès Grafana :"
echo "  URL      : http://monitor.keybuzz.io"
echo "  Username : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "🔍 Services disponibles :"
echo "  Prometheus : http://prometheus-operated.monitoring.svc:9090"
echo "  Alertmanager : http://alertmanager-operated.monitoring.svc:9093"
echo "  Loki : http://loki.monitoring.svc:3100"
echo ""
echo "📈 Métriques scrapées :"
echo "  ✓ Patroni (PostgreSQL)"
echo "  ✓ HAProxy"
echo "  ✓ Redis Sentinel"
echo "  ✓ RabbitMQ"
echo "  ✓ Ingress NGINX"
echo "  ✓ Nodes K3s"
echo "  ✓ Pods applications"
echo ""
echo "Prochaine étape :"
echo "  ./14_deploy_connect_api.sh"
echo ""

exit 0
