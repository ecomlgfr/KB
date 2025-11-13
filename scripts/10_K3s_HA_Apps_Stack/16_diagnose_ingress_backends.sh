#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic Communication Ingress → Backends                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "Problème identifié :"
echo "  → Health checks fonctionnent (workers OK)"
echo "  → Mais routes Ingress timeout (backends inaccessibles)"
echo "  → Communication inter-pods bloquée"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification des Services et Endpoints ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

APPS=("n8n:n8n:5678" "chatwoot:chatwoot-web:3000" "litellm:litellm:4000" "qdrant:qdrant:6333" "superset:superset:8088")

echo "Vérification que chaque service a des endpoints (pods backend) :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'SERVICES_CHECK'
OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

check_service() {
    local namespace="$1"
    local service="$2"
    local port="$3"
    
    echo "→ $namespace/$service (port $port)"
    
    # Vérifier si le service existe
    if ! kubectl get svc -n "$namespace" "$service" >/dev/null 2>&1; then
        echo -e "  $KO Service n'existe pas"
        echo "  Action : Déployer le service dans K3s"
        echo ""
        return
    fi
    
    # Vérifier les endpoints
    endpoints=$(kubectl get endpoints -n "$namespace" "$service" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    
    if [ -z "$endpoints" ]; then
        echo -e "  $WARN Service existe mais PAS d'endpoints"
        echo "  Cause : Aucun pod backend actif"
        
        # Vérifier s'il y a des pods
        pods=$(kubectl get pods -n "$namespace" -l app="$service" -o name 2>/dev/null | wc -l)
        if [ "$pods" -eq 0 ]; then
            echo "  Action : Déployer les pods pour $service"
        else
            echo "  Pods : $pods trouvés mais pas Ready"
            echo "  Action : Vérifier les logs des pods"
        fi
    else
        endpoint_count=$(echo "$endpoints" | wc -w)
        echo -e "  $OK $endpoint_count endpoint(s) : $endpoints"
        
        # Vérifier si les endpoints sont joignables
        first_endpoint=$(echo "$endpoints" | awk '{print $1}')
        if timeout 3 bash -c "</dev/tcp/$first_endpoint/$port" 2>/dev/null; then
            echo -e "  $OK Endpoint joignable sur port $port"
        else
            echo -e "  $WARN Endpoint existe mais PAS joignable sur port $port"
            echo "  Cause : Pod existe mais n'écoute pas sur le port ou réseau bloqué"
        fi
    fi
    
    echo ""
}

check_service "n8n" "n8n" "5678"
check_service "chatwoot" "chatwoot-web" "3000"
check_service "litellm" "litellm" "4000"
check_service "qdrant" "qdrant" "6333"
check_service "superset" "superset" "8088"
SERVICES_CHECK

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test Communication Ingress → Backend ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test depuis un pod Ingress NGINX vers les backends :"
echo "(Si timeout → Communication inter-pods bloquée)"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'INGRESS_TEST'
OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

# Récupérer un pod Ingress NGINX
INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -n1 | cut -d/ -f2)

if [ -z "$INGRESS_POD" ]; then
    echo -e "$KO Aucun pod Ingress NGINX trouvé"
    exit 1
fi

echo "Pod Ingress NGINX utilisé : $INGRESS_POD"
echo ""

test_backend() {
    local namespace="$1"
    local service="$2"
    local port="$3"
    
    echo -n "  $namespace/$service:$port ... "
    
    # Obtenir l'IP du service (ClusterIP)
    cluster_ip=$(kubectl get svc -n "$namespace" "$service" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    
    if [ -z "$cluster_ip" ] || [ "$cluster_ip" = "None" ]; then
        echo -e "$KO Service n'existe pas"
        return
    fi
    
    # Tester depuis le pod Ingress NGINX
    result=$(kubectl exec -n ingress-nginx "$INGRESS_POD" -- timeout 3 curl -s -o /dev/null -w '%{http_code}' "http://$cluster_ip:$port/" 2>/dev/null || echo "000")
    
    case "$result" in
        200|302|404|401)
            echo -e "$OK (HTTP $result - Backend répond)"
            ;;
        503)
            echo -e "$WARN (HTTP $result - Backend existe mais pas prêt)"
            ;;
        000|"")
            echo -e "$KO (Timeout - Communication bloquée)"
            echo "    ClusterIP : $cluster_ip"
            echo "    Cause : Réseau pod overlay (VXLAN) non fonctionnel"
            ;;
        *)
            echo -e "$WARN (HTTP $result)"
            ;;
    esac
}

