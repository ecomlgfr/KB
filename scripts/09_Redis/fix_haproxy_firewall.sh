#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX_HAPROXY_FIREWALL - Correction firewall HAProxy         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

echo ""
echo "Vérification et correction du firewall sur HAProxy"
echo ""

# Pour chaque HAProxy
for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "═══ $host ($IP_PRIV) ═══"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'FW_FIX'
# Vérifier l'état UFW
echo "  État actuel UFW:"
ufw status numbered | head -20

echo ""
echo "  Ajout des règles pour RabbitMQ et Redis:"

# Redis (pour le LB Hetzner)
ufw allow 6379/tcp comment 'Redis LB' 2>/dev/null

# RabbitMQ AMQP (pour le LB Hetzner)
ufw allow 5672/tcp comment 'RabbitMQ AMQP' 2>/dev/null

# RabbitMQ Management (pour le LB Hetzner)
ufw allow 15672/tcp comment 'RabbitMQ Management' 2>/dev/null

# PostgreSQL (déjà fait normalement)
ufw allow 5432/tcp comment 'PostgreSQL Master' 2>/dev/null
ufw allow 5433/tcp comment 'PostgreSQL Replica' 2>/dev/null
ufw allow 6432/tcp comment 'PgBouncer' 2>/dev/null

# HAProxy stats (utile pour debug)
ufw allow 8404/tcp comment 'HAProxy Stats' 2>/dev/null

# Appliquer
ufw --force reload

echo ""
echo "  Ports écoutés actuellement:"
netstat -tlpn | grep -E ":(5672|15672|6379|5432|5433|6432|8404)" | sort

echo ""
echo "  Test des containers HAProxy:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "haproxy|NAME"

echo ""
FW_FIX
done

echo "═══ Test de connectivité depuis install-01 ═══"
echo ""

# Test direct sur les HAProxy
for host in haproxy-01 haproxy-02; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  $host ($IP):"
    
    echo -n "    Redis (6379): "
    timeout 2 nc -zv "$IP" 6379 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    RabbitMQ AMQP (5672): "
    timeout 2 nc -zv "$IP" 5672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    RabbitMQ Mgmt (15672): "
    timeout 2 nc -zv "$IP" 15672 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    PostgreSQL (5432): "
    timeout 2 nc -zv "$IP" 5432 &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    echo -n "    PgBouncer (6432): "
    timeout 2 nc -zv "$IP" 6432 &>/dev/null && echo -e "$OK" || echo -e "$KO"
done

echo ""
echo "═══ Configuration Load Balancer Hetzner ═══"
echo ""
echo "Pour le port 15672 (RabbitMQ Management UI) dans le LB Hetzner:"
echo ""
echo "  Type: HTTP (pas TCP)"
echo "  Port source: 15672"
echo "  Port destination: 15672"
echo "  Path pour health check: /api/overview"
echo "  Status code: 200"
echo "  Protocole: HTTP"
echo ""
echo "OU plus simple:"
echo ""
echo "  Type: TCP"
echo "  Port source: 15672"
echo "  Port destination: 15672"
echo "  Health check: TCP (connexion simple)"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions effectuées:"
echo "  ✓ Ouverture ports 6379, 5672, 15672 sur HAProxy"
echo "  ✓ Reload UFW"
echo ""
echo "Prochaines étapes:"
echo "  1. Vérifier dans Hetzner Cloud Console que les services passent en vert"
echo "  2. Si toujours rouge, vérifier les logs HAProxy:"
echo "     docker logs haproxy-redis"
echo "     docker logs haproxy-rabbitmq"
echo "═══════════════════════════════════════════════════════════════════"
