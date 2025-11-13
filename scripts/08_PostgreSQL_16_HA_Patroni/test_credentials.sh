#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         TEST CHARGEMENT CREDENTIALS                                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

echo ""
echo "→ Test 1: Fichier credentials existe ?"
CRED_FILE="/opt/keybuzz-installer/credentials/postgres.env"
if [ -f "$CRED_FILE" ]; then
    echo "  ✓ Fichier trouvé: $CRED_FILE"
    echo "    Permissions: $(ls -l $CRED_FILE | awk '{print $1, $3, $4}')"
else
    echo "  ✗ Fichier introuvable"
    exit 1
fi

echo ""
echo "→ Test 2: Chargement du fichier"
source "$CRED_FILE"
echo "  ✓ Fichier chargé"

echo ""
echo "→ Test 3: Variables définies ?"
echo "  POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-NOT SET}"
echo "  REPLICATOR_PASSWORD=${REPLICATOR_PASSWORD:-NOT SET}"
echo "  PATRONI_API_PASSWORD=${PATRONI_API_PASSWORD:-NOT SET}"

echo ""
echo "→ Test 4: Curl manuel avec credentials"
DB_MASTER_IP="10.0.0.120"
echo "  Curl vers $DB_MASTER_IP:8008..."

RESULT=$(curl -s -m 5 -u "patroni:${PATRONI_API_PASSWORD}" "http://${DB_MASTER_IP}:8008/" 2>&1)
if echo "$RESULT" | grep -q '"state"'; then
    echo "  ✓ API répond"
    echo "$RESULT" | python3 -m json.tool | head -15 | sed 's/^/    /'
else
    echo "  ✗ API ne répond pas ou erreur"
    echo "    Résultat: $(echo $RESULT | head -c 100)"
fi

echo ""
echo "→ Test 5: Extraction role et state"
ROLE=$(echo "$RESULT" | grep -o '"role":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
STATE=$(echo "$RESULT" | grep -o '"state":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
echo "  Role: $ROLE"
echo "  State: $STATE"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ TEST TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
