#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX PATRONI API & HAPROXY STATS                            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CRED_FILE="/opt/keybuzz-installer/credentials/postgres.env"

# Charger les credentials
if [ -f "$CRED_FILE" ]; then
    source "$CRED_FILE"
else
    echo -e "$KO Fichier credentials manquant: $CRED_FILE"
    exit 1
fi

DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2_IP=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Ce script va corriger:"
echo "  1. Autoriser le port 8008 (API Patroni) dans UFW sur les nœuds DB"
echo "  2. Autoriser le port 8404 (HAProxy Stats) dans UFW sur les proxies"
echo ""
read -p "Continuer ? (yes/NO): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Annulé"
    exit 0
fi

echo ""
echo "▓▓▓ CORRECTION API PATRONI (port 8008) ▓▓▓"
echo ""

for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "→ $NAME ($IP)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'FIXPATRONI'
    set -e
    
    # Ouvrir le port 8008 dans UFW
    echo "  → Autoriser port 8008 dans UFW..."
    ufw allow from any to any port 8008 proto tcp >/dev/null 2>&1 || true
    ufw status | grep 8008 || echo "    (UFW désactivé ou règle non affichée)"
    
    # Vérifier que le port est bien en écoute
    if ss -tln | grep -q ':8008 '; then
        echo "  ✓ Port 8008 en écoute"
    else
        echo "  ⚠ Port 8008 non en écoute (Patroni config?)"
    fi
FIXPATRONI
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Correction appliquée"
    else
        echo -e "  $KO Échec"
    fi
    echo ""
done

echo ""
echo "▓▓▓ CORRECTION HAPROXY STATS (port 8404) ▓▓▓"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "→ $NAME ($IP)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'FIXHAPROXY'
    set -e
    
    # Ouvrir le port 8404 dans UFW
    echo "  → Autoriser port 8404 dans UFW..."
    ufw allow from any to any port 8404 proto tcp >/dev/null 2>&1 || true
    ufw status | grep 8404 || echo "    (UFW désactivé ou règle non affichée)"
    
    # Vérifier que le port est bien en écoute
    if ss -tln | grep -q ':8404 '; then
        echo "  ✓ Port 8404 en écoute"
    else
        echo "  ⚠ Port 8404 non en écoute (HAProxy config?)"
        
        # Vérifier la config HAProxy
        if docker exec haproxy cat /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null | grep -q "listen stats"; then
            echo "  → Config stats trouvée, redémarrage HAProxy..."
            docker restart haproxy >/dev/null 2>&1
            sleep 3
            
            if ss -tln | grep -q ':8404 '; then
                echo "  ✓ Port 8404 maintenant en écoute"
            else
                echo "  ✗ Port toujours non en écoute"
            fi
        else
            echo "  ✗ Section 'listen stats' manquante dans haproxy.cfg"
        fi
    fi
FIXHAPROXY
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Correction appliquée"
    else
        echo -e "  $KO Échec"
    fi
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "✅ CORRECTIONS APPLIQUÉES"
echo ""
echo "Tests de vérification:"
echo ""

# Test API Patroni
echo "→ Test API Patroni (db-master-01):"
if curl -s -m 3 -u "patroni:${PATRONI_API_PASSWORD}" "http://${DB_MASTER_IP}:8008/" 2>/dev/null | grep -q '"state"'; then
    echo -e "  $OK API répond"
else
    echo -e "  $WARN API ne répond toujours pas"
    echo ""
    echo "  Vérifier l'authentification dans patroni.yml:"
    echo "    ssh root@${DB_MASTER_IP} 'docker exec patroni cat /etc/patroni/patroni.yml | grep -A5 restapi'"
    echo ""
    echo "  Tester avec credentials depuis postgres.env:"
    echo "    curl -u patroni:\$PATRONI_API_PASSWORD http://${DB_MASTER_IP}:8008/"
fi

echo ""

# Test HAProxy Stats
echo "→ Test HAProxy Stats (haproxy-01):"
if curl -s -m 3 "http://${HAPROXY1_IP}:8404/" 2>/dev/null | grep -q "Statistics"; then
    echo -e "  $OK Stats accessibles"
    echo "    http://${HAPROXY1_IP}:8404/"
else
    echo -e "  $WARN Stats non accessibles"
    echo ""
    echo "  Vérifier la config HAProxy:"
    echo "    ssh root@${HAPROXY1_IP} 'docker exec haproxy cat /usr/local/etc/haproxy/haproxy.cfg | grep -A10 \"listen stats\"'"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📋 Prochaine étape: Relancer le diagnostic complet"
echo "   bash diagnostic_rapide.sh"
echo ""
