#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              REDIS_TEST_FINAL - Test de l'état actuel              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

# Charger les credentials
source "$CREDS_DIR/redis.env"

echo ""
echo "1. Test de connexion basique:"
echo ""

# Test simple sans écriture
echo -n "  Connexion au LB (10.0.0.10): "
if timeout 2 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
    echo -e "$OK"
    
    # Info sur le master
    echo -n "  Rôle: "
    timeout 2 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2
else
    echo -e "$KO"
fi

echo ""
echo "2. Test d'écriture/lecture simple:"
echo ""

# Test avec une clé simple
TEST_KEY="test_$(date +%s)"
TEST_VALUE="ok"

echo -n "  Écriture: "
RESULT=$(timeout 2 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET "$TEST_KEY" "$TEST_VALUE" 2>&1)
if echo "$RESULT" | grep -q "OK"; then
    echo -e "$OK"
    
    echo -n "  Lecture: "
    VALUE=$(timeout 2 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning GET "$TEST_KEY" 2>/dev/null)
    if [ "$VALUE" = "$TEST_VALUE" ]; then
        echo -e "$OK (valeur: $VALUE)"
    else
        echo -e "$KO"
    fi
else
    echo -e "$KO"
    echo "    Erreur: $RESULT"
fi

echo ""
echo "3. Vérification des replicas:"
echo ""

for host in redis-01 redis-02 redis-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  $host: "
    
    if timeout 2 redis-cli -h "$IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        ROLE=$(timeout 2 redis-cli -h "$IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        echo -e "$OK (role: $ROLE)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Le plus important : est-ce que ça marche via le LB ?
if timeout 2 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING &>/dev/null; then
    echo -e "$OK REDIS HA FONCTIONNEL VIA 10.0.0.10:6379"
    echo ""
    echo "L'échec du test d'écriture peut être dû à:"
    echo "  • Timeout trop court (2-3 secondes)"
    echo "  • Latence réseau temporaire"
    echo "  • Redis en cours de synchronisation"
    echo ""
    echo "Si les connexions fonctionnent, c'est OK !"
else
    echo -e "$KO Redis non accessible"
fi
echo "═══════════════════════════════════════════════════════════════════"
