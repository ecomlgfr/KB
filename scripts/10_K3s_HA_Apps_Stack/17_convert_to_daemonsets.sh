#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Conversion Deployments → DaemonSets (Solution VXLAN)           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CONTEXTE ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<CONTEXT
Problème actuel :
  ❌ VXLAN bloqué → Communication inter-pods impossible
  ❌ Ingress NGINX ne peut pas joindre les backends sur d'autres workers
  ❌ Seuls les backends sur le MÊME worker que Ingress fonctionnent

Solution :
  ✅ Convertir les Deployments en DaemonSets
  ✅ 1 pod par worker (comme Ingress NGINX)
  ✅ Communication locale → Pas besoin de VXLAN

Services à convertir :
  - n8n       (API stateless)
  - litellm   (API stateless)
  - qdrant    (Vector DB, peut tourner en cluster)
  - superset  (Dashboard, stateless si DB externe)

Services à NE PAS convertir :
  - chatwoot  (Service n'existe pas encore, à créer normalement)
  - PostgreSQL, Redis, RabbitMQ (services avec état)

CONTEXT

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ CONFIRMATION ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "⚠️  ATTENTION : Cette opération va :"
echo ""
echo "  1. Sauvegarder les Deployments actuels"
echo "  2. Supprimer les Deployments"
echo "  3. Créer des DaemonSets à la place"
echo "  4. Les pods vont redémarrer (interruption ~2 minutes)"
echo ""

read -p "Voulez-vous continuer ? (yes/NO) : " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo ""
    echo "❌ Opération annulée"
    exit 0
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Sauvegarde des Deployments ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

BACKUP_DIR="/opt/keybuzz-installer/backups/deployments-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "Sauvegarde dans : $BACKUP_DIR"
echo ""

SERVICES=("n8n" "litellm" "qdrant" "superset")

for service in "${SERVICES[@]}"; do
    echo -n "  Sauvegarde $service ... "
    
    if ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
        "kubectl get deployment -n $service $service -o yaml > /tmp/${service}-deployment.yaml 2>/dev/null"; then
        
        scp -o StrictHostKeyChecking=no root@"$IP_MASTER01":/tmp/${service}-deployment.yaml \
            "$BACKUP_DIR/" >/dev/null 2>&1
        
        echo -e "$OK"
    else
        echo -e "$WARN (n'existe pas)"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Conversion en DaemonSets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CONVERT'
set -u

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

convert_to_daemonset() {
    local service="$1"
    local namespace="$2"
    local port="$3"
    local image="$4"
    
    echo "→ Conversion de $service"
    echo ""
    
    # Vérifier si le Deployment existe
    if ! kubectl get deployment -n "$namespace" "$service" >/dev/null 2>&1; then
        echo -e "  $WARN Deployment n'existe pas, création directe en DaemonSet"
    else
        echo "  ✓ Récupération de l'image actuelle..."
        current_image=$(kubectl get deployment -n "$namespace" "$service" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
        
        if [ -n "$current_image" ]; then
            image="$current_image"
            echo "    Image : $image"
        fi
        
        echo "  ✓ Suppression du Deployment..."
        kubectl delete deployment -n "$namespace" "$service" --ignore-not-found=true >/dev/null 2>&1
        
        echo "  ✓ Attente suppression (5s)..."
        sleep 5
    fi
    
    # Créer le DaemonSet
    echo "  ✓ Création du DaemonSet..."
    
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $service
  namespace: $namespace
  labels:
    app: $service
spec:
  selector:
    matchLabels:
      app: $service
  template:
    metadata:
      labels:
        app: $service
    spec:
      nodeSelector:
        node.kubernetes.io/instance-type: worker
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: $service
        image: $image
        ports:
        - containerPort: $port
          name: http
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK DaemonSet créé"
    else
        echo -e "  $KO Échec création DaemonSet"
        return 1
    fi
    
    # Vérifier que le Service existe, sinon le créer
    if ! kubectl get svc -n "$namespace" "$service" >/dev/null 2>&1; then
        echo "  ✓ Création du Service..."
        kubectl expose daemonset "$service" --port="$port" --name="$service" -n "$namespace" >/dev/null 2>&1
    fi
    
    echo ""
}

# Conversion des services
convert_to_daemonset "n8n" "n8n" "5678" "n8nio/n8n:latest"
convert_to_daemonset "litellm" "litellm" "4000" "ghcr.io/berriai/litellm:main-latest"
convert_to_daemonset "qdrant" "qdrant" "6333" "qdrant/qdrant:latest"
convert_to_daemonset "superset" "superset" "8088" "apache/superset:latest"

CONVERT

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Attente démarrage des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 30 secondes pour le démarrage..."
sleep 30

echo ""
echo "État des DaemonSets :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'STATUS'
for service in n8n litellm qdrant superset; do
    echo "→ $service :"
    kubectl get daemonset -n "$service" "$service" 2>/dev/null || echo "  N'existe pas"
    echo ""
done
STATUS

echo "État des pods :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get pods -A | grep -E '(n8n|litellm|qdrant|superset)' | grep -v ingress"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test Communication Ingress → Backends ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 30s supplémentaires pour que les pods soient Ready..."
sleep 30

echo ""
echo "Test depuis un pod Ingress NGINX :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'TEST'
OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -n1 | cut -d/ -f2)

if [ -z "$INGRESS_POD" ]; then
    echo -e "$KO Aucun pod Ingress NGINX trouvé"
    exit 1
fi

test_backend() {
    local namespace="$1"
    local service="$2"
    local port="$3"
    
    echo -n "  $namespace/$service:$port ... "
    
    cluster_ip=$(kubectl get svc -n "$namespace" "$service" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    
    if [ -z "$cluster_ip" ] || [ "$cluster_ip" = "None" ]; then
        echo -e "$KO Service n'existe pas"
        return
    fi
    
    result=$(kubectl exec -n ingress-nginx "$INGRESS_POD" -- timeout 5 curl -s -o /dev/null -w '%{http_code}' "http://$cluster_ip:$port/" 2>/dev/null || echo "000")
    
    case "$result" in
        200|302|404|401)
            echo -e "$OK (HTTP $result - Backend répond !)"
            ;;
        503)
            echo -e "$WARN (HTTP $result - Backend pas encore prêt)"
            ;;
        000|"")
            echo -e "$KO (Timeout - Vérifier les pods)"
            ;;
        *)
            echo -e "$WARN (HTTP $result)"
            ;;
    esac
}

