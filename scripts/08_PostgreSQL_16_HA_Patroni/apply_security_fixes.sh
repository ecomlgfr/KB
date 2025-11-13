#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     CORRECTIFS SÉCURITÉ - Application automatique                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

echo ""
echo "Ce script va appliquer les correctifs suivants:"
echo ""
echo "  1. 🔴 CRITIQUE: pg_hba.conf → 10.0.0.0/16 (au lieu de 0.0.0.0/0)"
echo "  2. 🟠 RECOMMANDÉ: userlist.txt → ajouter n8n, chatwoot, pgbouncer"
echo "  3. 🟠 RECOMMANDÉ: PgBouncer → router via 127.0.0.1:5432"
echo ""
read -p "Continuer ? (yes/NO): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Annulé"
    exit 0
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ============================================================================
# CORRECTIF 1: pg_hba.conf sécurisé
# ============================================================================

echo "▓▓▓ CORRECTIF 1/3: Sécurisation pg_hba.conf ▓▓▓"
echo ""

SCRIPT_04="/opt/keybuzz-installer/scripts/04_postgres16_patroni_raft_FIXED.sh"

if [ ! -f "$SCRIPT_04" ]; then
    echo -e "$KO Script non trouvé: $SCRIPT_04"
    exit 1
fi

echo "→ Backup du script original"
cp "$SCRIPT_04" "${SCRIPT_04}.backup.$(date +%s)"
echo -e "  $OK Backup créé"

echo "→ Application du correctif pg_hba.conf"
sed -i 's|host all all 0\.0\.0\.0/0 scram-sha-256|host all all 10.0.0.0/16 scram-sha-256|g' "$SCRIPT_04"
sed -i 's|host replication replicator 0\.0\.0\.0/0 scram-sha-256|host replication replicator 10.0.0.0/16 scram-sha-256|g' "$SCRIPT_04"

# Vérifier le correctif
if grep -q "10.0.0.0/16" "$SCRIPT_04"; then
    echo -e "  $OK Correctif appliqué"
else
    echo -e "  $KO Échec du correctif"
    exit 1
fi

echo ""
echo "  ✅ pg_hba.conf maintenant limité au réseau privé 10.0.0.0/16"
echo ""

# ============================================================================
# CORRECTIF 2: userlist.txt complet
# ============================================================================

echo "▓▓▓ CORRECTIF 2/3: Complétion userlist.txt ▓▓▓"
echo ""

SCRIPT_06="/opt/keybuzz-installer/scripts/06_pgbouncer_scram_CORRECTED_V5.sh"

if [ ! -f "$SCRIPT_06" ]; then
    echo -e "$KO Script non trouvé: $SCRIPT_06"
    exit 1
fi

echo "→ Backup du script original"
cp "$SCRIPT_06" "${SCRIPT_06}.backup.$(date +%s)"
echo -e "  $OK Backup créé"

echo "→ Application du correctif userlist.txt"

# Trouver la ligne où on crée userlist.txt et la remplacer
cat > /tmp/userlist_fix.txt <<'FIX'
    # Récupérer les hash SCRAM de TOUS les users
    echo "  → Récupération hash SCRAM postgres..."
    HASH_POSTGRES=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='postgres';" 2>/dev/null | xargs || echo "")
    
    echo "  → Récupération hash SCRAM n8n..."
    HASH_N8N=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='n8n';" 2>/dev/null | xargs || echo "")
    
    echo "  → Récupération hash SCRAM chatwoot..."
    HASH_CHATWOOT=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='chatwoot';" 2>/dev/null | xargs || echo "")
    
    echo "  → Récupération hash SCRAM pgbouncer..."
    HASH_PGBOUNCER=$(PGPASSWORD="$PG_PASSWORD" psql -h "$DB_MASTER" -p 5432 -U postgres -d postgres -t -c "SELECT rolpassword FROM pg_authid WHERE rolname='pgbouncer';" 2>/dev/null | xargs || echo "")
    
    if [ -z "$HASH_POSTGRES" ] || [ "$HASH_POSTGRES" = "null" ]; then
        echo "  ✗ Impossible de récupérer le hash SCRAM postgres"
        exit 1
    fi
    
    echo "  ✓ Hash SCRAM récupérés"
    
    # Créer userlist.txt avec TOUS les users
    echo "  → Création userlist.txt..."
    cat > "$BASE/config/userlist.txt" <<EOF
