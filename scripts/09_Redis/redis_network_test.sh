#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║             REDIS_NETWORK_TEST - Test réseau direct                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
REDIS_PASSWORD="Lm1wszsUh07xuU9pttHw9YZOB"

echo ""
echo "1. Test direct sur redis-01..."
echo ""

IP_REDIS01=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")

ssh -o StrictHostKeyChecking=no root@"$IP_REDIS01" bash -s "$REDIS_PASSWORD" <<'TEST'
REDIS_PASSWORD="$1"

echo "  État des containers:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "NAME|redis|sentinel"

echo ""
echo "  Ports en écoute:"
ss -tlnp | grep -E ":6379|:26379"

echo ""
echo "  Test local dans le container:"
echo -n "    Sans auth: "
docker exec redis redis-cli PING 2>&1

echo -n "    Avec auth: "
docker exec redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning PING 2>&1

echo ""
echo "  Test local depuis l'hôte:"
echo -n "    Port 6379: "
nc -zv localhost 6379 2>&1 | grep -q succeeded && echo "✓ Ouvert" || echo "✗ Fermé"

echo -n "    Connexion locale: "
redis-cli -h localhost -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>&1 || echo "KO"

echo ""
echo "  Processus Redis dans le container:"
docker exec redis ps aux | grep redis-server

echo ""
echo "  Derniers logs Redis:"
docker logs redis --tail 15 2>&1
TEST

echo ""
echo "2. Test depuis install-01..."
echo ""

# Test de connectivité réseau de base
echo -n "  Ping redis-01: "
ping -c 1 -W 1 "$IP_REDIS01" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Port 6379 TCP: "
timeout 2 nc -zv "$IP_REDIS01" 6379 2>&1 | grep -q succeeded && echo -e "$OK" || echo -e "$KO"

echo -n "  Port 26379 TCP: "
timeout 2 nc -zv "$IP_REDIS01" 26379 2>&1 | grep -q succeeded && echo -e "$OK" || echo -e "$KO"

# Test telnet manuel
echo ""
echo "3. Test telnet direct..."
echo -n "  Tentative AUTH: "
(echo "AUTH $REDIS_PASSWORD"; echo "PING"; sleep 1) | nc "$IP_REDIS01" 6379 2>/dev/null | grep -q "+PONG" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Pour debug manuel:"
echo "  ssh root@$IP_REDIS01"
echo "  docker exec -it redis sh"
echo "  redis-cli -a $REDIS_PASSWORD"
echo "═══════════════════════════════════════════════════════════════════"
