#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       RABBITMQ_CLUSTER_DEPLOY - Déploiement cluster RabbitMQ       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/rabbitmq_cluster_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Déploiement RabbitMQ Cluster (3 nœuds)"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Charger les credentials
if [ ! -f "$CREDS_DIR/rabbitmq.env" ]; then
    echo -e "$KO Credentials non trouvés. Exécutez d'abord rabbitmq_prep_storage.sh"
    exit 1
fi
source "$CREDS_DIR/rabbitmq.env"

# Obtenir les IPs des 3 nœuds
QUEUE01_IP=$(awk -F'\t' '$2=="queue-01" {print $3}' "$SERVERS_TSV")
QUEUE02_IP=$(awk -F'\t' '$2=="queue-02" {print $3}' "$SERVERS_TSV")
QUEUE03_IP=$(awk -F'\t' '$2=="queue-03" {print $3}' "$SERVERS_TSV")

echo "Configuration du cluster:"
echo "  queue-01 (seed): $QUEUE01_IP"
echo "  queue-02: $QUEUE02_IP"
echo "  queue-03: $QUEUE03_IP"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: Déploiement des conteneurs RabbitMQ
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Déploiement des conteneurs RabbitMQ                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in queue-01 queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Déploiement sur $host ($IP_PRIV)..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash -s "$host" "$IP_PRIV" <<'DEPLOY'
HOSTNAME="$1"
IP_PRIVEE="$2"

# Charger les credentials
source /opt/keybuzz-installer/credentials/rabbitmq.env

BASE="/opt/keybuzz/rabbitmq"
cd "$BASE"

# Créer le fichier .env local
cat > "$BASE/.env" <<EOF
HOSTNAME=$HOSTNAME
IP_PRIVEE=$IP_PRIVEE
RABBITMQ_ERLANG_COOKIE=$RABBITMQ_ERLANG_COOKIE
RABBITMQ_ADMIN_USER=$RABBITMQ_ADMIN_USER
RABBITMQ_ADMIN_PASS=$RABBITMQ_ADMIN_PASS
EOF

# Configuration RabbitMQ
cat > "$BASE/config/rabbitmq.conf" <<EOF
cluster_formation.peer_discovery_backend = rabbit_peer_discovery_classic_config
cluster_formation.classic_config.nodes.1 = rabbit@queue-01
cluster_formation.classic_config.nodes.2 = rabbit@queue-02
cluster_formation.classic_config.nodes.3 = rabbit@queue-03

cluster_name = keybuzz-queue
cluster_partition_handling = autoheal

# Performance
vm_memory_high_watermark.relative = 0.6
disk_free_limit.absolute = 5GB

# Network
tcp_listen_options.backlog = 128
tcp_listen_options.nodelay = true
tcp_listen_options.linger.on = true
tcp_listen_options.linger.timeout = 0

# Management
management.tcp.port = 15672
management.tcp.ip = 0.0.0.0

# Logs
log.file.level = info
log.console = true
log.console.level = info
EOF

# Configuration avancée
cat > "$BASE/config/advanced.config" <<EOF
[
  {rabbit, [
    {tcp_listeners, [5672]},
    {loopback_users, []},
    {default_vhost, <<"/">>},
    {default_user, <<"$RABBITMQ_ADMIN_USER">>},
    {default_pass, <<"$RABBITMQ_ADMIN_PASS">>},
    {default_permissions, [<<".*">>, <<".*">>, <<".*">>]},
    {cluster_nodes, {['rabbit@queue-01', 'rabbit@queue-02', 'rabbit@queue-03'], disc}}
  ]},
  {rabbitmq_management, [
    {listener, [{port, 15672}, {ip, "0.0.0.0"}]}
  ]}
].
EOF

# Docker-compose.yml
cat > "$BASE/docker-compose.yml" <<EOF
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.13-management-alpine
    container_name: rabbitmq
    hostname: $HOSTNAME
    restart: unless-stopped
    environment:
      RABBITMQ_NODENAME: "rabbit@$HOSTNAME"
      RABBITMQ_ERLANG_COOKIE: "$RABBITMQ_ERLANG_COOKIE"
      RABBITMQ_USE_LONGNAME: "false"
      RABBITMQ_DEFAULT_USER: "$RABBITMQ_ADMIN_USER"
      RABBITMQ_DEFAULT_PASS: "$RABBITMQ_ADMIN_PASS"
      RABBITMQ_CONFIG_FILE: "/etc/rabbitmq/rabbitmq.conf"
      RABBITMQ_ADVANCED_CONFIG_FILE: "/etc/rabbitmq/advanced.config"
    volumes:
      - ${BASE}/data:/var/lib/rabbitmq
      - ${BASE}/logs:/var/log/rabbitmq
      - ${BASE}/config/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
      - ${BASE}/config/advanced.config:/etc/rabbitmq/advanced.config:ro
    ports:
      - "${IP_PRIVEE}:5672:5672"
      - "${IP_PRIVEE}:15672:15672"
      - "${IP_PRIVEE}:4369:4369"
      - "${IP_PRIVEE}:25672:25672"
    extra_hosts:
      - "queue-01:$QUEUE01_IP"
      - "queue-02:$QUEUE02_IP"
      - "queue-03:$QUEUE03_IP"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping", "-q"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

