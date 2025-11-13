#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         DIAGNOSTIC APPROFONDI API PATRONI                          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CRED_FILE="/opt/keybuzz-installer/credentials/postgres.env"

# Charger credentials
if [ -f "$CRED_FILE" ]; then
    source "$CRED_FILE"
fi

# IPs
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2_IP=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "▓▓▓ $NAME ($IP) ▓▓▓"
    echo ""
    
    # Test 1: Conteneur Patroni
    echo -n "  1. Conteneur Patroni: "
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" "docker ps | grep -q patroni" 2>/dev/null; then
        echo -e "$OK Running"
    else
        echo -e "$KO Stopped"
        echo ""
        continue
    fi
    
    # Test 2: Port 8008 en écoute
    echo -n "  2. Port 8008 (API): "
    PORT_CHECK=$(ssh -o StrictHostKeyChecking=no root@"$IP" "ss -tln | grep ':8008 '" 2>/dev/null)
    if [ -n "$PORT_CHECK" ]; then
        echo -e "$OK En écoute"
        echo "     → $PORT_CHECK" | head -1
    else
        echo -e "$KO Pas en écoute"
    fi
    
    # Test 3: Curl direct (sans auth)
    echo -n "  3. Curl API (sans auth): "
    CURL_NOAUTH=$(curl -s -m 3 "http://${IP}:8008/" 2>&1)
    if echo "$CURL_NOAUTH" | grep -q '"state"'; then
        echo -e "$OK Répond"
    elif echo "$CURL_NOAUTH" | grep -qi "401\|unauthorized"; then
        echo -e "$WARN Authentification requise"
    else
        echo -e "$KO Timeout ou erreur"
        echo "     → $(echo "$CURL_NOAUTH" | head -1)"
    fi
    
    # Test 4: Lire le patroni.yml
    echo "  4. Config Patroni (restapi):"
    ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec patroni cat /etc/patroni/patroni.yml 2>/dev/null | grep -A5 'restapi:'" 2>/dev/null || echo "     ✗ Impossible de lire la config"
    
    # Test 5: Logs Patroni (dernières lignes)
    echo "  5. Logs récents:"
    ssh -o StrictHostKeyChecking=no root@"$IP" "docker logs patroni 2>&1 | grep -i 'restapi\|listen\|8008' | tail -5" 2>/dev/null || echo "     Aucun log trouvé"
    
    # Test 6: Tester avec auth depuis postgres.env
    echo -n "  6. Curl API (avec auth): "
    
    if [ -n "${PATRONI_API_PASSWORD:-}" ]; then
        CURL_AUTH=$(curl -s -m 3 -u "patroni:${PATRONI_API_PASSWORD}" "http://${IP}:8008/" 2>&1)
        if echo "$CURL_AUTH" | grep -q '"state"'; then
            echo -e "$OK Répond avec auth"
            echo "$CURL_AUTH" | python3 -m json.tool 2>/dev/null | head -10 | sed 's/^/     /'
        else
            echo -e "$KO Échec même avec auth"
        fi
    else
        echo -e "$WARN Variable PATRONI_API_PASSWORD non définie dans postgres.env"
    fi
    
    # Test 7: PostgreSQL status
    echo -n "  7. PostgreSQL status: "
    if ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
        echo -e "$OK Accepting connections"
    else
        echo -e "$KO Non prêt"
    fi
    
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🔍 DIAGNOSTIC COMPLET TERMINÉ"
echo ""
echo "Si l'API Patroni ne répond pas, vérifier:"
echo "  1. Authentification dans patroni.yml (restapi.authentication)"
echo "  2. Bind address: doit être sur IP privée, pas 127.0.0.1"
echo "  3. Firewall UFW: autoriser port 8008"
echo ""
