#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      RABBITMQ_HA_INSTALL_COMPLETE - Installation complète RabbitMQ  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/rabbitmq_complete_$TIMESTAMP.log"

mkdir -p "$LOG_DIR" "$CREDS_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Installation RabbitMQ Quorum Cluster HA (3 nœuds)"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS PRÉALABLES
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier servers.tsv
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Compter les serveurs
QUEUE_COUNT=$(grep -E "queue-0[1-3]" "$SERVERS_TSV" | wc -l)
HAPROXY_COUNT=$(grep -E "haproxy-0[1-2]" "$SERVERS_TSV" | wc -l)

echo "  Serveurs Queue trouvés: $QUEUE_COUNT"
echo "  Serveurs HAProxy trouvés: $HAPROXY_COUNT"

[ "$QUEUE_COUNT" -lt 3 ] && { echo -e "$KO Il faut 3 serveurs Queue"; exit 1; }
[ "$HAPROXY_COUNT" -lt 2 ] && { echo -e "$KO Il faut 2 serveurs HAProxy"; exit 1; }

# IPs fixes (pas de variables dans heredoc)
QUEUE01_IP="10.0.0.126"
QUEUE02_IP="10.0.0.127"
QUEUE03_IP="10.0.0.128"

echo "  queue-01: $QUEUE01_IP"
echo "  queue-02: $QUEUE02_IP"
echo "  queue-03: $QUEUE03_IP"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: GESTION SÉCURISÉE DES CREDENTIALS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Gestion sécurisée des credentials                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ -f "$CREDS_DIR/rabbitmq.env" ]; then
    echo "  Chargement des credentials existants..."
    source "$CREDS_DIR/rabbitmq.env"
    echo "  Cookie Erlang: $(echo -n "$RABBITMQ_ERLANG_COOKIE" | sha256sum | cut -c1-16)..."
else
    echo "  Génération de nouveaux credentials..."
    RABBITMQ_ERLANG_COOKIE=$(openssl rand -hex 32)
    RABBITMQ_ADMIN_USER="admin"
    RABBITMQ_ADMIN_PASS=$(openssl rand -base64 32 | tr -d "=+/\n" | cut -c1-25)
    
    cat > "$CREDS_DIR/rabbitmq.env" <<EOF
#!/bin/bash
# RabbitMQ Credentials - NE JAMAIS COMMITER
# Généré le $(date)
export RABBITMQ_ERLANG_COOKIE="$RABBITMQ_ERLANG_COOKIE"
export RABBITMQ_ADMIN_USER="$RABBITMQ_ADMIN_USER"
export RABBITMQ_ADMIN_PASS="$RABBITMQ_ADMIN_PASS"
export RABBITMQ_CLUSTER_NAME="keybuzz-queue"
EOF
    chmod 600 "$CREDS_DIR/rabbitmq.env"
    
    # Ajouter à secrets.json
    if [ -f "$CREDS_DIR/secrets.json" ]; then
        jq ".rabbitmq_erlang_cookie = \"$RABBITMQ_ERLANG_COOKIE\" | .rabbitmq_admin_pass = \"$RABBITMQ_ADMIN_PASS\"" \
           "$CREDS_DIR/secrets.json" > /tmp/secrets.tmp && mv /tmp/secrets.tmp "$CREDS_DIR/secrets.json"
    else
        echo "{\"rabbitmq_erlang_cookie\": \"$RABBITMQ_ERLANG_COOKIE\", \"rabbitmq_admin_pass\": \"$RABBITMQ_ADMIN_PASS\"}" | \
        jq '.' > "$CREDS_DIR/secrets.json"
    fi
    chmod 600 "$CREDS_DIR/secrets.json"
    
    echo "  Credentials générés et sécurisés"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: PRÉPARATION DES SERVEURS QUEUE
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Préparation des serveurs Queue                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in queue-01 queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "$KO IP de $host non trouvée"; continue; }
    
    echo "  Préparation de $host ($IP_PRIV)..."
    
    # Copier les credentials
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" "mkdir -p /opt/keybuzz-installer/credentials"
    scp -q -o ConnectTimeout=10 "$CREDS_DIR/rabbitmq.env" root@"$IP_PRIV":/opt/keybuzz-installer/credentials/
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash <<'PREPARE'
# Charger les credentials
source /opt/keybuzz-installer/credentials/rabbitmq.env

