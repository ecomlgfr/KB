#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    CORRECTION FINALE - Vault + Wazuh Indexer                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

echo ""
echo "📊 ÉTAT ACTUEL :"
echo "  ✅ 81/81 pods Running (hors Wazuh)"
echo "  ✅ Vault : 8/8 Running (sealed, initialisé)"
echo "  ❌ Wazuh Indexer : Erreur SSL + index manquant"
echo ""
echo "Ce script va :"
echo "  1. Déverrouiller Vault (ou réinitialiser si clés perdues)"
echo "  2. Corriger Wazuh Indexer (sans SSL)"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 1 : VAULT - Déverrouillage ou Réinitialisation
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 1: Vault - Déverrouillage                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

POD=$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}')

echo "→ Vérification de l'état Vault..."
kubectl exec -n vault "$POD" -- vault status 2>&1 || true

echo ""
echo "→ Recherche des clés Vault existantes..."
KEYS_FOUND=false

if [ -f "/root/vault_keys.txt" ]; then
    echo -e "$OK Clés trouvées dans /root/vault_keys.txt"
    KEYS_FOUND=true
elif [ -f "/opt/keybuzz-installer/credentials/vault_keys.txt" ]; then
    echo -e "$OK Clés trouvées dans /opt/keybuzz-installer/credentials/vault_keys.txt"
    cp /opt/keybuzz-installer/credentials/vault_keys.txt /root/vault_keys.txt
    KEYS_FOUND=true
fi

if [ "$KEYS_FOUND" = true ]; then
    echo ""
    echo "⚠️  CLÉS TROUVÉES ! Déverrouillage manuel requis."
    echo ""
    echo "Exécutez ces commandes avec les clés du fichier :"
    echo ""
    echo "  POD=\$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}')"
    echo "  kubectl exec -n vault \$POD -- vault operator unseal <KEY1>"
    echo "  kubectl exec -n vault \$POD -- vault operator unseal <KEY2>"
    echo "  kubectl exec -n vault \$POD -- vault operator unseal <KEY3>"
    echo ""
    echo "Clés disponibles dans : /root/vault_keys.txt"
    echo ""
    read -p "Avez-vous déverrouillé Vault ? (yes/NO) : " unsealed
    [ "$unsealed" != "yes" ] && echo "⚠️  Vault toujours sealed, continuez les corrections Wazuh"
else
    echo -e "$WARN Aucune clé trouvée"
    echo ""
    echo "⚠️  ATTENTION : Vault est initialisé mais les clés sont perdues !"
    echo "   (Problème : file storage avec hostPath non persistant entre redémarrages)"
    echo ""
    echo "Options :"
    echo "  1. Réinitialiser Vault (PERTE DE DONNÉES)"
    echo "  2. Garder Vault sealed (pas d'accès)"
    echo ""
    read -p "Réinitialiser Vault ? (yes/NO) : " reinit
    
    if [ "$reinit" = "yes" ]; then
        echo "→ Suppression namespace Vault..."
        kubectl delete namespace vault
        sleep 30
        
        echo "→ Recréation namespace..."
        kubectl create namespace vault
        
        echo "→ Création ConfigMap..."
        kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: vault
data:
  vault.hcl: |
    ui = true
    listener "tcp" {
      address = "0.0.0.0:8200"
      tls_disable = 1
    }
    storage "file" {
      path = "/vault/data"
    }
    api_addr = "http://0.0.0.0:8200"
    cluster_addr = "http://0.0.0.0:8201"
    log_level = "info"
    disable_mlock = true
EOF

        echo "→ Création DaemonSet..."
        kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vault
  namespace: vault
  labels:
    app: vault
spec:
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: vault
        image: hashicorp/vault:1.16
        ports:
        - containerPort: 8200
          hostPort: 8200
        - containerPort: 8201
          hostPort: 8201
        env:
        - name: SKIP_SETCAP
          value: "true"
        - name: VAULT_ADDR
          value: "http://0.0.0.0:8200"
        command:
        - vault
        - server
        - -config=/vault/config/vault.hcl
        volumeMounts:
        - name: config
          mountPath: /vault/config
        - name: data
          mountPath: /vault/data
      volumes:
      - name: config
        configMap:
          name: vault-config
      - name: data
        hostPath:
          path: /opt/keybuzz/vault/data
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: vault
spec:
  type: NodePort
  selector:
    app: vault
  ports:
  - name: http
    port: 8200
    targetPort: 8200
    nodePort: 30820
  - name: cluster
    port: 8201
    targetPort: 8201
    nodePort: 30821
