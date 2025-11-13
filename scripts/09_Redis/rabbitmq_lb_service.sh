#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      RABBITMQ_LB_SERVICE - Configuration Load Balancer RabbitMQ    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/rabbitmq_lb_service_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Configuration du Load Balancer pour RabbitMQ"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Vérifier que les credentials existent
if [ ! -f "$CREDS_DIR/rabbitmq.env" ]; then
    echo -e "$KO Credentials RabbitMQ non trouvés"
    exit 1
fi
source "$CREDS_DIR/rabbitmq.env"

# Obtenir les IPs des HAProxy
HAPROXY01_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY02_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

# Obtenir les IPs des nœuds RabbitMQ
QUEUE01_IP=$(awk -F'\t' '$2=="queue-01" {print $3}' "$SERVERS_TSV")
QUEUE02_IP=$(awk -F'\t' '$2=="queue-02" {print $3}' "$SERVERS_TSV")
QUEUE03_IP=$(awk -F'\t' '$2=="queue-03" {print $3}' "$SERVERS_TSV")

echo "Configuration:"
echo "  Load Balancers: haproxy-01 ($HAPROXY01_IP), haproxy-02 ($HAPROXY02_IP)"
echo "  Backend RabbitMQ: queue-01 ($QUEUE01_IP), queue-02 ($QUEUE02_IP), queue-03 ($QUEUE03_IP)"
echo "  VIP: 10.0.0.10"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Configuration HAProxy pour RabbitMQ
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Configuration des HAProxy pour RabbitMQ                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Configuration de $host..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash -s \
        "$QUEUE01_IP" "$QUEUE02_IP" "$QUEUE03_IP" "$RABBITMQ_ADMIN_USER" "$RABBITMQ_ADMIN_PASS" <<'HAPROXY_CONFIG'
QUEUE01_IP="$1"
QUEUE02_IP="$2"
QUEUE03_IP="$3"
ADMIN_USER="$4"
ADMIN_PASS="$5"

BASE="/opt/keybuzz/rabbitmq-lb"

# Créer la structure
mkdir -p "$BASE"/{config,logs,status}

# Arrêter l'ancien container si présent
docker stop haproxy-rabbitmq 2>/dev/null
docker rm haproxy-rabbitmq 2>/dev/null

# Configuration HAProxy pour RabbitMQ
cat > "$BASE/config/haproxy-rabbitmq.cfg" <<EOF
global
    maxconn 10000
    log stdout local0
    stats socket /var/run/haproxy.sock mode 660

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global
    option tcplog

# Stats page
listen stats
    bind 0.0.0.0:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats show-legends
    stats auth admin:admin

# RabbitMQ AMQP (5672)
listen rabbitmq_amqp
    bind 0.0.0.0:5672
    mode tcp
    balance leastconn
    option tcp-check
    tcp-check connect
    server queue-01 ${QUEUE01_IP}:5672 check inter 5s fall 3 rise 2
    server queue-02 ${QUEUE02_IP}:5672 check inter 5s fall 3 rise 2
    server queue-03 ${QUEUE03_IP}:5672 check inter 5s fall 3 rise 2

# RabbitMQ Management UI (15672)
listen rabbitmq_management
    bind 0.0.0.0:15672
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check connect port 15672
    server queue-01 ${QUEUE01_IP}:15672 check inter 5s fall 3 rise 2
    server queue-02 ${QUEUE02_IP}:15672 check inter 5s fall 3 rise 2
    server queue-03 ${QUEUE03_IP}:15672 check inter 5s fall 3 rise 2

# RabbitMQ Clustering ports (for inter-node communication)
listen rabbitmq_epmd
    bind 0.0.0.0:4369
    mode tcp
    balance source
    server queue-01 ${QUEUE01_IP}:4369 check inter 5s fall 3 rise 2
    server queue-02 ${QUEUE02_IP}:4369 check inter 5s fall 3 rise 2
    server queue-03 ${QUEUE03_IP}:4369 check inter 5s fall 3 rise 2

listen rabbitmq_clustering
    bind 0.0.0.0:25672
    mode tcp
    balance source
    server queue-01 ${QUEUE01_IP}:25672 check inter 5s fall 3 rise 2
    server queue-02 ${QUEUE02_IP}:25672 check inter 5s fall 3 rise 2
    server queue-03 ${QUEUE03_IP}:25672 check inter 5s fall 3 rise 2
EOF

# Démarrer HAProxy
docker run -d \
    --name haproxy-rabbitmq \
    --restart unless-stopped \
    --network host \
    -v ${BASE}/config/haproxy-rabbitmq.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
    haproxy:2.9-alpine

sleep 3

if docker ps | grep -q haproxy-rabbitmq; then
    echo "    ✓ HAProxy RabbitMQ démarré"
else
    echo "    ✗ Échec démarrage HAProxy"
fi
HAPROXY_CONFIG
done

echo ""
sleep 5

# ═══════════════════════════════════════════════════════════════════
# Test de connectivité
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Test de connectivité                                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Test des HAProxy locaux:"
for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host AMQP (5672): "
    timeout 3 nc -zv "$IP_PRIV" 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    $host Management (15672): "
    timeout 3 nc -zv "$IP_PRIV" 15672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
done

echo ""
echo "  Test via Load Balancer VIP (10.0.0.10):"
echo -n "    AMQP (5672): "
timeout 3 nc -zv 10.0.0.10 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "    Management (15672): "
timeout 3 nc -zv 10.0.0.10 15672 &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo ""

# Test avec authentification
echo "  Test d'authentification Management UI:"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "$RABBITMQ_ADMIN_USER:$RABBITMQ_ADMIN_PASS" \
    http://10.0.0.10:15672/api/overview 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "    $OK Authentification réussie"
else
    echo -e "    $KO Code HTTP: $HTTP_CODE"
fi

# ═══════════════════════════════════════════════════════════════════
# Résumé final
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Créer le résumé
cat > "$CREDS_DIR/rabbitmq-summary.txt" <<EOF
RABBITMQ HA - CONFIGURATION COMPLÈTE
═══════════════════════════════════════════════════════════════════

Date: $(date)

ARCHITECTURE:
  • 3 nœuds RabbitMQ en cluster
  • Mode: Quorum queues + HA policies
  • 2 HAProxy pour load balancing
  • VIP sur Load Balancer Hetzner

ENDPOINTS:
  AMQP: 10.0.0.10:5672
  Management UI: http://10.0.0.10:15672
  
CREDENTIALS:
  Fichier: $CREDS_DIR/rabbitmq.env
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
  • Tolérance de panne: 2/3 nœuds peuvent tomber
  • Quorum queues: réplication automatique
  • Auto-heal en cas de partition réseau
EOF

if timeout 3 nc -zv 10.0.0.10 5672 &>/dev/null; then
    echo -e "$OK RABBITMQ HA LOAD BALANCER CONFIGURÉ"
    echo ""
    echo "Endpoints disponibles:"
    echo "  • AMQP: 10.0.0.10:5672"
    echo "  • Management: http://10.0.0.10:15672"
    echo "  • User: $RABBITMQ_ADMIN_USER"
    echo ""
    echo "Résumé complet: $CREDS_DIR/rabbitmq-summary.txt"
else
    echo -e "$KO Configuration incomplète"
    echo "Vérifier les logs: $MAIN_LOG"
fi
echo "═══════════════════════════════════════════════════════════════════"

echo ""
echo "Logs (50 dernières lignes):"
echo "═══════════════════════════════════════════════════════════════════"
tail -n 50 "$MAIN_LOG" | grep -E "(✓|✗|OK|KO|démarré|configuré)"
