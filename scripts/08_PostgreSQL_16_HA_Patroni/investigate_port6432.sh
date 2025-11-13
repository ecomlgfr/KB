#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         INVESTIGATION PORT 6432                                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "Investigation approfondie sur haproxy-01 ($HAPROXY1_IP)"
echo ""

ssh -o StrictHostKeyChecking=no root@"$HAPROXY1_IP" bash <<'INVEST'
set -e

echo "═══════════════════════════════════════════════════════════════════"
echo "1. QUI ÉCOUTE SUR LE PORT 6432 ?"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ss -tlnp | grep ":6432" || echo "Port 6432 libre"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "2. PROCESSUS HAPROXY"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ps aux | grep haproxy | grep -v grep

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "3. CONTENEUR HAPROXY - FICHIERS DE CONFIG"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Fichier haproxy.cfg actuel:"
docker exec haproxy cat /usr/local/etc/haproxy/haproxy.cfg | grep -n "6432\|listen\|bind" || echo "  (Aucune mention de 6432)"

echo ""
echo "→ Tous les fichiers .cfg dans le conteneur:"
docker exec haproxy find /usr/local/etc/haproxy -name "*.cfg" -exec echo "  {}" \; -exec grep -l "6432" {} \; 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "4. FICHIERS DE CONFIG SUR L'HÔTE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Fichiers dans /opt/keybuzz/haproxy/config:"
ls -la /opt/keybuzz/haproxy/config/ 2>/dev/null || echo "  (Répertoire non trouvé)"

echo ""
echo "→ Contenu des fichiers .cfg:"
find /opt/keybuzz/haproxy/config -name "*.cfg" -exec echo "=== {} ===" \; -exec cat {} \; 2>/dev/null | grep -B2 -A2 "6432\|listen\|bind" || echo "  (Aucune mention de 6432)"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "5. DOCKER COMPOSE / DOCKER RUN"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Ports mappés par Docker:"
docker ps --filter name=haproxy --format "{{.Ports}}"

echo ""
echo "→ Commande de démarrage du conteneur:"
docker inspect haproxy --format '{{.Config.Cmd}}' 2>/dev/null

echo ""
echo "→ Arguments de démarrage:"
docker inspect haproxy --format '{{.Args}}' 2>/dev/null

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "6. LSOF SUR LE PROCESSUS HAPROXY"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

PID=$(ss -tlnp | grep ":6432" | grep -o "pid=[0-9]*" | cut -d= -f2 | head -1)
if [ -n "$PID" ]; then
    echo "→ PID utilisant le port 6432: $PID"
    echo ""
    echo "→ Informations sur le processus:"
    ps -p $PID -o pid,ppid,cmd
    echo ""
    echo "→ Fichiers ouverts par ce processus (ports):"
    lsof -p $PID 2>/dev/null | grep "TCP\|LISTEN" || true
else
    echo "  (Aucun processus trouvé sur le port 6432)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

INVEST

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ INVESTIGATION TERMINÉE"
echo "═══════════════════════════════════════════════════════════════════"
