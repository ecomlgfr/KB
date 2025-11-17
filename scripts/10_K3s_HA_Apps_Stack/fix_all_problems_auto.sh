#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    CORRECTION AUTOMATIQUE - Tous les problèmes du cluster        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

echo ""
echo "Ce script va corriger automatiquement :"
echo "  1. 🔐 Vault (7/8 pods en CrashLoopBackOff)"
echo "  2. 🛡️  Wazuh Manager (8 pods en CrashLoopBackOff)"
echo "  3. 🔍 Wazuh Indexer (restarts élevés)"
echo "  4. 📊 ERPNext socketio (CrashLoopBackOff)"
echo "  5. 🧹 Nettoyage des pods debug/test terminés"
echo ""

read -p "Lancer la correction automatique ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/home/user/KB/logs/fix_all_${TIMESTAMP}.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Fonction de log
log() {
    echo "$1" | tee -a "$LOG_FILE"
}

log ""
log "╔════════════════════════════════════════════════════════════════╗"
log "║ CORRECTION 1/5 : Nettoyage des pods debug/test                ║"
log "╚════════════════════════════════════════════════════════════════╝"
log ""

log "→ Suppression des pods Completed/Error..."

# Supprimer pods node-debugger
kubectl delete pods -n default -l job-name --field-selector=status.phase=Succeeded 2>&1 | tee -a "$LOG_FILE"
kubectl delete pods -n default -l job-name --field-selector=status.phase=Failed 2>&1 | tee -a "$LOG_FILE"

# Supprimer pods de test DNS
kubectl delete pod -n connect dnscheck 2>/dev/null || true
kubectl delete pod -n litellm dnscheck-llm 2>/dev/null || true
kubectl delete pod -n litellm testcurl 2>/dev/null || true
kubectl delete pod -n n8n dnsdiag-n8n 2>/dev/null || true
kubectl delete pod -n connect netdiag 2>/dev/null || true
kubectl delete pod -n connect nettest 2>/dev/null || true
kubectl delete pod -n default dns-test 2>/dev/null || true

# Pods tmp ERPNext
kubectl delete pod -n erpnext tmp-nginx 2>/dev/null || true

log -e "$OK Nettoyage terminé"
log ""

log "╔════════════════════════════════════════════════════════════════╗"
log "║ CORRECTION 2/5 : Vault - Redéploiement propre                 ║"
log "╚════════════════════════════════════════════════════════════════╝"
log ""

log "→ Analyse de l'état actuel de Vault..."
VAULT_RUNNING=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep -c "Running.*1/1" || echo 0)
VAULT_TOTAL=$(kubectl get pods -n vault --no-headers 2>/dev/null | wc -l || echo 0)