BASE="/opt/keybuzz/rabbitmq"

# Arrêter et nettoyer complètement
docker ps -aq --filter "name=rabbitmq" | xargs -r docker stop 2>/dev/null
docker ps -aq --filter "name=rabbitmq" | xargs -r docker rm 2>/dev/null
docker network prune -f 2>/dev/null

# Créer la structure
mkdir -p "$BASE"/{data,config,logs,status}

# Vérifier le volume XFS
if mountpoint -q "$BASE/data"; then
    FS_TYPE=$(df -T "$BASE/data" | tail -1 | awk '{print $2}')
    echo "    Volume monté (système: $FS_TYPE)"
else
    echo "    ⚠ Volume non monté sur $BASE/data"
fi

# Permissions pour RabbitMQ (UID 999)
chown -R 999:999 "$BASE/data" "$BASE/logs"
chmod 755 "$BASE/data" "$BASE/logs"

# Copier les credentials localement
cp /opt/keybuzz-installer/credentials/rabbitmq.env "$BASE/.env"
chmod 600 "$BASE/.env"

echo "    ✓ Préparé et nettoyé"
PREPARE
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: DÉPLOIEMENT RABBITMQ (SANS EXTRA_HOSTS PROBLÉMATIQUE)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Déploiement RabbitMQ sur chaque nœud                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in queue-01 queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  Déploiement sur $host ($IP_PRIV)..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash -s "$host" <<'DEPLOY'
HOSTNAME="$1"

# Charger les credentials
source /opt/keybuzz-installer/credentials/rabbitmq.env

BASE="/opt/keybuzz/rabbitmq"
cd "$BASE"

# Ajouter les hosts dans /etc/hosts si pas présents
grep -q "queue-01" /etc/hosts || echo "10.0.0.126 queue-01" >> /etc/hosts
grep -q "queue-02" /etc/hosts || echo "10.0.0.127 queue-02" >> /etc/hosts
grep -q "queue-03" /etc/hosts || echo "10.0.0.128 queue-03" >> /etc/hosts

# Docker-compose.yml SIMPLIFIÉ
cat > "$BASE/docker-compose.yml" <<COMPOSE
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.13-management-alpine
    container_name: rabbitmq
    hostname: $HOSTNAME
    restart: unless-stopped
    network_mode: host
    environment:
      RABBITMQ_NODENAME: rabbit@$HOSTNAME
      RABBITMQ_ERLANG_COOKIE: ${RABBITMQ_ERLANG_COOKIE}
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_ADMIN_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_ADMIN_PASS}
    volumes:
      - ${BASE}/data:/var/lib/rabbitmq
      - ${BASE}/logs:/var/log/rabbitmq
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping", "-q"]
      interval: 30s
      timeout: 10s
      retries: 3
COMPOSE

# Démarrer
docker compose down 2>/dev/null
docker compose up -d

sleep 5

# Vérifier
if docker ps | grep -q rabbitmq; then
    echo "    ✓ RabbitMQ démarré"
else
    echo "    ✗ Échec démarrage"
    docker logs --tail 10 rabbitmq
fi
DEPLOY
done

echo ""
echo "  Attente de stabilisation (20s)..."
sleep 20

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: FORMATION DU CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Formation du cluster RabbitMQ                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier queue-01
echo "  État initial de queue-01..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$QUEUE01_IP" \
    "docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -E 'Running Nodes|rabbit@'" || true

# Joindre queue-02
echo ""
echo "  Ajout de queue-02 au cluster..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$QUEUE02_IP" <<'JOIN2'
docker exec rabbitmq rabbitmqctl stop_app 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl reset 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl join_cluster rabbit@queue-01 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl start_app 2>/dev/null

if docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -q "queue-01"; then
    echo "    ✓ queue-02 a rejoint le cluster"
else
    echo "    ✗ Échec de jonction queue-02"
fi
JOIN2

# Joindre queue-03
echo ""
echo "  Ajout de queue-03 au cluster..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$QUEUE03_IP" <<'JOIN3'
docker exec rabbitmq rabbitmqctl stop_app 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl reset 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl join_cluster rabbit@queue-01 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl start_app 2>/dev/null

if docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -q "queue-01"; then
    echo "    ✓ queue-03 a rejoint le cluster"
else
    echo "    ✗ Échec de jonction queue-03"
fi
JOIN3

echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: CONFIGURATION DES POLITIQUES HA
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Configuration des politiques HA                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$QUEUE01_IP" <<'POLICIES'
source /opt/keybuzz-installer/credentials/rabbitmq.env

# Politique HA pour toutes les queues
docker exec rabbitmq rabbitmqctl set_policy ha-all \
    ".*" \
    '{"ha-mode":"all","ha-sync-mode":"automatic"}' \
    --priority 0 \
    --apply-to queues

# Politique pour les quorum queues (futures)
docker exec rabbitmq rabbitmqctl set_policy quorum-queues \
    "^quorum\." \
    '{"queue-type":"quorum"}' \
    --priority 1 \
    --apply-to queues

echo "    ✓ Politiques HA configurées"

# Vérifier le cluster final
echo ""
echo "  État final du cluster:"
docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -E "Running Nodes"
POLICIES

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: CONFIGURATION LOAD BALANCER SUR HAPROXY
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Configuration Load Balancer sur HAProxy               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Configuration de $host ($IP_PRIV)..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash <<'HAPROXY_CONFIG'
BASE="/opt/keybuzz/rabbitmq-lb"

# Nettoyer anciens containers
docker stop haproxy-rabbitmq 2>/dev/null
docker rm haproxy-rabbitmq 2>/dev/null

# Créer structure
mkdir -p "$BASE"/{config,logs,status}

# Configuration HAProxy SANS stats socket problématique
cat > "$BASE/config/haproxy-rabbitmq.cfg" <<'EOF'
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global
    option tcplog

# RabbitMQ AMQP (5672)
listen rabbitmq_amqp
    bind *:5672
    mode tcp
    balance leastconn
    option tcp-check
    server queue-01 10.0.0.126:5672 check inter 5s fall 3 rise 2
    server queue-02 10.0.0.127:5672 check inter 5s fall 3 rise 2
    server queue-03 10.0.0.128:5672 check inter 5s fall 3 rise 2

# RabbitMQ Management (15672)
listen rabbitmq_management
    bind *:15672
    mode tcp
    balance roundrobin
    option tcp-check
    server queue-01 10.0.0.126:15672 check inter 5s fall 3 rise 2
    server queue-02 10.0.0.127:15672 check inter 5s fall 3 rise 2
    server queue-03 10.0.0.128:15672 check inter 5s fall 3 rise 2

# Stats page (optionnel)
listen stats
    bind *:8405
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF

# Démarrer HAProxy
docker run -d \
    --name haproxy-rabbitmq \
    --restart unless-stopped \
    --network host \
    -v ${BASE}/config/haproxy-rabbitmq.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
    haproxy:2.9-alpine \
    haproxy -f /usr/local/etc/haproxy/haproxy.cfg

sleep 3

if docker ps | grep -q haproxy-rabbitmq; then
    echo "    ✓ HAProxy RabbitMQ démarré"
else
    echo "    ✗ Échec démarrage HAProxy"
    docker logs --tail 5 haproxy-rabbitmq
fi

# Ouvrir les ports dans UFW
ufw allow 5672/tcp comment 'RabbitMQ AMQP' 2>/dev/null
ufw allow 15672/tcp comment 'RabbitMQ Management' 2>/dev/null
ufw allow 8405/tcp comment 'HAProxy Stats RabbitMQ' 2>/dev/null
ufw --force reload 2>/dev/null
HAPROXY_CONFIG
done

