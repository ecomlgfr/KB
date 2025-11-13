#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX Grafana - Correction CrashLoopBackOff                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

echo ""
echo "Ce script va :"
echo "  1. Désinstaller kube-prometheus-stack actuel"
echo "  2. Réinstaller avec config simplifiée"
echo "  3. Sans persistence pour Grafana (résout les problèmes d'init)"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Désinstallation de l'ancienne stack ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
helm uninstall loki -n monitoring 2>/dev/null || true
helm uninstall promtail -n monitoring 2>/dev/null || true

# Attendre la suppression complète
sleep 10

echo -e "$OK Ancienne stack désinstallée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Suppression des PVC ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl delete pvc -n monitoring --all

echo -e "$OK PVC supprimés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Création nouvelle config simplifiée ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

mkdir -p /opt/keybuzz-installer/k8s-manifests/monitoring

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-simple.yaml <<'EOF'
# kube-prometheus-stack - config simplifiée
defaultRules:
  create: true

alertmanager:
  enabled: true
  alertmanagerSpec:
    replicas: 1
    storage: {}
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi

grafana:
  enabled: true
  adminPassword: "KeyBuzz2025!"
  # DÉSACTIVER LA PERSISTENCE (cause du crash)
  persistence:
    enabled: false
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - monitor.keybuzz.io
    path: /
    pathType: Prefix
  # Simplifier les datasources
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://kube-prometheus-stack-prometheus.monitoring:9090
          isDefault: true
          access: proxy

prometheus:
  enabled: true
  prometheusSpec:
    replicas: 1
    retention: 7d
    # DÉSACTIVER LA PERSISTENCE
    storageSpec: {}
    resources:
      requests:
        cpu: 200m
        memory: 1Gi
      limits:
        cpu: 1000m
        memory: 2Gi
    # Scrapes de base uniquement
    additionalScrapeConfigs: []

prometheusOperator:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

# Composants optionnels
nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true

# Désactiver ce qui n'est pas supporté
kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
EOF

echo -e "$OK Config simplifiée créée"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Déploiement kube-prometheus-stack (simplifié) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/prometheus-values-simple.yaml \
  --wait \
  --timeout 10m

echo -e "$OK kube-prometheus-stack déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Déploiement Loki (simplifié) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-simple.yaml <<'EOF'
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem

singleBinary:
  replicas: 1
  # DÉSACTIVER LA PERSISTENCE
  persistence:
    enabled: false
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

test:
  enabled: false

monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false
EOF

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/loki-values-simple.yaml \
  --wait \
  --timeout 5m

echo -e "$OK Loki déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Déploiement Promtail ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat > /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-simple.yaml <<'EOF'
config:
  clients:
    - url: http://loki.monitoring:3100/loki/api/v1/push

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 100m
    memory: 128Mi
EOF

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --values /opt/keybuzz-installer/k8s-manifests/monitoring/promtail-values-simple.yaml \
  --wait \
  --timeout 5m

echo -e "$OK Promtail déployé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Attente démarrage (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente démarrage complet..."
sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods monitoring :"
kubectl get pods -n monitoring
echo ""

echo "Services :"
kubectl get svc -n monitoring | grep -E '(prometheus|grafana|loki)'
echo ""

echo "Ingress :"
kubectl get ingress -n monitoring
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Monitoring Stack corrigé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Accès Grafana :"
echo "  URL : http://monitor.keybuzz.io"
echo "  Username : admin"
echo "  Password : KeyBuzz2025!"
echo ""
echo "⚠️ ATTENTION :"
echo "  Persistence DÉSACTIVÉE pour Grafana/Prometheus/Loki"
echo "  Les données seront perdues au redémarrage des pods"
echo "  C'est une config de développement/test"
echo ""
echo "  Pour activer la persistence plus tard :"
echo "    - Modifier les values.yaml"
echo "    - Ajouter storageSpec avec PVC"
echo "    - Faire un helm upgrade"
echo ""

exit 0