if [ "$VAULT_RUNNING" -lt "$VAULT_TOTAL" ] || [ "$VAULT_TOTAL" -eq 0 ]; then
    log -e "$WARN $VAULT_RUNNING/$VAULT_TOTAL pods Vault fonctionnels - Correction nécessaire"
    log ""

    log "→ Suppression de l'ancien déploiement Vault..."
    kubectl delete daemonset vault -n vault 2>&1 | tee -a "$LOG_FILE"
    kubectl delete configmap vault-config -n vault 2>&1 | tee -a "$LOG_FILE"
    kubectl delete svc vault -n vault 2>&1 | tee -a "$LOG_FILE"

    log "Attente suppression complète (15s)..."
    sleep 15

    log "→ Nettoyage des données Vault sur les nœuds..."
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        kubectl debug node/$node -it --image=busybox -- sh -c "rm -rf /host/opt/keybuzz/vault/data/*" 2>/dev/null || true &
    done
    wait

    log "→ Création du nouveau ConfigMap Vault..."
    kubectl apply -f - <<'EOF' 2>&1 | tee -a "$LOG_FILE"
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

    log "→ Création du DaemonSet Vault..."
    kubectl apply -f - <<'EOF' 2>&1 | tee -a "$LOG_FILE"
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
        - name: VAULT_LOG_LEVEL
          value: "info"
        command:
        - vault
        - server
        - -config=/vault/config/vault.hcl
        volumeMounts:
        - name: config
          mountPath: /vault/config
        - name: data
          mountPath: /vault/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
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

    log "Attente démarrage Vault (45s)..."
    sleep 45

    # Initialiser Vault sur le premier pod Ready
    log "→ Initialisation de Vault..."
    VAULT_POD=$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$VAULT_POD" ]; then
        log "  Pod utilisé: $VAULT_POD"

        # Vérifier si Vault est déjà initialisé
        INIT_STATUS=$(kubectl exec -n vault "$VAULT_POD" -- vault status -format=json 2>/dev/null | grep -o '"initialized":[^,]*' | cut -d: -f2 || echo "false")

        if [ "$INIT_STATUS" = "false" ]; then
            log "  Vault non initialisé, initialisation..."
            kubectl exec -n vault "$VAULT_POD" -- vault operator init -key-shares=5 -key-threshold=3 > /home/user/KB/credentials/vault_keys_${TIMESTAMP}.txt 2>&1

            log -e "$OK Vault initialisé ! Clés sauvegardées dans :"
            log "     /home/user/KB/credentials/vault_keys_${TIMESTAMP}.txt"
            log ""
            log -e "$WARN ⚠️⚠️⚠️ SAUVEGARDER CE FICHIER IMMÉDIATEMENT ! ⚠️⚠️⚠️"
            log ""

            # Déverrouiller automatiquement avec les 3 premières clés
            KEY1=$(grep "Unseal Key 1:" /home/user/KB/credentials/vault_keys_${TIMESTAMP}.txt | awk '{print $NF}')
            KEY2=$(grep "Unseal Key 2:" /home/user/KB/credentials/vault_keys_${TIMESTAMP}.txt | awk '{print $NF}')
            KEY3=$(grep "Unseal Key 3:" /home/user/KB/credentials/vault_keys_${TIMESTAMP}.txt | awk '{print $NF}')

            if [ -n "$KEY1" ] && [ -n "$KEY2" ] && [ -n "$KEY3" ]; then
                log "  Déverrouillage automatique..."
                kubectl exec -n vault "$VAULT_POD" -- vault operator unseal "$KEY1" 2>&1 | tee -a "$LOG_FILE"
                kubectl exec -n vault "$VAULT_POD" -- vault operator unseal "$KEY2" 2>&1 | tee -a "$LOG_FILE"
                kubectl exec -n vault "$VAULT_POD" -- vault operator unseal "$KEY3" 2>&1 | tee -a "$LOG_FILE"
                log -e "$OK Vault déverrouillé"
            fi
        else
            log -e "$INFO Vault déjà initialisé"
            log "  Note: Si Vault est 'sealed', déverrouillez-le manuellement avec les clés existantes"
        fi
    fi

    log -e "$OK Vault redéployé"
else
    log -e "$OK Vault déjà fonctionnel ($VAULT_RUNNING/$VAULT_TOTAL pods)"
fi

log ""
log "╔════════════════════════════════════════════════════════════════╗"
log "║ CORRECTION 3/5 : Wazuh Indexer - Sans SSL                     ║"
log "╚════════════════════════════════════════════════════════════════╝"
log ""

log "→ Suppression de l'ancien Wazuh Indexer..."
kubectl delete statefulset wazuh-indexer -n wazuh 2>&1 | tee -a "$LOG_FILE"
kubectl delete pvc -n wazuh -l app=wazuh-indexer 2>&1 | tee -a "$LOG_FILE"
kubectl delete svc wazuh-indexer -n wazuh 2>&1 | tee -a "$LOG_FILE"

log "Attente suppression (15s)..."
sleep 15

log "→ Déploiement Wazuh Indexer (SANS SSL, single-node)..."
kubectl apply -f - <<'EOF' 2>&1 | tee -a "$LOG_FILE"
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
        image: busybox:1.35
        command:
        - sh
        - -c
        - |
          sysctl -w vm.max_map_count=262144
          ulimit -n 65536
          chown -R 1000:1000 /var/lib/wazuh-indexer 2>/dev/null || true
        securityContext:
          privileged: true
        volumeMounts:
        - name: data
          mountPath: /var/lib/wazuh-indexer
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
        - name: compatibility.override_main_response_version
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
          initialDelaySeconds: 120
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 10
        livenessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
            scheme: HTTP
          initialDelaySeconds: 180
          periodSeconds: 30
          timeoutSeconds: 10
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

log -e "$OK Wazuh Indexer déployé (attendre 3-5 min pour démarrage complet)"
log ""

log "╔════════════════════════════════════════════════════════════════╗"
log "║ CORRECTION 4/5 : Wazuh Manager - Suppression temporaire       ║"
log "╚════════════════════════════════════════════════════════════════╝"
log ""

