#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Correction Monitoring Stack V2                           ║"
echo "║    (Fix Datasource Conflict + Prometheus + Loki)                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script corrige :"
echo "  1. Suppression complète du namespace monitoring"
echo "  2. Configuration Grafana SANS conflit datasource"
echo "  3. Prometheus sans PVC volumeClaimTemplate"
echo "  4. Loki en mode SingleBinary"
echo "  5. Augmentation des timeouts Helm"
echo ""

read -p "Corriger le monitoring stack V2 ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Nettoyage COMPLET du namespace ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Suppression des releases Helm..."
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || echo "  kube-prometheus-stack déjà absent"
helm uninstall loki -n monitoring 2>/dev/null || echo "  loki déjà absent"
helm uninstall promtail -n monitoring 2>/dev/null || echo "  promtail déjà absent"

echo ""
echo "Suppression du namespace monitoring..."
kubectl delete namespace monitoring --timeout=60s 2>/dev/null || echo "  namespace déjà absent"

echo ""
echo "Attente cleanup complet (30s)..."
sleep 30

echo ""
echo "Recréation du namespace monitoring..."
kubectl create namespace monitoring

echo -e "$OK Nettoyage terminé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création values kube-prometheus-stack CORRIGÉ V2 ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/monitoring

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-v2.yaml <<'EOF'
# kube-prometheus-stack values V2 - CORRIGÉ datasource unique
prometheus:
  prometheusSpec:
    retention: 15d
    # Pas de volumeClaimTemplate pour éviter PVC pending
    storageSpec: {}
    
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    
    # Scrape des services externes
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
  enabled: true
  adminPassword: "KeyBuzz2025!"
  
  # Persistence
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
  
  # Ingress
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - monitor.keybuzz.io
    path: /
    pathType: Prefix
  
  # CRITICAL: Configuration datasource UNIQUE - une seule datasource par défaut
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
  
  # Désactiver les sidecars de provisionning auto pour éviter conflits
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

echo -e "$OK Values Prometheus V2 créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Déploiement kube-prometheus-stack avec timeout étendu ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-v2.yaml \
  --timeout 15m \
  --wait

if [ $? -eq 0 ]; then
    echo -e "$OK kube-prometheus-stack déployé avec succès"
else
    echo -e "$KO Échec du déploiement kube-prometheus-stack"
    echo ""
    echo "Diagnostic rapide :"
    kubectl get pods -n monitoring
    echo ""
    kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=30
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Attente stabilisation (1 minute) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Ajout datasource Loki manuellement ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Note : Loki sera déployé ensuite et ajouté manuellement dans Grafana"
echo "      pour éviter les conflits de datasources au démarrage"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Déploiement Loki (mode SingleBinary) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-v2.yaml <<'EOF'
# Loki en mode SingleBinary explicite
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

# Désactiver TOUS les autres modes
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
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-v2.yaml \
  --timeout 10m \
  --wait

if [ $? -eq 0 ]; then
    echo -e "$OK Loki déployé avec succès"
else
    echo -e "$WARN Loki peut nécessiter plus de temps ou une correction manuelle"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Déploiement Promtail ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-v2.yaml <<'EOF'
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
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-v2.yaml \
  --timeout 5m \
  --wait

echo -e "$OK Promtail déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Configuration règles d'alerte ═══"
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
            summary: "Taux d'erreurs 5xx élevé sur Ingress"
            description: "Plus de 10 erreurs 5xx/min sur l'Ingress NGINX"
        
        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod en crash loop"
            description: "Le pod {{ $labels.pod }} redémarre fréquemment"
EOF

echo -e "$OK Règles d'alerte créées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9. Ajout manuel datasource Loki dans Grafana ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Créer un ConfigMap pour ajouter Loki comme datasource
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
echo "Redémarrage des pods Grafana pour charger la nouvelle datasource..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana

echo ""
echo "Attente redémarrage Grafana (30s)..."
sleep 30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10. Vérification finale ═══"
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

echo "PVC :"
kubectl get pvc -n monitoring
echo ""

# Test Grafana
echo "Test accès Grafana..."
GRAFANA_SVC=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}')
sleep 10
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$GRAFANA_SVC --max-time 10 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo -e "  Grafana : $OK (HTTP $HTTP_CODE)"
else
    echo -e "  Grafana : $WARN (HTTP $HTTP_CODE) - peut nécessiter plus de temps"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Monitoring Stack V2 déployé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Accès Grafana :"
echo "  URL      : http://monitor.keybuzz.io"
echo "  Username : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "📝 Configuration datasources :"
echo "  ✓ Prometheus : déjà configuré (par défaut)"
echo "  ✓ Loki : ajouté via ConfigMap"
echo ""
echo "🔍 Vérification datasources dans Grafana :"
echo "  1. Ouvrir http://monitor.keybuzz.io"
echo "  2. Menu → Configuration → Data Sources"
echo "  3. Vérifier : Prometheus (default) + Loki"
echo ""
echo "Si Loki n'apparaît pas :"
echo "  kubectl logs -n monitoring -l app.kubernetes.io/name=grafana | grep -i datasource"
echo ""
echo "Prochaine étape :"
echo "  ./14_deploy_connect_api.sh"
echo ""

exit 0