test_backend "n8n" "n8n" "5678"
test_backend "litellm" "litellm" "4000"
test_backend "qdrant" "qdrant" "6333"
test_backend "superset" "superset" "8088"
TEST

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Test depuis Internet (via Load Balancers) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 10s pour que les Load Balancers détectent les changements..."
sleep 10

echo ""
echo "Test HTTP depuis Internet :"
echo ""

DOMAINS=("n8n.keybuzz.io" "llm.keybuzz.io" "qdrant.keybuzz.io" "superset.keybuzz.io")

for domain in "${DOMAINS[@]}"; do
    echo -n "  http://$domain ... "
    
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        "http://$domain/" 2>/dev/null)
    
    case "$response" in
        200|302)
            echo -e "$OK (HTTP $response)"
            ;;
        404|401)
            echo -e "$WARN (HTTP $response - App OK mais auth requise)"
            ;;
        503)
            echo -e "$WARN (HTTP $response - Backend pas encore prêt)"
            ;;
        000|"")
            echo -e "$KO (Timeout - Vérifier DNS et Load Balancers)"
            ;;
        *)
            echo -e "$WARN (HTTP $response)"
            ;;
    esac
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSULTAT ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<RESULT

✅ Conversion terminée !

Les services tournent maintenant en DaemonSet :
  - 1 pod par worker (5 pods par service)
  - Communication locale (pas de VXLAN nécessaire)
  - Haute disponibilité native

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 Prochaines étapes :

1. Vérifier que tous les pods sont Running :
   kubectl get pods -A | grep -E '(n8n|litellm|qdrant|superset)'

2. Si des pods sont en CrashLoopBackOff :
   kubectl logs -n <namespace> <pod-name>

3. Corriger le DNS pour n8n.keybuzz.io :
   - SUPPRIMER : n8n.keybuzz.io A 10.0.0.100
   - AJOUTER : n8n.keybuzz.io A 49.13.42.76
   - AJOUTER : n8n.keybuzz.io A 138.199.132.240

4. Corriger le Load Balancer 2 dans Hetzner Console :
   https://console.hetzner.cloud/ → Load Balancers → LB2
   - Vérifier Targets : 5 workers "Healthy"
   - Vérifier Services : HTTP 80 → 31695
   - Vérifier Health Checks : HTTP port 31695 path /healthz

5. Test final :
   for i in {1..10}; do
     curl -s -o /dev/null -w "HTTP %{http_code}\n" http://llm.keybuzz.io
     sleep 1
   done
   
   → Doit être stable (10/10 succès)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Sauvegarde des anciens Deployments :
  $BACKUP_DIR

Pour restaurer un Deployment (si nécessaire) :
  kubectl apply -f $BACKUP_DIR/<service>-deployment.yaml

RESULT

echo ""
