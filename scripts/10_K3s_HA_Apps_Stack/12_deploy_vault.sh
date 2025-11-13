#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Déploiement HashiCorp Vault                              ║"
echo "║    (DaemonSet + hostNetwork + Backend PostgreSQL)                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/vault_deploy_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Déploiement Vault - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

echo -n "→ Credentials PostgreSQL ... "
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

echo -n "→ Cluster K3s ... "
if kubectl get nodes &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    exit 1
fi

echo ""
echo "Configuration :"
echo "  PostgreSQL : 10.0.0.10:5432 (LB → HAProxy → Patroni)"
echo "  Port Vault : 8200"
echo "  Backend    : PostgreSQL (HA)"
echo ""

read -p "Déployer Vault ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: PRÉPARATION BASE POSTGRESQL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Préparation base PostgreSQL                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

IP_DB="10.0.0.10"
PORT_DB="5432"
DB_NAME="vault"
DB_USER="vault"
DB_PASSWORD="${POSTGRES_PASSWORD:-keybuzz2025}"

echo "Création base et user Vault..."

PGPASSWORD="$POSTGRES_PASSWORD" psql \
  -h "$IP_DB" \
  -p "$PORT_DB" \
  -U postgres \
  -d postgres \
  -c "SELECT 1" &>/dev/null

if [ $? -eq 0 ]; then
    echo -e "$OK Connexion PostgreSQL OK"
else
    echo -e "$KO Connexion PostgreSQL échouée"
    exit 1
fi

# Créer la base
PGPASSWORD="$POSTGRES_PASSWORD" psql \
  -h "$IP_DB" \
  -p "$PORT_DB" \
  -U postgres \
  -d postgres <<EOSQL
-- Créer base si n'existe pas
SELECT 'CREATE DATABASE vault'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'vault')\gexec

-- Créer user si n'existe pas
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'vault') THEN
    CREATE USER vault WITH PASSWORD '$DB_PASSWORD';
  END IF;
END
\$\$;

-- Permissions
GRANT ALL PRIVILEGES ON DATABASE vault TO vault;
\c vault
ALTER SCHEMA public OWNER TO vault;
GRANT ALL PRIVILEGES ON SCHEMA public TO vault;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO vault;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO vault;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO vault;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO vault;
EOSQL

echo -e "$OK Base vault créée"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: CRÉATION NAMESPACE
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Création namespace                                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl create namespace vault 2>/dev/null || true
echo -e "$OK Namespace vault créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: CRÉATION SECRETS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Création secrets                                      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

DB_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${IP_DB}:${PORT_DB}/${DB_NAME}?sslmode=disable"

kubectl create secret generic vault-secrets -n vault \
  --from-literal=DATABASE_URL="$DB_URL" \
  --from-literal=VAULT_ADDR="http://0.0.0.0:8200" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "$OK Secrets Vault créés"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: DÉPLOIEMENT VAULT DAEMONSET
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Déploiement Vault DaemonSet                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
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
    
    storage "postgresql" {
      connection_url = "postgresql://vault:VAULT_DB_PASSWORD@10.0.0.10:5432/vault?sslmode=disable"
      ha_enabled = "true"
      max_parallel = "128"
    }
    
    api_addr = "http://0.0.0.0:8200"
    cluster_addr = "http://0.0.0.0:8201"
    
    log_level = "info"
    disable_mlock = true
---
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
          name: http
        - containerPort: 8201
          hostPort: 8201
          name: cluster
        env:
        - name: SKIP_SETCAP
          value: "true"
        - name: VAULT_ADDR
          value: "http://0.0.0.0:8200"
        - name: VAULT_API_ADDR
          value: "http://0.0.0.0:8200"
        - name: VAULT_CLUSTER_ADDR
          value: "http://0.0.0.0:8201"
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
            cpu: "1000m"
        readinessProbe:
          httpGet:
            path: /v1/sys/health?standbyok=true
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 2
        livenessProbe:
          httpGet:
            path: /v1/sys/health?standbyok=true
            port: 8200
            scheme: HTTP
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 3
      volumes:
      - name: config
        configMap:
          name: vault-config
      - name: data
        emptyDir: {}
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

# Remplacer le password dans le ConfigMap
kubectl patch configmap vault-config -n vault --type merge -p "{\"data\":{\"vault.hcl\":\"$(kubectl get configmap vault-config -n vault -o jsonpath='{.data.vault\.hcl}' | sed "s/VAULT_DB_PASSWORD/${DB_PASSWORD}/g")\"}}"

echo -e "$OK Vault DaemonSet déployé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: CRÉATION INGRESS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Création Ingress                                      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault
  namespace: vault
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
spec:
  ingressClassName: nginx
  rules:
  - host: vault.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vault
            port:
              number: 8200
EOF

echo -e "$OK Ingress vault créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: ATTENTE ET VÉRIFICATION
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Attente démarrage (60s)                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Pods Vault :"
kubectl get pods -n vault -o wide
echo ""

echo "Services :"
kubectl get svc -n vault
echo ""

echo "Ingress :"
kubectl get ingress -n vault
echo ""

echo "DaemonSet :"
kubectl get daemonset -n vault
echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    ✅ Vault déployé avec succès                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Configuration :"
echo "  URL externe : http://vault.keybuzz.io"
echo "  URL interne : http://vault.vault.svc:8200"
echo "  NodePort    : 30820 (HTTP) / 30821 (Cluster)"
echo ""
echo "🔧 Backend :"
echo "  Type        : PostgreSQL (HA)"
echo "  Connexion   : 10.0.0.10:5432/vault"
echo ""
echo "⚠️  IMPORTANT - Initialisation Vault :"
echo ""
echo "1️⃣  Initialiser Vault (PREMIÈRE FOIS UNIQUEMENT) :"
echo "  kubectl exec -n vault \$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}') -- vault operator init"
echo ""
echo "  ⚠️  Sauvegarder les clés de déverrouillage et le root token !"
echo ""
echo "2️⃣  Déverrouiller Vault (après chaque redémarrage, 3 clés minimum) :"
echo "  kubectl exec -n vault \$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}') -- vault operator unseal <key1>"
echo "  kubectl exec -n vault \$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}') -- vault operator unseal <key2>"
echo "  kubectl exec -n vault \$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}') -- vault operator unseal <key3>"
echo ""
echo "3️⃣  Se connecter :"
echo "  export VAULT_ADDR=http://vault.keybuzz.io"
echo "  vault login <root_token>"
echo ""
echo "Prochaine étape :"
echo "  ./13_deploy_monitoring_stack.sh (si pas déjà fait)"
echo "  ./19_deploy_wazuh_siem.sh"
echo ""

exit 0