test_backend "n8n" "n8n" "5678"
test_backend "chatwoot" "chatwoot-web" "3000"
test_backend "litellm" "litellm" "4000"
test_backend "qdrant" "qdrant" "6333"
test_backend "superset" "superset" "8088"
INGRESS_TEST

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Vérification Réseau Pod Overlay (Flannel) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Vérification de la communication inter-pods (VXLAN) :"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'VXLAN_TEST'
OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

# Récupérer 2 pods sur des workers différents
POD1=$(kubectl get pods -A -o json | jq -r '.items[] | select(.status.phase=="Running") | select(.spec.nodeName=="k3s-worker-01") | "\(.metadata.namespace)/\(.metadata.name)/\(.status.podIP)"' | head -n1)
POD2=$(kubectl get pods -A -o json | jq -r '.items[] | select(.status.phase=="Running") | select(.spec.nodeName=="k3s-worker-02") | "\(.metadata.namespace)/\(.metadata.name)/\(.status.podIP)"' | head -n1)

if [ -z "$POD1" ] || [ -z "$POD2" ]; then
    echo -e "$WARN Impossible de trouver 2 pods sur des workers différents"
    exit 0
fi

POD1_NS=$(echo "$POD1" | cut -d/ -f1)
POD1_NAME=$(echo "$POD1" | cut -d/ -f2)
POD1_IP=$(echo "$POD1" | cut -d/ -f3)

POD2_NS=$(echo "$POD2" | cut -d/ -f1)
POD2_NAME=$(echo "$POD2" | cut -d/ -f2)
POD2_IP=$(echo "$POD2" | cut -d/ -f3)

echo "Pod 1 : $POD1_NAME (worker-01) → IP $POD1_IP"
echo "Pod 2 : $POD2_NAME (worker-02) → IP $POD2_IP"
echo ""

echo -n "Test ping depuis Pod 1 vers Pod 2 ... "

# Test ping
if kubectl exec -n "$POD1_NS" "$POD1_NAME" -- timeout 3 ping -c 1 "$POD2_IP" >/dev/null 2>&1; then
    echo -e "$OK Communication inter-pods fonctionne"
else
    echo -e "$KO Communication inter-pods bloquée"
    echo ""
    echo "Cause : VXLAN (port 8472/UDP) bloqué au niveau infrastructure"
    echo "Impact : Les pods sur des workers différents ne peuvent pas communiquer"
    echo ""
    echo "Conséquence pour Ingress :"
    echo "  → Si Ingress sur worker-01 et backend sur worker-02 → KO"
    echo "  → Si Ingress et backend sur le MÊME worker → OK"
fi
VXLAN_TEST

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC ET SOLUTIONS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<DIAGNOSTIC

📊 Résumé du diagnostic :

✅ Infrastructure K3s : OK
   - 5 workers opérationnels
   - Pods Ingress NGINX running (5 pods)
   - Health checks fonctionnent

❌ Communication inter-pods : KO
   - Ingress NGINX ne peut pas joindre les backends
   - VXLAN bloqué (communication entre workers)
   - Seuls les backends sur le MÊME worker que Ingress fonctionnent

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎯 SOLUTIONS POSSIBLES

SOLUTION 1 : Déployer les backends en DaemonSet (RAPIDE) ⚡
──────────────────────────────────────────────────────────────────

Principe :
  → Chaque backend tourne sur CHAQUE worker (comme Ingress NGINX)
  → Ingress et backend sur le même worker → communication locale
  → Pas besoin de VXLAN

Avantages :
  ✅ Résout immédiatement le problème
  ✅ Haute disponibilité (5 réplicas)
  ✅ Pas de changement réseau