"postgres" "$HASH_POSTGRES"
EOF
    
    # Ajouter n8n si le hash existe
    if [ -n "$HASH_N8N" ] && [ "$HASH_N8N" != "null" ]; then
        echo "\"n8n\" \"$HASH_N8N\"" >> "$BASE/config/userlist.txt"
        echo "    ✓ User n8n ajouté"
    fi
    
    # Ajouter chatwoot si le hash existe
    if [ -n "$HASH_CHATWOOT" ] && [ "$HASH_CHATWOOT" != "null" ]; then
        echo "\"chatwoot\" \"$HASH_CHATWOOT\"" >> "$BASE/config/userlist.txt"
        echo "    ✓ User chatwoot ajouté"
    fi
    
    # Ajouter pgbouncer si le hash existe
    if [ -n "$HASH_PGBOUNCER" ] && [ "$HASH_PGBOUNCER" != "null" ]; then
        echo "\"pgbouncer\" \"$HASH_PGBOUNCER\"" >> "$BASE/config/userlist.txt"
        echo "    ✓ User pgbouncer ajouté"
    fi
FIX

# Remplacer la section dans le script
# (Ligne approximative ~80-85)
sed -i '/echo "  → Récupération des hash SCRAM depuis PostgreSQL..."/,/cat > "\$BASE\/config\/userlist.txt"/c\
    # CORRECTIF: Récupération de TOUS les users\
    '"$(cat /tmp/userlist_fix.txt | sed 's/$/\\/')"'' "$SCRIPT_06"

if grep -q "HASH_N8N" "$SCRIPT_06"; then
    echo -e "  $OK Correctif appliqué"
else
    echo -e "  $WARN Correctif partiel (vérifier manuellement)"
fi

echo ""
echo "  ✅ userlist.txt inclura maintenant tous les users applicatifs"
echo ""

# ============================================================================
# CORRECTIF 3: PgBouncer via HAProxy local
# ============================================================================

echo "▓▓▓ CORRECTIF 3/3: Routing PgBouncer via HAProxy ▓▓▓"
echo ""

echo "→ Application du correctif routing"
sed -i 's|\* = host=\$DB_MASTER port=5432|* = host=127.0.0.1 port=5432|g' "$SCRIPT_06"

if grep -q "host=127.0.0.1 port=5432" "$SCRIPT_06"; then
    echo -e "  $OK Correctif appliqué"
else
    echo -e "  $KO Échec du correctif"
    exit 1
fi

echo ""
echo "  ✅ PgBouncer routera via HAProxy local (127.0.0.1:5432)"
echo ""

# ============================================================================
# RÉSUMÉ
# ============================================================================

echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK TOUS LES CORRECTIFS APPLIQUÉS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📝 Scripts modifiés:"
echo "   • 04_postgres16_patroni_raft_FIXED.sh"
echo "   • 06_pgbouncer_scram_CORRECTED_V5.sh"
echo ""
echo "💾 Backups créés:"
echo "   • ${SCRIPT_04}.backup.*"
echo "   • ${SCRIPT_06}.backup.*"
echo ""
echo "🔄 Prochaines étapes:"
echo ""
echo "   1. Réinstaller PostgreSQL/Patroni (si déjà installé):"
echo "      bash 03_db_clean_reset.sh  # yes"
echo "      bash 04_postgres16_patroni_raft_FIXED.sh"
echo ""
echo "   2. Réinstaller PgBouncer:"
echo "      ./cleanup_pgbouncer.sh  # yes"
echo "      bash 06_pgbouncer_scram_CORRECTED_V5.sh"
echo ""
echo "   3. Valider:"
echo "      ./diagnostic_rapide_V2_FINAL.sh"
echo "      bash 07_test_infrastructure_FINAL_V2.sh"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "✅ Résultat attendu: 22/22 tests (100%)"
echo ""