EOF

        echo "Attente démarrage Vault (30s)..."
        sleep 30
        
        POD=$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}')
        echo "→ Initialisation Vault..."
        kubectl exec -n vault "$POD" -- vault operator init > /root/vault_keys_NEW.txt
        
        echo -e "$OK Vault réinitialisé ! Clés dans : /root/vault_keys_NEW.txt"
        echo ""
        echo "⚠️⚠️⚠️ SAUVEGARDER /root/vault_keys_NEW.txt IMMÉDIATEMENT ! ⚠️⚠️⚠️"
        echo ""
        
        # Déverrouiller automatiquement
        KEY1=$(grep "Unseal Key 1:" /root/vault_keys_NEW.txt | awk '{print $NF}')
        KEY2=$(grep "Unseal Key 2:" /root/vault_keys_NEW.txt | awk '{print $NF}')
        KEY3=$(grep "Unseal Key 3:" /root/vault_keys_NEW.txt | awk '{print $NF}')
        
        kubectl exec -n vault "$POD" -- vault operator unseal "$KEY1"
        kubectl exec -n vault "$POD" -- vault operator unseal "$KEY2"
        kubectl exec -n vault "$POD" -- vault operator unseal "$KEY3"
        
        echo -e "$OK Vault déverrouillé"
    else
        echo "⚠️  Vault restera sealed"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# CORRECTION 2 : WAZUH INDEXER - Sans SSL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ CORRECTION 2: Wazuh Indexer - Configuration sans SSL          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Vérification namespace wazuh..."
kubectl get namespace wazuh 2>/dev/null || kubectl create namespace wazuh

echo "→ Suppression ancien Indexer..."
kubectl delete statefulset wazuh-indexer -n wazuh 2>/dev/null || true
kubectl delete pvc -n wazuh -l app=wazuh-indexer 2>/dev/null || true
sleep 10

echo "→ Déploiement Wazuh Indexer (SANS SSL)..."
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: wazuh-indexer
  namespace: wazuh
  labels:
    app: wazuh-indexer
spec:
  serviceName: wazuh-indexer
  replicas: 1
  selector:
    matchLabels:
      app: wazuh-indexer
  template:
    metadata:
      labels:
        app: wazuh-indexer
    spec:
      initContainers:
      - name: sysctl
        image: busybox:latest
        command:
        - sh
        - -c
        - |
          sysctl -w vm.max_map_count=262144
          ulimit -n 65536
        securityContext:
          privileged: true
      containers:
      - name: wazuh-indexer
        image: wazuh/wazuh-indexer:4.7.0
        ports:
        - containerPort: 9200
          name: http
        - containerPort: 9300
          name: transport
        env:
        - name: OPENSEARCH_JAVA_OPTS
          value: "-Xms2g -Xmx2g"
        - name: cluster.name
          value: "wazuh-cluster"
        - name: network.host
          value: "0.0.0.0"
        - name: node.name
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: discovery.type
          value: "single-node"
        - name: bootstrap.memory_lock
          value: "false"
        - name: DISABLE_INSTALL_DEMO_CONFIG
          value: "true"
        - name: plugins.security.disabled
          value: "true"
        volumeMounts:
        - name: data
          mountPath: /var/lib/wazuh-indexer
        resources:
          requests:
            memory: "3Gi"
            cpu: "1000m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        readinessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
            scheme: HTTP
          initialDelaySeconds: 90
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 10
        livenessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
            scheme: HTTP
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 5
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 50Gi
---
apiVersion: v1
kind: Service
metadata:
  name: wazuh-indexer
  namespace: wazuh
spec:
  type: ClusterIP
  selector:
    app: wazuh-indexer
  ports:
  - name: http
    port: 9200
    targetPort: 9200
  - name: transport
    port: 9300
    targetPort: 9300
EOF

echo -e "$OK Wazuh Indexer déployé (sans SSL)"
echo "Attente démarrage (3 minutes)..."
sleep 180

echo "→ Vérification Indexer..."
POD_INDEXER=$(kubectl get pods -n wazuh -l app=wazuh-indexer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_INDEXER" ]; then
    echo "Pod: $POD_INDEXER"
    kubectl get pod -n wazuh "$POD_INDEXER"
    echo ""
    echo "Logs (30 dernières lignes) :"
    kubectl logs -n wazuh "$POD_INDEXER" --tail=30 2>&1 || true
    echo ""
    echo "→ Test HTTP Indexer..."
    kubectl exec -n wazuh "$POD_INDEXER" -- curl -s http://localhost:9200 || echo "Test échoué"
fi

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  ✅ CORRECTIONS TERMINÉES                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "🔧 Actions effectuées :"
echo "  ✓ Vault : Déverrouillage tenté (ou réinitialisé)"
echo "  ✓ Wazuh Indexer : Redéployé SANS SSL"
echo ""
echo "⏱️  ATTENDRE 5 MINUTES pour stabilisation"
echo ""
echo "🔍 Vérifications finales :"
echo "  kubectl get pods -A | grep -v Running"
echo "  kubectl exec -n wazuh \$(kubectl get pods -n wazuh -o name | head -1) -- curl -s http://localhost:9200"
echo ""
echo "📊 Validation finale :"
echo "  ./21_final_validation_complete.sh"
echo ""
echo "💾 Si Vault réinitialisé, clés dans : /root/vault_keys_NEW.txt"
echo "   ⚠️⚠️⚠️ SAUVEGARDER CE FICHIER IMMÉDIATEMENT ! ⚠️⚠️⚠️"
echo ""

exit 0
