#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       FIX_HAPROXY_RABBITMQ - Correction HAProxy pour RabbitMQ      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

echo ""
echo "Diagnostic et correction des HAProxy RabbitMQ"
echo ""

# Vérifier les logs sur haproxy-01
echo "═══ Diagnostic sur haproxy-01 ═══"
echo ""
ssh -o StrictHostKeyChecking=no root@10.0.0.11 bash <<'DIAG'
echo "  Logs du container haproxy-rabbitmq:"
docker logs --tail 20 haproxy-rabbitmq 2>&1 | head -15

echo ""
echo "  Configuration actuelle:"
cat /opt/keybuzz/rabbitmq-lb/config/haproxy-rabbitmq.cfg | grep -A3 "bind"

echo ""
echo "  Suppression du container défaillant..."
docker stop haproxy-rabbitmq 2>/dev/null
docker rm haproxy-rabbitmq 2>/dev/null
DIAG

# Même chose sur haproxy-02
echo ""
echo "═══ Diagnostic sur haproxy-02 ═══"
echo ""
ssh -o StrictHostKeyChecking=no root@10.0.0.12 bash <<'DIAG2'
echo "  Logs du container haproxy-rabbitmq:"
docker logs --tail 20 haproxy-rabbitmq 2>&1 | head -15

echo ""
echo "  Suppression du container défaillant..."
docker stop haproxy-rabbitmq 2>/dev/null
docker rm haproxy-rabbitmq 2>/dev/null
DIAG2

echo ""
echo "═══ Reconfiguration des HAProxy RabbitMQ ═══"
echo ""

# Reconfigurer avec une config qui fonctionne
for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Configuration de $host..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'RECONFIG'
BASE="/opt/keybuzz/rabbitmq-lb"
mkdir -p "$BASE/config"

# Configuration HAProxy CORRIGÉE
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

# RabbitMQ AMQP
listen rabbitmq_amqp
    bind *:5672
    mode tcp
    balance leastconn
    option tcp-check
    server queue-01 10.0.0.126:5672 check inter 5s fall 3 rise 2
    server queue-02 10.0.0.127:5672 check inter 5s fall 3 rise 2
    server queue-03 10.0.0.128:5672 check inter 5s fall 3 rise 2

# RabbitMQ Management
listen rabbitmq_management
    bind *:15672
    mode tcp
    balance roundrobin
    option tcp-check
    server queue-01 10.0.0.126:15672 check inter 5s fall 3 rise 2
    server queue-02 10.0.0.127:15672 check inter 5s fall 3 rise 2
    server queue-03 10.0.0.128:15672 check inter 5s fall 3 rise 2

# Stats
listen stats
    bind *:8405
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF

# Démarrer avec la bonne config
docker run -d \
    --name haproxy-rabbitmq \
    --restart unless-stopped \
    --network host \
    -v ${BASE}/config/haproxy-rabbitmq.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
    haproxy:2.9-alpine \
    haproxy -f /usr/local/etc/haproxy/haproxy.cfg

sleep 3

# Vérifier
if docker ps | grep -q haproxy-rabbitmq; then
    echo "    ✓ HAProxy RabbitMQ démarré"
    
    # Vérifier les ports
    echo "    Ports en écoute:"
    netstat -tlpn | grep -E ":(5672|15672|8405)" | grep haproxy
else
    echo "    ✗ Échec démarrage"
    docker logs --tail 10 haproxy-rabbitmq
fi
RECONFIG
done

echo ""
echo "═══ Test de connectivité ═══"
echo ""

sleep 5

for host in haproxy-01 haproxy-02; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  $host ($IP):"
    
    echo -n "    AMQP (5672): "
    timeout 2 nc -zv "$IP" 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    Management (15672): "
    timeout 2 nc -zv "$IP" 15672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    Stats (8405): "
    curl -s -o /dev/null -w "%{http_code}" "http://$IP:8405/stats" 2>/dev/null | grep -q "200" && echo -e "$OK" || echo -e "$KO"
done

echo ""
echo "  Test via VIP 10.0.0.10:"
echo -n "    AMQP (5672): "
timeout 2 nc -zv 10.0.0.10 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "    Management (15672): "
timeout 2 nc -zv 10.0.0.10 15672 &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Configuration pour le Load Balancer Hetzner :"
echo ""
echo "Service AMQP (5672):"
echo "  • Type: TCP"
echo "  • Port source: 5672"
echo "  • Port destination: 5672"
echo ""
echo "Service Management (15672):"
echo "  • Type: TCP"
echo "  • Port source: 15672"
echo "  • Port destination: 15672"
echo ""
echo "Les deux services devraient maintenant passer en vert dans Hetzner."
echo "═══════════════════════════════════════════════════════════════════"
