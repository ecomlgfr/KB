#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         DIAGNOSTIC HAPROXY STATS                                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "▓▓▓ $NAME ($IP) ▓▓▓"
    echo ""
    
    # Test 1: Conteneur HAProxy
    echo -n "  1. Conteneur HAProxy: "
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" "docker ps | grep -q haproxy" 2>/dev/null; then
        echo -e "$OK Running"
    else
        echo -e "$KO Stopped"
        echo ""
        continue
    fi
    
    # Test 2: Port 8404 en écoute
    echo -n "  2. Port 8404 (Stats): "
    PORT_CHECK=$(ssh -o StrictHostKeyChecking=no root@"$IP" "ss -tln | grep ':8404 '" 2>/dev/null)
    if [ -n "$PORT_CHECK" ]; then
        echo -e "$OK En écoute"
        echo "     → $PORT_CHECK" | head -1
    else
        echo -e "$KO Pas en écoute"
    fi
    
    # Test 3: Curl Stats
    echo -n "  3. Curl Stats page: "
    CURL_STATS=$(curl -s -m 3 "http://${IP}:8404/" 2>&1)
    if echo "$CURL_STATS" | grep -q "Statistics"; then
        echo -e "$OK Page accessible"
    else
        echo -e "$KO Erreur"
        echo "     → $(echo "$CURL_STATS" | head -1)"
    fi
    
    # Test 4: Vérifier la config HAProxy
    echo "  4. Config HAProxy (stats section):"
    ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec haproxy cat /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null | grep -A10 'listen stats'" 2>/dev/null || echo "     ✗ Impossible de lire la config"
    
    # Test 5: Logs HAProxy
    echo "  5. Logs récents:"
    ssh -o StrictHostKeyChecking=no root@"$IP" "docker logs haproxy 2>&1 | grep -i 'stats\|8404\|bind' | tail -5" 2>/dev/null || echo "     Aucun log trouvé"
    
    # Test 6: Firewall UFW
    echo -n "  6. UFW port 8404: "
    UFW_CHECK=$(ssh -o StrictHostKeyChecking=no root@"$IP" "ufw status | grep 8404" 2>/dev/null)
    if [ -n "$UFW_CHECK" ]; then
        echo -e "$OK Autorisé"
        echo "     → $UFW_CHECK"
    else
        echo -e "$WARN Pas de règle UFW (peut bloquer)"
    fi
    
    # Test 7: Netstat détaillé
    echo "  7. Netstat détaillé port 8404:"
    ssh -o StrictHostKeyChecking=no root@"$IP" "ss -tlnp | grep ':8404'" 2>/dev/null | sed 's/^/     /' || echo "     Port non trouvé"
    
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🔍 DIAGNOSTIC COMPLET TERMINÉ"
echo ""
echo "Si HAProxy Stats ne répond pas, vérifier:"
echo "  1. Config HAProxy: section 'listen stats' présente"
echo "  2. Bind address dans stats: doit être sur IP privée ou 0.0.0.0"
echo "  3. Firewall UFW: autoriser port 8404"
echo "  4. Redémarrer HAProxy: docker restart haproxy"
echo ""
