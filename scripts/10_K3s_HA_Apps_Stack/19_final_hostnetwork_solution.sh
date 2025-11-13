#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Solution Finale : hostNetwork + Correction Superset            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<DIAGNOSTIC
Problème actuel :
  ❌ Communication Ingress → Backends via ClusterIP ne fonctionne pas
  ❌ VXLAN bloqué → ClusterIP inutilisable
  ❌ Superset crashe (CrashLoopBackOff)

Solution finale :
  ✅ Activer hostNetwork sur les DaemonSets
  ✅ Les pods utilisent directement l'IP du node
  ✅ Ingress peut joindre les backends via NodeIP:Port
  ✅ Supprimer Superset (application complexe, à déployer séparément)

Impact :
  ⚠️  Les pods écoutent directement sur les ports du node
  ⚠️  Ports 5678 (n8n), 4000 (litellm), 6333 (qdrant) utilisés sur TOUS les nodes
  ✅  Communication fonctionne sans VXLAN

DIAGNOSTIC

echo ""
read -p "Appliquer la solution finale ? (yes/NO) : " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "❌ Opération annulée"
    exit 0
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification des logs Superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Logs d'un pod Superset en erreur :"
echo ""

kubectl logs -n superset $(kubectl get pods -n superset -o name | grep superset | head -n1) --tail=20 2>/dev/null || echo "  Impossible de récupérer les logs"

echo ""
echo "→ Suppression de Superset (trop complexe pour DaemonSet)..."
kubectl delete daemonset -n superset superset 2>/dev/null
kubectl delete svc -n superset superset 2>/dev/null
echo -e "  $OK Superset supprimé (à redéployer en Deployment normal plus tard)"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Conversion vers hostNetwork ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Recréation des DaemonSets avec hostNetwork..."
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: n8n
  namespace: n8n
  labels:
    app: n8n
spec:
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: n8n
        image: n8nio/n8n:latest
        ports:
        - containerPort: 5678
          hostPort: 5678
        env:
        - name: N8N_HOST
          value: "0.0.0.0"
        - name: N8N_PORT
          value: "5678"
        - name: N8N_PROTOCOL
          value: "http"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: litellm
  namespace: litellm
  labels:
    app: litellm
spec:
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main-latest
        ports:
        - containerPort: 4000
          hostPort: 4000
        env:
        - name: PORT
          value: "4000"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: qdrant
  namespace: qdrant
  labels:
    app: qdrant
spec:
  selector:
    matchLabels:
      app: qdrant
  template:
    metadata:
      labels:
        app: qdrant
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: qdrant
        image: qdrant/qdrant:latest
        ports:
        - containerPort: 6333
          hostPort: 6333
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
EOF

echo -e "$OK DaemonSets avec hostNetwork créés"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Modification des Services (type NodePort) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Conversion des Services en NodePort..."
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: Service
metadata:
  name: n8n
  namespace: n8n
spec:
  type: NodePort
  selector:
    app: n8n
  ports:
  - port: 5678
    targetPort: 5678
    nodePort: 30678
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: litellm
spec:
  type: NodePort
  selector:
    app: litellm
  ports:
  - port: 4000
    targetPort: 4000
    nodePort: 30400
---
apiVersion: v1
kind: Service
metadata:
  name: qdrant
  namespace: qdrant
spec:
  type: NodePort
  selector:
    app: qdrant
  ports:
  - port: 6333
    targetPort: 6333
    nodePort: 30633
EOF

echo -e "$OK Services convertis en NodePort"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Modification des Ingress (utiliser NodePort) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Mise à jour des Ingress pour utiliser les NodePorts..."
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: n8n
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
spec:
  ingressClassName: nginx
  rules:
  - host: n8n.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: n8n
            port:
              number: 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  namespace: litellm
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: llm.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: litellm
            port:
              number: 4000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qdrant
  namespace: qdrant
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: qdrant.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: qdrant
            port:
              number: 6333
EOF

echo -e "$OK Ingress mis à jour"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Attente redémarrage des pods (60s) ═══"
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
echo "═══ 6. Vérification des pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -A | grep -E '(n8n|litellm|qdrant)' | grep -v 'ingress\|admission'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Test depuis un worker (direct) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

WORKER_IP=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "Test direct vers k3s-worker-01 ($WORKER_IP) :"
echo ""

for port_service in "5678:n8n" "4000:litellm" "6333:qdrant"; do
    port=$(echo "$port_service" | cut -d: -f1)
    service=$(echo "$port_service" | cut -d: -f2)
    
    echo -n "  $service (port $port) ... "
    
    response=$(timeout 3 curl -s -o /dev/null -w '%{http_code}' "http://$WORKER_IP:$port/" 2>/dev/null)
    
    case "$response" in
        200|302|404|401)
            echo -e "$OK (HTTP $response)"
            ;;
        000|"")
            echo -e "$KO (Timeout)"
            ;;
        *)
            echo -e "$WARN (HTTP $response)"
            ;;
    esac
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Test depuis Internet (via Load Balancers) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test stabilité (10 requêtes) sur llm.keybuzz.io :"
echo ""

SUCCESS=0
for i in {1..10}; do
    response=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://llm.keybuzz.io/" 2>/dev/null)
    
    echo -n "  #$i : HTTP $response "
    
    if [ "$response" = "200" ] || [ "$response" = "302" ]; then
        echo -e "[$OK]"
        ((SUCCESS++))
    else
        echo -e "[$KO]"
    fi
    
    sleep 1
done

echo ""
echo "Résultat : $SUCCESS/10 succès"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSULTAT FINAL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$SUCCESS" -ge 8 ]; then
    cat <<SUCCESS_MSG
✅ SUCCÈS ! La solution fonctionne !

Configuration finale :
  ✓ DaemonSets avec hostNetwork activé
  ✓ Pods écoutent directement sur les IPs des nodes
  ✓ Services en NodePort
  ✓ Communication fonctionne sans VXLAN
  ✓ Tests stables depuis Internet ($SUCCESS/10)

Prochaines étapes :
  1. Corriger le DNS pour n8n.keybuzz.io
  2. Corriger le Load Balancer 2
  3. Déployer les services manquants (chatwoot, superset)

SUCCESS_MSG
else
    cat <<PARTIAL_MSG
⚠️  AMÉLIORATION PARTIELLE

Résultat : $SUCCESS/10 succès

Si toujours instable :
  1. Vérifier les logs des pods :
     kubectl logs -n n8n <pod-name>
     kubectl logs -n litellm <pod-name>
     
  2. Vérifier les Load Balancers dans Hetzner Console
  3. Corriger le DNS pour n8n.keybuzz.io

PARTIAL_MSG
fi

echo ""
echo "Commandes utiles :"
echo "  kubectl get pods -A | grep -E '(n8n|litellm|qdrant)'"
echo "  kubectl get daemonset -A"
echo "  kubectl get svc -A | grep -E '(n8n|litellm|qdrant)'"
echo ""