Inconvénients :
  ⚠️  Consomme plus de ressources (5x les pods)
  ⚠️  Pas adapté pour tous les services (bases de données)

Services compatibles :
  - n8n (API stateless)
  - Qdrant (peut fonctionner en cluster)
  - LiteLLM (API stateless)

Services NON compatibles :
  - Chatwoot (nécessite PostgreSQL)
  - Superset (nécessite PostgreSQL)

SOLUTION 2 : Utiliser les Services K3s en mode Local (MOYEN) 🔧
──────────────────────────────────────────────────────────────────

Principe :
  → Modifier les Ingress pour utiliser des NodePorts au lieu de ClusterIP
  → Communication via l'IP du node (pas via VXLAN)

Avantages :
  ✅ Fonctionne sans VXLAN
  ✅ Garde les déploiements normaux (pas besoin de DaemonSet)

Inconvénients :
  ⚠️  Plus complexe à configurer
  ⚠️  Performance légèrement réduite

SOLUTION 3 : Réparer VXLAN (LONG) 🔨
──────────────────────────────────────────────────────────────────

Principe :
  → Débloquer VXLAN au niveau infrastructure Hetzner
  → Ou migrer vers un CNI alternatif (Calico, Cilium)

Avantages :
  ✅ Solution pérenne
  ✅ Communication inter-pods normale

Inconvénients :
  ⚠️  Nécessite changement infrastructure
  ⚠️  Temps de mise en œuvre long
  ⚠️  Risque de downtime

SOLUTION 4 : Mode Hybride (RECOMMANDÉ) 🌟
──────────────────────────────────────────────────────────────────

Principe :
  → Services stateless en DaemonSet (n8n, litellm, qdrant)
  → Services avec état en Deployment normal (bases de données)
  → Ingress NGINX route localement quand possible

Avantages :
  ✅ Meilleur compromis performance/ressources
  ✅ Fonctionne immédiatement
  ✅ Haute disponibilité

Configuration :
  1. Convertir n8n, litellm, qdrant en DaemonSet
  2. Garder chatwoot, superset en Deployment
  3. Ajouter node affinity pour co-localiser quand possible

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DIAGNOSTIC

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ACTIONS IMMÉDIATES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<ACTIONS

📋 Plan d'action immédiat :

ÉTAPE 1 : Vérifier quels services ont des endpoints
──────────────────────────────────────────────────────────────────

kubectl get svc,endpoints -A | grep -E '(n8n|chatwoot|litellm|qdrant|superset)'

Services SANS endpoints → À déployer en priorité

ÉTAPE 2 : Déployer les services manquants (si nécessaire)
──────────────────────────────────────────────────────────────────

Exemple pour n8n :
kubectl create deployment n8n --image=n8nio/n8n:latest -n n8n --replicas=5
kubectl expose deployment n8n --port=5678 --name=n8n -n n8n

ÉTAPE 3 : Convertir en DaemonSet (solution rapide)
──────────────────────────────────────────────────────────────────

Je peux créer un script pour convertir les Deployments en DaemonSets.
Cela résoudra immédiatement le problème de communication.

ÉTAPE 4 : Corriger les DNS
──────────────────────────────────────────────────────────────────

⚠️  CRITIQUE : n8n.keybuzz.io pointe vers 10.0.0.100

Chez le registrar DNS :
  - SUPPRIMER : n8n.keybuzz.io A 10.0.0.100
  - AJOUTER : n8n.keybuzz.io A 49.13.42.76
  - AJOUTER : n8n.keybuzz.io A 138.199.132.240

ÉTAPE 5 : Corriger le Load Balancer 2
──────────────────────────────────────────────────────────────────

Console Hetzner : https://console.hetzner.cloud/
→ Load Balancers → LB2

Vérifier et corriger :
  - TARGETS : 5 workers (IPs privées 10.0.0.110-114)
  - SERVICES : HTTP 80 → 31695
  - HEALTH CHECKS : HTTP port 31695 path /healthz
  - NETWORKS : Attaché au réseau privé

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ACTIONS

echo ""
echo "Voulez-vous que je crée un script pour convertir"
echo "les Deployments en DaemonSets automatiquement ? (yes/NO)"
echo ""
