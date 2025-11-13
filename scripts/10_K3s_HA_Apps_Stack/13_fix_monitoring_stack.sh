#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Correction Monitoring Stack                              ║"
echo "║    (Fix Prometheus PVC + Loki + Grafana)                          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script corrige :"
echo "  1. Suppression des déploiements en erreur"
echo "  2. Correction configuration Loki (mode SingleBinary)"
echo "  3. Correction Prometheus (sans PVC volumeClaimTemplate)"
echo "  4. Utilisation Promtail via kube-prometheus-stack"
echo "  5. Redéploiement propre"
echo ""

read -p "Corriger le monitoring stack ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Nettoyage des déploiements en erreur ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Suppression des releases Helm en erreur..."
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || echo "  kube-prometheus-stack déjà absent"
helm uninstall loki -n monitoring 2>/dev/null || echo "  loki déjà absent"
helm uninstall promtail -n monitoring 2>/dev/null || echo "  promtail déjà absent"

echo ""
echo "Suppression des PVC en pending..."
kubectl delete pvc -n monitoring prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 2>/dev/null || echo "  PVC déjà absent"

echo ""
echo "Attente cleanup (15s)..."
sleep 15

echo -e "$OK Nettoyage terminé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Création values kube-prometheus-stack CORRIGÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/monitoring

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-fixed.yaml <<'EOF'
# kube-prometheus-stack values CORRIGÉ
prometheus:
  prometheusSpec:
    retention: 15d
    # SUPPRESSION du volumeClaimTemplate qui cause le PVC pending
    # On utilise le stockage éphémère ou emptyDir pour Prometheus
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
  
  # Configuration datasources
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
          isDefault: true
          access: proxy

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

echo -e "$OK Values Prometheus CORRIGÉS créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Redéploiement kube-prometheus-stack ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-fixed.yaml \
  --wait \
  --timeout 10m

if [ $? -eq 0 ]; then
    echo -e "$OK kube-prometheus-stack redéployé avec succès"
else
    echo -e "$KO Échec du déploiement kube-prometheus-stack"
    echo "Vérifiez les logs : kubectl get pods -n monitoring"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Déploiement Loki CORRIGÉ (mode SingleBinary) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-fixed.yaml <<'EOF'
# Loki en mode SingleBinary (sans simple scalable)
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

# Désactiver tous les autres composants
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
  enabled: false
EOF

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-fixed.yaml \
  --wait \
  --timeout 5m

if [ $? -eq 0 ]; then
    echo -e "$OK Loki redéployé avec succès"
else
    echo -e "$WARN Loki peut nécessiter plus de temps"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Déploiement Promtail ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-fixed.yaml <<'EOF'
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

# DaemonSet sur tous les nœuds
daemonset:
  enabled: true
EOF

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-fixed.yaml \
  --wait \
  --timeout 5m

echo -e "$OK Promtail déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Re-création des règles d'alerte ═══"
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
        
        # Ingress 5xx rate
        - alert: IngressHighErrorRate
          expr: rate(nginx_ingress_controller_requests{status=~"5.."}[5m]) > 10
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Taux d'erreurs 5xx élevé sur Ingress"
            description: "Plus de 10 erreurs 5xx/min sur l'Ingress NGINX"
        
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

echo -e "$OK Règles d'alerte recréées"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Attente démarrage complet (3 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente stabilisation des pods..."
sleep 180

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Vérification finale ═══"
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
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$GRAFANA_SVC 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo -e "  Grafana : $OK (HTTP $HTTP_CODE)"
else
    echo -e "  Grafana : $WARN (HTTP $HTTP_CODE)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Monitoring Stack corrigé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Accès Grafana :"
echo "  URL      : http://monitor.keybuzz.io"
echo "  Username : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "🔍 Vérification complémentaire :"
echo "  kubectl get pods -n monitoring"
echo "  kubectl logs -n monitoring -l app.kubernetes.io/name=grafana"
echo ""
echo "Si erreur 503 persiste :"
echo "  1. Vérifier que l'Ingress controller fonctionne :"
echo "     kubectl get pods -n ingress-nginx"
echo "  2. Vérifier les endpoints :"
echo "     kubectl get endpoints -n monitoring"
echo "  3. Tester directement le service :"
echo "     kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo "     Puis ouvrir http://localhost:3000"
echo ""
echo "Prochaine étape (une fois monitoring OK) :"
echo "  ./14_deploy_connect_api.sh"
echo ""

exit 0
