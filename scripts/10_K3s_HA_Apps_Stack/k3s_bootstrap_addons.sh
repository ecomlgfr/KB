#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              K3S HA CLUSTER - Bootstrap Addons                     ║"
echo "║         (Metrics-server, préparation Ingress DaemonSet)            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

# Vérifications préalables
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
mkdir -p "$LOG_DIR" "$CREDENTIALS_DIR"

LOG_FILE="$LOG_DIR/k3s_bootstrap_addons.log"

# Récupérer l'IP du master-01
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable"
    exit 1
fi

echo "" | tee -a "$LOG_FILE"
echo "═══ Configuration ═══" | tee -a "$LOG_FILE"
echo "  Master-01     : $IP_MASTER01" | tee -a "$LOG_FILE"
echo "  Log           : $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Vérifier que le cluster est opérationnel
echo "Vérification du cluster..." | tee -a "$LOG_FILE"
NODE_COUNT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes --no-headers 2>/dev/null | wc -l" || echo "0")

if [ "$NODE_COUNT" -lt 8 ]; then
    echo -e "$KO Cluster incomplet : $NODE_COUNT/8 nœuds" | tee -a "$LOG_FILE"
    echo "Lancez d'abord : ./k3s_workers_join.sh" | tee -a "$LOG_FILE"
    exit 1
fi

echo -e "  $OK Cluster opérationnel : $NODE_COUNT nœuds" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

read -p "Installer les addons K3s ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Metrics Server
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 1/3 : Installation Metrics Server ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'METRICS_SERVER' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Installation metrics-server..."

# Télécharger le manifest
curl -sL https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml -o /tmp/metrics-server.yaml

# Patcher pour accepter les certificats auto-signés
sed -i '/args:/a \        - --kubelet-insecure-tls' /tmp/metrics-server.yaml

# Appliquer
kubectl apply -f /tmp/metrics-server.yaml >/dev/null 2>&1

echo "[$(date '+%F %T')] Attente démarrage metrics-server..."
sleep 10

# Vérifier que metrics-server est Running
for i in {1..30}; do
    if kubectl get pods -n kube-system | grep metrics-server | grep -q "Running"; then
        echo "[$(date '+%F %T')] Metrics-server Running"
        break
    fi
    sleep 2
done

# Test
if kubectl top nodes >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] Metrics-server opérationnel"
else
    echo "[$(date '+%F %T')] WARN : Metrics-server pas encore prêt (normal, attendre 30s)"
fi

mkdir -p /opt/keybuzz/k3s/addons
echo "OK" > /opt/keybuzz/k3s/addons/metrics-server.state
METRICS_SERVER

if [ $? -eq 0 ]; then
    echo -e "  $OK Metrics-server installé" | tee -a "$LOG_FILE"
else
    echo -e "  $KO Erreur metrics-server" | tee -a "$LOG_FILE"
fi

sleep 3

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Configuration réseau pour Ingress DaemonSet
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 2/3 : Configuration UFW pour Ingress (NodePort) ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Architecture Ingress NGINX prévue :" | tee -a "$LOG_FILE"
echo "  - Mode : DaemonSet + hostNetwork:true" | tee -a "$LOG_FILE"
echo "  - HTTP NodePort  : 31695 (mappé depuis port 80 des LBs)" | tee -a "$LOG_FILE"
echo "  - HTTPS NodePort : 32720 (mappé depuis port 443 des LBs)" | tee -a "$LOG_FILE"
echo "  - Load Balancers : lb-keybuzz-1 (10.0.0.5) + lb-keybuzz-2 (10.0.0.6)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "NOTE : L'installation de l'Ingress se fera via ./09_deploy_ingress_daemonset.sh" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Récupérer les IPs des workers
WORKER_IPS=()
for i in {1..5}; do
    ip=$(awk -F'\t' -v h="k3s-worker-0$i" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -n "$ip" ]; then
        WORKER_IPS+=("$ip")
    fi
done