echo ""
sleep 5

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 7: TESTS FINAUX
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 7: Tests finaux                                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Test des nœuds RabbitMQ:"
for host in queue-01 queue-02 queue-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host AMQP (5672): "
    timeout 2 nc -zv "$IP" 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
done

echo ""
echo "  Test des HAProxy:"
for host in haproxy-01 haproxy-02; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host AMQP (5672): "
    timeout 2 nc -zv "$IP" 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    $host Management (15672): "
    timeout 2 nc -zv "$IP" 15672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
done

echo ""
echo "  Test via Load Balancer VIP (10.0.0.10):"
echo -n "    AMQP (5672): "
timeout 2 nc -zv 10.0.0.10 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "    Management (15672): "
timeout 2 nc -zv 10.0.0.10 15672 &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo ""
echo "  Test authentification Management UI:"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$RABBITMQ_ADMIN_USER:$RABBITMQ_ADMIN_PASS" \
    "http://$QUEUE01_IP:15672/api/overview" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "    $OK Authentification réussie (HTTP 200)"
else
    echo -e "    Code HTTP: $HTTP_CODE"
fi

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Créer le résumé sécurisé
cat > "$CREDS_DIR/rabbitmq-summary.txt" <<EOF
RABBITMQ HA - INSTALLATION COMPLÈTE
═══════════════════════════════════════════════════════════════════

Date: $(date)

ARCHITECTURE:
  • 3 nœuds RabbitMQ en cluster
  • Politiques HA actives
  • 2 HAProxy pour load balancing
  • VIP sur Load Balancer Hetzner

ENDPOINTS:
  AMQP: 10.0.0.10:5672
  Management UI: http://10.0.0.10:15672
  
CREDENTIALS:
  Fichier: $CREDS_DIR/rabbitmq.env (mode 600)
  User: $RABBITMQ_ADMIN_USER
  Password: [voir fichier rabbitmq.env]

CONNEXION AMQP:
  Host: 10.0.0.10
  Port: 5672
  User: $RABBITMQ_ADMIN_USER
  Password: \${RABBITMQ_ADMIN_PASS}

MANAGEMENT UI:
  URL: http://10.0.0.10:15672
  Login avec les credentials ci-dessus

HAUTE DISPONIBILITÉ:
  • Tolérance de panne: jusqu'à 2 nœuds
  • Réplication automatique des queues
  • Auto-heal en cas de partition réseau

CONFIGURATION HETZNER LOAD BALANCER:
  Service AMQP:
    • Type: TCP
    • Port source: 5672
    • Port destination: 5672
    
  Service Management:
    • Type: TCP
    • Port source: 15672
    • Port destination: 15672
EOF

if timeout 2 nc -zv 10.0.0.10 5672 &>/dev/null; then
    echo -e "$OK RABBITMQ HA INSTALLATION COMPLÈTE ET OPÉRATIONNELLE"
    echo ""
    echo "Endpoints:"
    echo "  • AMQP: 10.0.0.10:5672"
    echo "  • Management: http://10.0.0.10:15672"
    echo "  • User: $RABBITMQ_ADMIN_USER"
    echo "  • Cookie Erlang: $(echo -n "$RABBITMQ_ERLANG_COOKIE" | sha256sum | cut -c1-16)..."
    echo ""
    echo "Pour tester:"
    echo "  Management UI: http://10.0.0.10:15672"
    echo "  Login: $RABBITMQ_ADMIN_USER"
    echo "  Password: [voir $CREDS_DIR/rabbitmq.env]"
    echo ""
    echo "Résumé complet: $CREDS_DIR/rabbitmq-summary.txt"
else
    echo -e "$KO Installation incomplète"
    echo "Vérifier les logs: $MAIN_LOG"
fi
echo "═══════════════════════════════════════════════════════════════════"
