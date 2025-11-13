#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Correction DaemonSets + Configuration kubectl                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "Problèmes identifiés :"
echo "  ❌ DaemonSets : 0 pods (nodeSelector incorrect)"
echo "  ❌ kubectl ne fonctionne pas depuis install-01"
echo ""
echo "Solutions :"
echo "  ✅ Supprimer le nodeSelector des DaemonSets"
echo "  ✅ Configurer kubeconfig sur install-01"
echo ""

read -p "Appliquer les corrections ? (yes/NO) : " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "❌ Opération annulée"
    exit 0
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Configuration kubectl sur install-01 ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Copie du kubeconfig depuis k3s-master-01..."

# Créer le répertoire .kube
mkdir -p ~/.kube

# Copier le kubeconfig depuis le master
scp -o StrictHostKeyChecking=no root@"$IP_MASTER01":/etc/rancher/k3s/k3s.yaml ~/.kube/config >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "  $OK kubeconfig copié"
    
    # Corriger l'IP du serveur (remplacer 127.0.0.1 par l'IP du master)
    sed -i "s|https://127.0.0.1:6443|https://$IP_MASTER01:6443|g" ~/.kube/config
    
    echo -e "  $OK Server corrigé (https://$IP_MASTER01:6443)"
    
    # Tester
    if kubectl get nodes >/dev/null 2>&1; then
        echo -e "  $OK kubectl fonctionne !"
    else
        echo -e "  $WARN kubectl configuré mais erreur de connexion"
    fi
else
    echo -e "  $KO Échec copie kubeconfig"
    echo "  Continuons avec SSH vers le master..."
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Correction des DaemonSets (supprimer nodeSelector) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Suppression du nodeSelector incorrect..."
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'FIX_DAEMONSETS'
set -u

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

fix_daemonset() {
    local service="$1"
    local namespace="$2"
    
    echo -n "  $service ... "
    
    # Supprimer le DaemonSet actuel
    kubectl delete daemonset -n "$namespace" "$service" --ignore-not-found=true >/dev/null 2>&1
    
    # Attendre la suppression
    sleep 3
    
    # Récréer sans nodeSelector
    kubectl get daemonset -n "$namespace" "$service" >/dev/null 2>&1 || {
        # Le DaemonSet n'existe plus, on peut le recréer
        echo -e "$OK Supprimé, recréation..."
        return 0
    }
    
    echo -e "$KO Échec suppression"
    return 1
}

# Corriger chaque DaemonSet
fix_daemonset "n8n" "n8n"
fix_daemonset "litellm" "litellm"
fix_daemonset "qdrant" "qdrant"
fix_daemonset "superset" "superset"

FIX_DAEMONSETS

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Recréation des DaemonSets (SANS nodeSelector) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CREATE_DAEMONSETS'
set -u

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

create_daemonset() {
    local service="$1"
    local namespace="$2"
    local port="$3"
    local image="$4"
    
    echo "→ $service"
    
    # Créer le namespace
    kubectl create namespace "$namespace" 2>/dev/null || true
    
    # Créer le DaemonSet SANS nodeSelector
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
        echo -e "  $KO Échec création"
    fi
    
    # Vérifier/créer le Service
    if ! kubectl get svc -n "$namespace" "$service" >/dev/null 2>&1; then
        echo "  ✓ Création du Service..."
        kubectl create service clusterip "$service" --tcp="$port:$port" -n "$namespace" >/dev/null 2>&1
        kubectl label svc -n "$namespace" "$service" app="$service" >/dev/null 2>&1
    fi
    
    echo ""
}

# Créer les DaemonSets
create_daemonset "n8n" "n8n" "5678" "n8nio/n8n:latest"
create_daemonset "litellm" "litellm" "4000" "ghcr.io/berriai/litellm:main-latest"
create_daemonset "qdrant" "qdrant" "6333" "qdrant/qdrant:latest"
create_daemonset "superset" "superset" "8088" "apache/superset:latest"

CREATE_DAEMONSETS

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Attente démarrage des pods (60s) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 60 secondes..."
for i in {60..1}; do
    echo -ne "  $i secondes restantes...\r"
    sleep 1
done
echo ""

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification des DaemonSets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CHECK'
echo "État des DaemonSets :"
echo ""
kubectl get daemonset -A | grep -E '(n8n|litellm|qdrant|superset)'
echo ""
echo "État des pods :"
echo ""
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|superset)' | grep -v 'ingress\|admission'
CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Test Communication Ingress → Backends ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test depuis un pod Ingress NGINX :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'TEST'
OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o name 2>/dev/null | head -n1 | cut -d/ -f2)

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
            echo -e "$WARN (HTTP $result - Backend pas prêt)"
            ;;
        000|"")
            echo -e "$KO (Timeout)"
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
echo "═══ 7. Test depuis Internet ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test stabilité (10 requêtes) :"
echo ""

for i in {1..10}; do
    echo -n "  #$i : "
    curl -s -o /dev/null -w "HTTP %{http_code}\n" http://llm.keybuzz.io
    sleep 1
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSULTAT ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<RESULT

✅ Corrections appliquées !

Vérifications :
  1. kubectl fonctionne sur install-01 ?
  2. DaemonSets ont des pods (DESIRED > 0) ?
  3. Pods sont Running ?
  4. Communication Ingress → Backends fonctionne ?
  5. Tests depuis Internet stables (pas 503) ?

Si tout est OK :
  → Passer aux actions suivantes (DNS + LB2)

Si des pods ne démarrent pas :
  → Vérifier les logs : kubectl logs -n <namespace> <pod>

RESULT

echo ""