if [ ${#WORKER_IPS[@]} -ne 5 ]; then
    echo -e "$WARN Seulement ${#WORKER_IPS[@]}/5 workers trouvés" | tee -a "$LOG_FILE"
fi

echo "Ouverture des ports NodePort sur les workers..." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

for ip in "${WORKER_IPS[@]}"; do
    echo "  Configuration UFW sur $ip..." | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'UFW_CONFIG' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Ouverture ports NodePort pour Ingress..."

if command -v ufw &>/dev/null; then
    # HTTP NodePort
    ufw allow from 10.0.0.0/16 to any port 31695 proto tcp comment 'K3s Ingress HTTP' 2>/dev/null || true
    # HTTPS NodePort
    ufw allow from 10.0.0.0/16 to any port 32720 proto tcp comment 'K3s Ingress HTTPS' 2>/dev/null || true
    
    echo "[$(date '+%F %T')] Ports 31695/32720 ouverts"
else
    echo "[$(date '+%F %T')] UFW non installé, skip"
fi
UFW_CONFIG
    
    echo "" | tee -a "$LOG_FILE"
done

# Créer le fichier d'état sur master-01 (pas localement)
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "mkdir -p /opt/keybuzz/k3s/addons && echo 'OK' > /opt/keybuzz/k3s/addons/ufw-nodeport.state" 2>/dev/null

echo -e "  $OK Configuration UFW NodePort terminée" | tee -a "$LOG_FILE"

sleep 3

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Test avec pod simple
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ ÉTAPE 3/3 : Test avec deployment simple ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'TEST_DEPLOYMENT' | tee -a "$LOG_FILE"
set -u
set -o pipefail

echo "[$(date '+%F %T')] Création namespace de test..."
kubectl create namespace test-k3s --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

echo "[$(date '+%F %T')] Déploiement pod de test..."

# Créer un deployment test simple
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
  namespace: test-k3s
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: test-nginx
  namespace: test-k3s
spec:
  selector:
    app: test-nginx
  ports:
  - port: 80
    targetPort: 80
EOF

echo "[$(date '+%F %T')] Attente démarrage pods..."
sleep 10

# Vérifier que les pods sont Running
for i in {1..30}; do
    RUNNING_COUNT=$(kubectl get pods -n test-k3s 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$RUNNING_COUNT" -eq 2 ]; then
        echo "[$(date '+%F %T')] Pods de test Running (2/2)"
        break
    fi
    sleep 2
done

# Créer le fichier d'état avant le test HTTP
mkdir -p /opt/keybuzz/k3s/addons
echo "OK" > /opt/keybuzz/k3s/addons/test-deployment.state

# Test HTTP via service ClusterIP
echo "[$(date '+%F %T')] Test HTTP via service..."
if kubectl run test-curl --image=curlimages/curl:latest --rm -i --restart=Never -n test-k3s -- curl -s -o /dev/null -w "%{http_code}" http://test-nginx 2>/dev/null | grep -q "200"; then
    echo "[$(date '+%F %T')] HTTP 200 OK via service"
else
    echo "[$(date '+%F %T')] WARN : Service non accessible (peut nécessiter quelques secondes)"
fi

echo "[$(date '+%F %T')] Test deployment créé"
exit 0
TEST_DEPLOYMENT

if [ $? -eq 0 ]; then
    echo -e "  $OK Deployment de test créé" | tee -a "$LOG_FILE"
else
    echo -e "  $KO Erreur deployment de test" | tee -a "$LOG_FILE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Vérification finale et résumé
# ═══════════════════════════════════════════════════════════════════════════

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "═══ VÉRIFICATION FINALE ═══" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

sleep 5

echo "État des addons :" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Pods système
echo "Pods système (kube-system) :" | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n kube-system -o wide" 2>/dev/null | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "Pods test :" | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n test-k3s -o wide" 2>/dev/null | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "Services test :" | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get svc -n test-k3s" 2>/dev/null | tee -a "$LOG_FILE"

# Vérifier l'état global
echo "" | tee -a "$LOG_FILE"
METRICS_OK=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "[ -f /opt/keybuzz/k3s/addons/metrics-server.state ] && echo 1 || echo 0")
UFW_OK=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "[ -f /opt/keybuzz/k3s/addons/ufw-nodeport.state ] && echo 1 || echo 0")
TEST_OK=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "[ -f /opt/keybuzz/k3s/addons/test-deployment.state ] && echo 1 || echo 0")