# Export des IPs pour extra_hosts
export QUEUE01_IP="10.0.0.126"
export QUEUE02_IP="10.0.0.127"
export QUEUE03_IP="10.0.0.128"

# Remplacer les IPs dans docker-compose
sed -i "s/\$QUEUE01_IP/$QUEUE01_IP/g" "$BASE/docker-compose.yml"
sed -i "s/\$QUEUE02_IP/$QUEUE02_IP/g" "$BASE/docker-compose.yml"
sed -i "s/\$QUEUE03_IP/$QUEUE03_IP/g" "$BASE/docker-compose.yml"

# Démarrer le conteneur
docker compose down 2>/dev/null
docker compose up -d

echo "    ✓ Container démarré"
DEPLOY

    # Vérifier le démarrage
    sleep 5
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP_PRIV" "docker ps | grep -q rabbitmq"; then
        echo "    ✓ $host: RabbitMQ actif"
    else
        echo "    ✗ $host: Problème de démarrage"
    fi
done

echo ""
echo "  Attente de stabilisation (20s)..."
sleep 20

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: Formation du cluster
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Formation du cluster                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Les nœuds 2 et 3 rejoignent le nœud 1
for host in queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Ajout de $host au cluster..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash <<'JOIN'
docker exec rabbitmq rabbitmqctl stop_app 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl reset 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl join_cluster rabbit@queue-01 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl start_app 2>/dev/null

if docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -q "queue-01"; then
    echo "    ✓ Rejoint le cluster"
else
    echo "    ✗ Échec de jonction"
fi
JOIN
done

echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: Configuration des politiques HA
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Configuration des politiques HA                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Configuration des quorum queues par défaut..."

ssh -o StrictHostKeyChecking=no root@"$QUEUE01_IP" bash <<'POLICIES'
# Charger les credentials
source /opt/keybuzz-installer/credentials/rabbitmq.env

# Politique pour les quorum queues
docker exec rabbitmq rabbitmqctl set_policy quorum-queues \
    "^quorum\." \
    '{"queue-type":"quorum", "quorum-initial-group-size": 3}' \
    --priority 1 \
    --apply-to queues

# Politique HA pour toutes les autres queues
docker exec rabbitmq rabbitmqctl set_policy ha-all \
    "^(?!quorum\.)" \
    '{"ha-mode":"all", "ha-sync-mode":"automatic"}' \
    --priority 0 \
    --apply-to queues

echo "    ✓ Politiques HA configurées"
POLICIES

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: Vérification du cluster
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Vérification du cluster                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  État du cluster:"
ssh -o StrictHostKeyChecking=no root@"$QUEUE01_IP" \
    "docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null" | \
    grep -E "(Basics|Disk Nodes|Running Nodes)" | head -10

echo ""
echo "  Test de connectivité:"
for host in queue-01 queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host: "
    
    if timeout 3 nc -zv "$IP_PRIV" 5672 &>/dev/null; then
        echo -e "$OK AMQP (5672)"
    else
        echo -e "$KO"
    fi
done

# Marquer comme OK
for host in queue-01 queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "echo 'OK' > /opt/keybuzz/rabbitmq/status/STATE" 2>/dev/null
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK CLUSTER RABBITMQ DÉPLOYÉ"
echo ""
echo "Endpoints:"
echo "  • AMQP: queue-01:5672, queue-02:5672, queue-03:5672"
echo "  • Management: http://queue-01:15672"
echo ""
echo "Credentials:"
echo "  • User: $RABBITMQ_ADMIN_USER"
echo "  • Password: [dans $CREDS_DIR/rabbitmq.env]"
echo ""
echo "Prochaine étape: ./rabbitmq_lb_service.sh pour le Load Balancer"
echo "═══════════════════════════════════════════════════════════════════"

echo ""
echo "Logs (50 dernières lignes):"
echo "═══════════════════════════════════════════════════════════════════"
tail -n 50 "$MAIN_LOG" | grep -E "(✓|✗|OK|KO|cluster|joined)"
