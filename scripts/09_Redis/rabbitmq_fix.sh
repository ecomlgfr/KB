#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          RABBITMQ_FIX - Correction du déploiement RabbitMQ         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

echo ""
echo "Correction du cluster RabbitMQ"
echo ""

# Charger les credentials
source "$CREDS_DIR/rabbitmq.env"

# Obtenir les IPs CORRECTEMENT
QUEUE01_IP="10.0.0.126"
QUEUE02_IP="10.0.0.127"
QUEUE03_IP="10.0.0.128"

echo "IPs des nœuds:"
echo "  queue-01: $QUEUE01_IP"
echo "  queue-02: $QUEUE02_IP"
echo "  queue-03: $QUEUE03_IP"
echo ""

# Fonction pour déployer sur un nœud
deploy_rabbitmq() {
    local HOST=$1
    local IP_PRIV=$2
    
    echo "  Configuration de $HOST ($IP_PRIV)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<EOF
# Charger les credentials
source /opt/keybuzz-installer/credentials/rabbitmq.env

BASE="/opt/keybuzz/rabbitmq"
cd "\$BASE"

# Nettoyer complètement
docker stop rabbitmq 2>/dev/null
docker rm rabbitmq 2>/dev/null
docker network rm rabbitmq_default 2>/dev/null

# Docker-compose.yml SIMPLIFIÉ sans extra_hosts problématique
cat > "\$BASE/docker-compose.yml" <<'COMPOSE'
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.13-management-alpine
    container_name: rabbitmq
    hostname: $HOST
    restart: unless-stopped
    network_mode: host
    environment:
      RABBITMQ_NODENAME: rabbit@$HOST
      RABBITMQ_ERLANG_COOKIE: \${RABBITMQ_ERLANG_COOKIE}
      RABBITMQ_DEFAULT_USER: \${RABBITMQ_ADMIN_USER}
      RABBITMQ_DEFAULT_PASS: \${RABBITMQ_ADMIN_PASS}
    volumes:
      - \${BASE}/data:/var/lib/rabbitmq
      - \${BASE}/logs:/var/log/rabbitmq
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
COMPOSE

# Ajouter les hosts dans /etc/hosts si pas présents
grep -q "queue-01" /etc/hosts || echo "$QUEUE01_IP queue-01" >> /etc/hosts
grep -q "queue-02" /etc/hosts || echo "$QUEUE02_IP queue-02" >> /etc/hosts
grep -q "queue-03" /etc/hosts || echo "$QUEUE03_IP queue-03" >> /etc/hosts

# Démarrer
docker compose up -d

sleep 5

# Vérifier
if docker ps | grep -q rabbitmq; then
    echo "    ✓ RabbitMQ démarré"
else
    echo "    ✗ Échec démarrage"
fi
EOF
}

echo "═══ Déploiement des nœuds ═══"
echo ""

# Déployer sur chaque nœud
deploy_rabbitmq "queue-01" "$QUEUE01_IP"
deploy_rabbitmq "queue-02" "$QUEUE02_IP"
deploy_rabbitmq "queue-03" "$QUEUE03_IP"

echo ""
echo "Attente de stabilisation (15s)..."
sleep 15

echo ""
echo "═══ Formation du cluster ═══"
echo ""

# Former le cluster
echo "  Configuration du nœud principal (queue-01)..."
ssh -o StrictHostKeyChecking=no root@"$QUEUE01_IP" <<'EOF'
docker exec rabbitmq rabbitmqctl cluster_status
EOF

# Joindre queue-02
echo "  Ajout de queue-02..."
ssh -o StrictHostKeyChecking=no root@"$QUEUE02_IP" <<EOF
docker exec rabbitmq rabbitmqctl stop_app
docker exec rabbitmq rabbitmqctl reset
docker exec rabbitmq rabbitmqctl join_cluster rabbit@queue-01
docker exec rabbitmq rabbitmqctl start_app
EOF

# Joindre queue-03
echo "  Ajout de queue-03..."
ssh -o StrictHostKeyChecking=no root@"$QUEUE03_IP" <<EOF
docker exec rabbitmq rabbitmqctl stop_app
docker exec rabbitmq rabbitmqctl reset
docker exec rabbitmq rabbitmqctl join_cluster rabbit@queue-01
docker exec rabbitmq rabbitmqctl start_app
EOF

sleep 10

echo ""
echo "═══ Configuration HA ═══"
echo ""

ssh -o StrictHostKeyChecking=no root@"$QUEUE01_IP" <<EOF
source /opt/keybuzz-installer/credentials/rabbitmq.env

# Politique HA
docker exec rabbitmq rabbitmqctl set_policy ha-all ".*" '{"ha-mode":"all","ha-sync-mode":"automatic"}' --priority 0 --apply-to queues

# Vérifier le cluster
docker exec rabbitmq rabbitmqctl cluster_status
EOF

echo ""
echo "═══ Vérification finale ═══"
echo ""

# Test des ports
for host in queue-01 queue-02 queue-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  $host AMQP (5672): "
    timeout 2 nc -zv "$IP" 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
done

echo ""
echo -n "  Management UI (http://$QUEUE01_IP:15672): "
curl -s -o /dev/null -w "%{http_code}" -u "$RABBITMQ_ADMIN_USER:$RABBITMQ_ADMIN_PASS" \
    "http://$QUEUE01_IP:15672/api/overview" | grep -q "200" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"

if timeout 2 nc -zv "$QUEUE01_IP" 5672 &>/dev/null; then
    echo -e "$OK RABBITMQ CLUSTER OPÉRATIONNEL"
    echo ""
    echo "Endpoints directs:"
    echo "  • AMQP: $QUEUE01_IP:5672, $QUEUE02_IP:5672, $QUEUE03_IP:5672"
    echo "  • Management: http://$QUEUE01_IP:15672"
    echo "  • User: $RABBITMQ_ADMIN_USER"
    echo "  • Password: [dans rabbitmq.env]"
    echo ""
    echo "Relancez ./rabbitmq_lb_service.sh après cette correction"
else
    echo -e "$KO Problème persistant"
fi
echo "═══════════════════════════════════════════════════════════════════"