SUCCESS_COUNT=$((METRICS_OK + UFW_OK + TEST_OK))

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Résumé des addons installés :" | tee -a "$LOG_FILE"
echo "  - Metrics-server     : $([ "$METRICS_OK" = "1" ] && echo -e "$OK" || echo -e "$KO")" | tee -a "$LOG_FILE"
echo "  - UFW NodePort       : $([ "$UFW_OK" = "1" ] && echo -e "$OK" || echo -e "$KO")" | tee -a "$LOG_FILE"
echo "  - Test deployment    : $([ "$TEST_OK" = "1" ] && echo -e "$OK" || echo -e "$KO")" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$SUCCESS_COUNT" -ge 2 ]; then
    echo -e "$OK BOOTSTRAP TERMINÉ AVEC SUCCÈS" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Cluster K3s HA prêt pour la suite !" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "🎯 ARCHITECTURE ACTUELLE :" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "  K3s Cluster HA :" | tee -a "$LOG_FILE"
    echo "    - 3 Masters (control-plane + etcd intégré)" | tee -a "$LOG_FILE"
    echo "    - 5 Workers (agents)" | tee -a "$LOG_FILE"
    echo "    - API K3s : via lb-keybuzz-1 (10.0.0.5) / lb-keybuzz-2 (10.0.0.6)" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "  Infrastructure Data (validée) :" | tee -a "$LOG_FILE"
    echo "    - PostgreSQL 16 + Patroni RAFT (1 leader + 2 replicas)" | tee -a "$LOG_FILE"
    echo "    - HAProxy (haproxy-01/02) + PgBouncer SCRAM-SHA-256" | tee -a "$LOG_FILE"
    echo "    - LB Database : 10.0.0.10 (ports 5432/5433/6432)" | tee -a "$LOG_FILE"
    echo "    - Redis Sentinel HA (3 nœuds)" | tee -a "$LOG_FILE"
    echo "    - RabbitMQ Quorum (3 nœuds)" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "📋 STRINGS DE CONNEXION (pour les apps) :" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "  PostgreSQL (via PgBouncer - recommandé) :" | tee -a "$LOG_FILE"
    echo "    postgresql://postgres:PASSWORD@10.0.0.10:6432/votre_database" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "  Redis (via HAProxy TCP) :" | tee -a "$LOG_FILE"
    echo "    redis://10.0.0.10:6379" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "  RabbitMQ (AMQP) :" | tee -a "$LOG_FILE"
    echo "    amqp://admin:PASSWORD@10.0.0.10:5672" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Commandes utiles :" | tee -a "$LOG_FILE"
    echo "  ssh root@$IP_MASTER01 kubectl get nodes" | tee -a "$LOG_FILE"
    echo "  ssh root@$IP_MASTER01 kubectl top nodes" | tee -a "$LOG_FILE"
    echo "  ssh root@$IP_MASTER01 kubectl get pods -A" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Pour nettoyer le namespace de test :" | tee -a "$LOG_FILE"
    echo "  ssh root@$IP_MASTER01 kubectl delete namespace test-k3s" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "⏭️  PROCHAINES ÉTAPES (dans l'ordre) :" | tee -a "$LOG_FILE"
    echo "  1. ./00_check_prerequisites.sh       # Vérifier prérequis" | tee -a "$LOG_FILE"
    echo "  2. ./01_fix_ufw_k3s_networks.sh      # Finaliser UFW pour pods" | tee -a "$LOG_FILE"
    echo "  3. ./02_prepare_database.sh          # Créer les databases apps" | tee -a "$LOG_FILE"
    echo "  4. ./08_fix_ufw_nodeports_urgent.sh  # Contournement VXLAN" | tee -a "$LOG_FILE"
    echo "  5. ./09_deploy_ingress_daemonset.sh  # Ingress NGINX DaemonSet" | tee -a "$LOG_FILE"
    echo "  6. ./10_deploy_apps_hostnetwork.sh   # n8n + LiteLLM + Qdrant" | tee -a "$LOG_FILE"
    echo "  7. ./11_configure_ingress_routes.sh  # Routes Ingress" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    # Créer un résumé
    cat >> "$CREDENTIALS_DIR/k3s-cluster-summary.txt" <<SUMMARY

Addons installés :
  - Metrics-server : $([ "$METRICS_OK" = "1" ] && echo "OK" || echo "KO")
  - UFW NodePort   : $([ "$UFW_OK" = "1" ] && echo "OK" || echo "KO")
  - Test deployment: $([ "$TEST_OK" = "1" ] && echo "OK" || echo "KO")

NodePort Ingress (DaemonSet hostNetwork) :
  - HTTP  : 31695 (LBs 10.0.0.5/10.0.0.6 port 80 → workers:31695)
  - HTTPS : 32720 (LBs 10.0.0.5/10.0.0.6 port 443 → workers:32720)

État : PRÊT POUR DÉPLOIEMENT INGRESS + APPS
Date : $(date)
SUMMARY
    
    # Afficher les dernières lignes du log
    echo "═══════════════════════════════════════════════════════════════════"
    echo "Log complet (50 dernières lignes) :"
    echo "═══════════════════════════════════════════════════════════════════"
    tail -n 50 "$LOG_FILE"
    
    exit 0
else
    echo -e "$KO ERREURS DÉTECTÉES LORS DU BOOTSTRAP" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Vérifiez les logs :" | tee -a "$LOG_FILE"
    echo "  tail -n 100 $LOG_FILE" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    tail -n 50 "$LOG_FILE"
    exit 1
fi
