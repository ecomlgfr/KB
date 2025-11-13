#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Redéploiement Wazuh Managers (après stabilisation Indexer)    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

echo ""
echo "⚠️  PRÉREQUIS IMPORTANT :"
echo "  • Wazuh Indexer doit être Running et stable (30+ minutes uptime)"
echo "  • Indexer doit répondre sur http://localhost:9200"
echo ""

read -p "Avez-vous vérifié que l'Indexer est stable ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé. Attendez la stabilisation de l'Indexer."; exit 0; }

echo ""
echo "→ Vérification de l'état de Wazuh Indexer..."

# Vérifier que le pod Indexer existe et est Running
INDEXER_POD=$(kubectl get pods -n wazuh -l app=wazuh-indexer --no-headers 2>/dev/null | awk '{print $1}')
if [ -z "$INDEXER_POD" ]; then
    echo -e "$KO Wazuh Indexer non trouvé"
    echo "   Exécutez d'abord : ./fix_all_problems_auto.sh"
    exit 1
fi

INDEXER_STATUS=$(kubectl get pod -n wazuh "$INDEXER_POD" --no-headers 2>/dev/null | awk '{print $3}')
if [ "$INDEXER_STATUS" != "Running" ]; then
    echo -e "$KO Wazuh Indexer n'est pas Running (état: $INDEXER_STATUS)"
    echo "   Attendez que l'Indexer soit complètement démarré"
    exit 1
fi

echo "  Pod Indexer : $INDEXER_POD"
echo "  État : $INDEXER_STATUS"

# Test HTTP sur l'Indexer
echo ""
echo "→ Test de connectivité HTTP sur l'Indexer..."
HTTP_TEST=$(kubectl exec -n wazuh "$INDEXER_POD" -- curl -s -o /dev/null -w "%{http_code}" http://localhost:9200 2>/dev/null)

if [ "$HTTP_TEST" != "200" ]; then
    echo -e "$KO Indexer ne répond pas correctement (HTTP $HTTP_TEST)"
    echo "   Vérifiez les logs : kubectl logs -n wazuh $INDEXER_POD --tail=50"
    exit 1
fi

echo -e "$OK Indexer répond correctement (HTTP 200)"

# Vérifier le cluster health
echo ""
echo "→ Vérification du cluster health..."
CLUSTER_HEALTH=$(kubectl exec -n wazuh "$INDEXER_POD" -- curl -s http://localhost:9200/_cluster/health 2>/dev/null)
echo "$CLUSTER_HEALTH"

if echo "$CLUSTER_HEALTH" | grep -q '"status":"green"\|"status":"yellow"'; then
    echo -e "$OK Cluster health : OK"
else
    echo -e "$WARN Cluster health : Warning (peut être normal pour single-node)"
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Déploiement des Wazuh Managers (DaemonSet)                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

read -p "Continuer avec le déploiement des Managers ? (yes/NO) : " deploy
[ "$deploy" != "yes" ] && { echo "Annulé"; exit 0; }

echo "→ Suppression de l'ancien déploiement (si existe)..."
kubectl delete daemonset wazuh-manager -n wazuh 2>/dev/null || true
sleep 5

echo "→ Déploiement du DaemonSet Wazuh Manager..."
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wazuh-manager
  namespace: wazuh
  labels:
    app: wazuh-manager
spec:
  selector:
    matchLabels:
      app: wazuh-manager
  template:
    metadata:
      labels:
        app: wazuh-manager
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: wazuh-manager
        image: wazuh/wazuh-manager:4.7.0
        ports:
        - containerPort: 1514
          hostPort: 1514
          protocol: TCP
          name: agents-events
        - containerPort: 1515
          hostPort: 1515
          protocol: TCP
          name: agents-auth
        - containerPort: 514
          hostPort: 514
          protocol: UDP
          name: syslog
        - containerPort: 55000
          hostPort: 55000
          protocol: TCP
          name: api
        env:
        - name: INDEXER_URL
          value: "http://wazuh-indexer:9200"
        - name: INDEXER_USERNAME
          value: "admin"
        - name: INDEXER_PASSWORD
          value: "admin"
        - name: FILEBEAT_SSL_VERIFICATION_MODE
          value: "none"
        - name: SSL_CERTIFICATE_AUTHORITIES
          value: ""
        - name: SSL_CERTIFICATE
          value: ""
        - name: SSL_KEY
          value: ""
        - name: API_USERNAME
          value: "wazuh-admin"
        - name: API_PASSWORD
          value: "wazuh-admin"
        volumeMounts:
        - name: data
          mountPath: /var/ossec/data
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - /var/ossec/bin/wazuh-control status | grep -q "wazuh-modulesd is running"
          initialDelaySeconds: 120
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 5
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - /var/ossec/bin/wazuh-control status | grep -q "wazuh-modulesd is running"
          initialDelaySeconds: 180
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
      volumes:
      - name: data
        hostPath:
          path: /opt/keybuzz/wazuh/manager/data
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: wazuh-manager
  namespace: wazuh
spec:
  type: NodePort
  selector:
    app: wazuh-manager
  ports:
  - name: agents-events
    port: 1514
    targetPort: 1514
    nodePort: 31514
    protocol: TCP
  - name: agents-auth
    port: 1515
    targetPort: 1515
    nodePort: 31515
    protocol: TCP
  - name: api
    port: 55000
    targetPort: 55000
    nodePort: 31550
    protocol: TCP
EOF

echo -e "$OK Wazuh Managers déployés"
echo ""

echo "⏱️  Attente du démarrage des pods (120s)..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAT FINAL DES PODS WAZUH"
echo "═══════════════════════════════════════════════════════════════════"

kubectl get pods -n wazuh -o wide

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "SERVICES WAZUH"
echo "═══════════════════════════════════════════════════════════════════"

kubectl get svc -n wazuh

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  ✅ DÉPLOIEMENT TERMINÉ                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

echo "📊 Architecture Wazuh déployée :"
echo "  • Wazuh Indexer : 1 pod (StatefulSet)"
echo "  • Wazuh Manager : 8 pods (DaemonSet - 1 par nœud)"
echo ""

echo "🔍 Vérifications à faire :"
echo "  1. Vérifier que tous les Managers sont Running :"
echo "     kubectl get pods -n wazuh -l app=wazuh-manager"
echo ""
echo "  2. Vérifier les logs d'un Manager :"
echo "     kubectl logs -n wazuh \$(kubectl get pod -n wazuh -l app=wazuh-manager -o name | head -1 | cut -d/ -f2) --tail=50"
echo ""
echo "  3. Tester l'API Wazuh :"
echo "     kubectl exec -n wazuh \$(kubectl get pod -n wazuh -l app=wazuh-manager -o name | head -1 | cut -d/ -f2) -- curl -u wazuh-admin:wazuh-admin http://localhost:55000"
echo ""

echo "📱 Accès :"
echo "  • API Wazuh : NodePort 31550"
echo "  • Agents Events : NodePort 31514"
echo "  • Agents Auth : NodePort 31515"
echo ""

echo "⚠️  Note : Credentials par défaut (à changer en production) :"
echo "  • API : wazuh-admin / wazuh-admin"
echo "  • Indexer : admin / admin"
echo ""

echo "🎯 Prochaines étapes :"
echo "  1. Attendre 5-10 minutes pour stabilisation complète"
echo "  2. Vérifier la connexion Managers → Indexer"
echo "  3. Configurer les agents Wazuh"
echo "  4. Déployer Wazuh Dashboard (optionnel)"
echo ""

exit 0
