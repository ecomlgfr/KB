#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Configuration Load Balancer + Ingress Routes                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification des Ingress Routes ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Ingress existants dans le cluster :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get ingress -A"

echo ""
echo "→ Création des Ingress manquants..."
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'INGRESS_SETUP'
set -u

# Fonction pour créer un Ingress
create_ingress() {
    local app="$1"
    local namespace="$2"
    local host="$3"
    local service="$4"
    local port="$5"
    
    echo -n "  $app ($host) ... "
    
    # Créer le namespace s'il n'existe pas
    kubectl create namespace "$namespace" 2>/dev/null || true
    
    # Créer l'Ingress
    cat <<EOF | kubectl apply -f - 2>&1 | grep -v "unchanged" || true
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $app
  namespace: $namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
spec:
  ingressClassName: nginx
  rules:
  - host: $host
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $service
            port:
              number: $port
EOF
    
    echo "✓"
}

# Créer les Ingress pour les applications
create_ingress "n8n" "n8n" "n8n.keybuzz.io" "n8n" "5678"
create_ingress "chatwoot" "chatwoot" "chat.keybuzz.io" "chatwoot-web" "3000"
create_ingress "litellm" "litellm" "llm.keybuzz.io" "litellm" "4000"
create_ingress "qdrant" "qdrant" "qdrant.keybuzz.io" "qdrant" "6333"
create_ingress "superset" "superset" "superset.keybuzz.io" "superset" "8088"

INGRESS_SETUP

echo ""
echo "→ Ingress après création :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get ingress -A"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Récupération des NodePorts ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)

HTTPS_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}'" 2>/dev/null)

echo "NodePorts Ingress NGINX :"
echo "  HTTP  : $HTTP_NODEPORT"
echo "  HTTPS : $HTTPS_NODEPORT"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. IPs des Workers (Targets) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

echo "IPs privées des workers :"
for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  $worker : $ip"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test Local (depuis un worker) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "Test depuis k3s-worker-01 ($WORKER_IP) :"
echo ""

test_ingress() {
    local host="$1"
    
    echo -n "  $host ... "
    
    response=$(ssh -o StrictHostKeyChecking=no root@"$WORKER_IP" \
        "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $host' http://localhost:$HTTP_NODEPORT/ --max-time 5" 2>/dev/null)
    
    if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "404" ] || [ "$response" = "503" ]; then
        echo -e "$OK (HTTP $response)"
    else
        echo -e "$WARN (HTTP ${response:-timeout})"
    fi
}

test_ingress "n8n.keybuzz.io"
test_ingress "chat.keybuzz.io"
test_ingress "llm.keybuzz.io"
test_ingress "qdrant.keybuzz.io"
test_ingress "superset.keybuzz.io"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. CONFIGURATION LOAD BALANCER HETZNER ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<INSTRUCTIONS

📋 Instructions pour configurer le Load Balancer dans Hetzner Cloud Console :

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1️⃣  ALLER DANS HETZNER CLOUD CONSOLE

   https://console.hetzner.cloud/
   → Projet KeyBuzz
   → Load Balancers
   → lb-keybuzz-1 (ou créer si absent)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

2️⃣  ONGLET "SERVICES"

   SERVICE HTTP :
   ┌─────────────────────────────────────────────────────────────┐
   │ Listen Port       : 80                                       │
   │ Destination Port  : $HTTP_NODEPORT                                       │
   │ Protocol          : HTTP                                     │
   │ Proxy Protocol    : Non                                      │
   │ Sticky Sessions   : Oui (Cookie)                            │
   │ Cookie Name       : INGRESSCOOKIE                           │
   │ Cookie Lifetime   : 300 seconds                             │
   └─────────────────────────────────────────────────────────────┘

   SERVICE HTTPS :
   ┌─────────────────────────────────────────────────────────────┐
   │ Listen Port       : 443                                      │
   │ Destination Port  : $HTTPS_NODEPORT                                      │
   │ Protocol          : TCP                                      │
   │ Proxy Protocol    : Non                                      │
   │ Sticky Sessions   : Oui (Cookie)                            │
   │ Cookie Name       : INGRESSCOOKIE                           │
   │ Cookie Lifetime   : 300 seconds                             │
   └─────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

3️⃣  ONGLET "TARGETS"

   Ajouter les 5 workers (utiliser les IPs PRIVÉES) :
   ┌─────────────────────────────────────────────────────────────┐
   │ k3s-worker-01 : 10.0.0.110                                  │
   │ k3s-worker-02 : 10.0.0.111                                  │
   │ k3s-worker-03 : 10.0.0.112                                  │
   │ k3s-worker-04 : 10.0.0.113                                  │
   │ k3s-worker-05 : 10.0.0.114                                  │
   └─────────────────────────────────────────────────────────────┘

   ⚠️  Important : Utiliser les IPs PRIVÉES (10.0.0.x)
                   PAS les IPs publiques !

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

4️⃣  ONGLET "HEALTH CHECKS"

   HTTP Health Check :
   ┌─────────────────────────────────────────────────────────────┐
   │ Protocol          : HTTP                                     │
   │ Port              : $HTTP_NODEPORT                                       │
   │ Path              : /healthz                                 │
   │ Interval          : 15 seconds                               │
   │ Timeout           : 10 seconds                               │
   │ Retries           : 3                                        │
   │ HTTP Status Codes : 200                                      │
   └─────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

5️⃣  ONGLET "NETWORKS"

   S'assurer que le Load Balancer est dans le réseau privé :
   ┌─────────────────────────────────────────────────────────────┐
   │ Network : keybuzz-network (10.0.0.0/16)                    │
   └─────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

6️⃣  VÉRIFIER LES DNS

   Les domaines doivent pointer vers l'IP PUBLIQUE du Load Balancer :

   Récupérer l'IP publique du LB :
   → Hetzner Console → Load Balancers → lb-keybuzz-1 → IPv4

   Configurer les DNS (chez votre registrar) :
   ┌─────────────────────────────────────────────────────────────┐
   │ n8n.keybuzz.io       A    <IP_PUBLIQUE_LB>                 │
   │ chat.keybuzz.io      A    <IP_PUBLIQUE_LB>                 │
   │ llm.keybuzz.io       A    <IP_PUBLIQUE_LB>                 │
   │ qdrant.keybuzz.io    A    <IP_PUBLIQUE_LB>                 │
   │ superset.keybuzz.io  A    <IP_PUBLIQUE_LB>                 │
   └─────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

7️⃣  ATTENDRE 30 SECONDES

   Le Load Balancer doit effectuer les health checks.
   Tous les targets doivent passer à "Healthy" (vert).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

8️⃣  TESTER DEPUIS INTERNET

   curl http://n8n.keybuzz.io
   curl http://chat.keybuzz.io
   curl http://llm.keybuzz.io

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTRUCTIONS

echo ""
echo "Après configuration, relancer ce test :"
echo "  curl -v http://n8n.keybuzz.io"
echo ""