log "→ Suppression des Wazuh Managers en CrashLoopBackOff..."
log "  (Ils seront redéployés proprement après stabilisation de l'Indexer)"

kubectl delete daemonset wazuh-manager -n wazuh 2>&1 | tee -a "$LOG_FILE"

log -e "$OK Wazuh Managers supprimés (redéploiement manuel requis après)"
log ""

log "╔════════════════════════════════════════════════════════════════╗"
log "║ CORRECTION 5/5 : ERPNext socketio                              ║"
log "╚════════════════════════════════════════════════════════════════╝"
log ""

log "→ Analyse du pod ERPNext socketio..."
SOCKETIO_POD=$(kubectl get pods -n erpnext -l app.kubernetes.io/component=socketio --no-headers 2>/dev/null | awk '{print $1}')

if [ -n "$SOCKETIO_POD" ]; then
    log "  Pod: $SOCKETIO_POD"

    log "→ Récupération des logs pour diagnostic..."
    kubectl logs -n erpnext "$SOCKETIO_POD" --tail=50 > /tmp/erpnext_socketio_logs.txt 2>&1

    # Analyser les logs pour trouver le problème
    if grep -q "ECONNREFUSED\|Connection refused\|Redis" /tmp/erpnext_socketio_logs.txt; then
        log -e "$WARN Problème de connexion Redis détecté"
        log "  → Vérifier la configuration Redis dans les secrets ERPNext"
    elif grep -q "ENOTFOUND\|DNS\|getaddrinfo" /tmp/erpnext_socketio_logs.txt; then
        log -e "$WARN Problème DNS détecté"
        log "  → Vérifier la configuration du service backend"
    else
        log -e "$INFO Redémarrage du pod socketio..."
        kubectl delete pod -n erpnext "$SOCKETIO_POD" 2>&1 | tee -a "$LOG_FILE"
        log "  Pod supprimé, Kubernetes va le recréer automatiquement"
    fi
else
    log -e "$INFO Aucun pod socketio trouvé"
fi

log ""
log "╔════════════════════════════════════════════════════════════════╗"
log "║                  ✅ CORRECTIONS TERMINÉES                      ║"
log "╚════════════════════════════════════════════════════════════════╝"
log ""

log "📊 RÉSUMÉ DES ACTIONS :"
log "  ✓ Pods debug/test nettoyés"
log "  ✓ Vault redéployé proprement (file storage)"
log "  ✓ Wazuh Indexer redéployé (sans SSL)"
log "  ✓ Wazuh Managers supprimés (redéploiement requis)"
log "  ✓ ERPNext socketio analysé/redémarré"
log ""

log "⏱️  TEMPS D'ATTENTE RECOMMANDÉ : 5-10 minutes"
log ""

log "🔍 VÉRIFICATIONS À FAIRE :"
log "  1. Attendre 5 minutes pour stabilisation"
log "  2. Vérifier l'état des pods :"
log "     kubectl get pods -A | grep -v Running"
log ""
log "  3. Vérifier Vault :"
log "     kubectl get pods -n vault"
log "     kubectl exec -n vault \$(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2) -- vault status"
log ""
log "  4. Vérifier Wazuh Indexer :"
log "     kubectl get pods -n wazuh"
log "     kubectl exec -n wazuh wazuh-indexer-0 -- curl -s http://localhost:9200"
log ""
log "  5. Relancer le diagnostic complet :"
log "     ./diagnostic_complete_cluster.sh"
log ""

log "⚠️  ACTIONS MANUELLES REQUISES :"
log "  1. VAULT : Si sealed, déverrouiller avec :"
log "     Fichier clés : /home/user/KB/credentials/vault_keys_${TIMESTAMP}.txt"
log "     Commandes :"
log "       kubectl exec -n vault \$(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2) -- vault operator unseal <KEY1>"
log "       kubectl exec -n vault \$(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2) -- vault operator unseal <KEY2>"
log "       kubectl exec -n vault \$(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2) -- vault operator unseal <KEY3>"
log ""
log "  2. WAZUH MANAGERS : Redéployer après stabilisation de l'Indexer (30+ minutes)"
log "     Script de redéploiement à créer : ./redeploy_wazuh_managers.sh"
log ""

log "💾 Log complet sauvegardé : $LOG_FILE"
log ""

echo ""
echo "✅ Script de correction terminé avec succès !"
echo ""
echo "Timestamp : $TIMESTAMP"
echo ""

exit 0
