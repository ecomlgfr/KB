#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     CORRECTIFS SÉCURITÉ - Détection et application automatique    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Chercher les scripts dans plusieurs emplacements possibles
POSSIBLE_PATHS=(
    "/opt/keybuzz-installer/scripts"
    "/opt/keybuzz-installer/scripts/08_PostgreSQL_16_HA_Patroni"
    "$HOME/scripts"
    "$(pwd)"
    "/root/scripts"
)

SCRIPT_04=""
SCRIPT_06=""

echo ""
echo "→ Recherche des scripts..."

for path in "${POSSIBLE_PATHS[@]}"; do
    if [ -f "$path/04_postgres16_patroni_raft_FIXED.sh" ]; then
        SCRIPT_04="$path/04_postgres16_patroni_raft_FIXED.sh"
        echo -e "  $OK Script 04 trouvé: $SCRIPT_04"
    fi
    
    if [ -f "$path/06_pgbouncer_scram_CORRECTED_V5.sh" ]; then
        SCRIPT_06="$path/06_pgbouncer_scram_CORRECTED_V5.sh"
        echo -e "  $OK Script 06 trouvé: $SCRIPT_06"
    fi
done

echo ""

# Si scripts non trouvés, afficher les instructions manuelles
if [ -z "$SCRIPT_04" ] || [ -z "$SCRIPT_06" ]; then
    echo -e "$WARN Scripts non trouvés automatiquement"
    echo ""
    echo "Veuillez indiquer l'emplacement de vos scripts:"
    echo ""
    read -p "Chemin du script 04_postgres16_patroni_raft_FIXED.sh: " SCRIPT_04
    read -p "Chemin du script 06_pgbouncer_scram_CORRECTED_V5.sh: " SCRIPT_06
    
    # Vérifier les chemins fournis
    if [ ! -f "$SCRIPT_04" ]; then
        echo -e "$KO Script 04 introuvable: $SCRIPT_04"
        exit 1
    fi
    
    if [ ! -f "$SCRIPT_06" ]; then
        echo -e "$KO Script 06 introuvable: $SCRIPT_06"
        exit 1
    fi
fi

echo ""
echo "Scripts trouvés:"
echo "  • Script 04: $SCRIPT_04"
echo "  • Script 06: $SCRIPT_06"
echo ""
read -p "Continuer avec ces scripts ? (yes/NO): " CONFIRM

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

echo "→ Backup du script original"
cp "$SCRIPT_04" "${SCRIPT_04}.backup.$(date +%s)"
echo -e "  $OK Backup créé: ${SCRIPT_04}.backup.*"

echo "→ Application du correctif pg_hba.conf"

# Compter les occurrences à corriger
COUNT_BEFORE=$(grep -c "0\.0\.0\.0/0" "$SCRIPT_04" || echo "0")
echo "  Occurrences trouvées: $COUNT_BEFORE"

if [ "$COUNT_BEFORE" -eq 0 ]; then
    echo -e "  $OK Déjà corrigé (pas de 0.0.0.0/0 trouvé)"
else
    # Appliquer les corrections
    sed -i 's|host all all 0\.0\.0\.0/0 scram-sha-256|host all all 10.0.0.0/16 scram-sha-256|g' "$SCRIPT_04"
    sed -i 's|host replication replicator 0\.0\.0\.0/0 scram-sha-256|host replication replicator 10.0.0.0/16 scram-sha-256|g' "$SCRIPT_04"
    
    # Vérifier le correctif
    COUNT_AFTER=$(grep -c "0\.0\.0\.0/0" "$SCRIPT_04" || echo "0")
    
    if [ "$COUNT_AFTER" -eq 0 ]; then
        echo -e "  $OK Correctif appliqué ($COUNT_BEFORE corrections)"
        
        # Vérifier que 10.0.0.0/16 est présent
        if grep -q "10.0.0.0/16" "$SCRIPT_04"; then
            echo -e "  $OK Réseau privé 10.0.0.0/16 configuré"
        else
            echo -e "  $WARN 10.0.0.0/16 non trouvé (vérification manuelle requise)"
        fi
    else
        echo -e "  $WARN Correctif partiel ($COUNT_AFTER occurrences restantes)"
    fi
fi

echo ""

# ============================================================================
# CORRECTIF 2: userlist.txt complet
# ============================================================================

echo "▓▓▓ CORRECTIF 2/3: Complétion userlist.txt ▓▓▓"
echo ""

echo "→ Backup du script original"
cp "$SCRIPT_06" "${SCRIPT_06}.backup.$(date +%s)"
echo -e "  $OK Backup créé: ${SCRIPT_06}.backup.*"

echo "→ Vérification de la section userlist.txt"

if grep -q "HASH_N8N" "$SCRIPT_06"; then
    echo -e "  $OK Déjà corrigé (HASH_N8N trouvé)"
else
    echo "  → Application du correctif..."
    
    # Créer le patch
    cat > /tmp/userlist_patch.txt <<'PATCH'
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
PATCH
    
    # Trouver la ligne où remplacer
    LINE_NUM=$(grep -n "Récupération des hash SCRAM depuis PostgreSQL" "$SCRIPT_06" | head -1 | cut -d: -f1)
    
    if [ -n "$LINE_NUM" ]; then
        echo "  Ligne trouvée: $LINE_NUM"
        echo -e "  $WARN Correctif complexe - application manuelle recommandée"
        echo ""
        echo "  Instructions manuelles:"
        echo "    1. Éditer: nano $SCRIPT_06"
        echo "    2. Chercher: 'Récupération des hash SCRAM'"
        echo "    3. Remplacer par le contenu de: /tmp/userlist_patch.txt"
    else
        echo -e "  $WARN Section non trouvée - vérification manuelle requise"
    fi
fi

echo ""

# ============================================================================
# CORRECTIF 3: PgBouncer via HAProxy local
# ============================================================================

echo "▓▓▓ CORRECTIF 3/3: Routing PgBouncer via HAProxy ▓▓▓"
echo ""

echo "→ Vérification configuration actuelle"

if grep -q "host=127.0.0.1 port=5432" "$SCRIPT_06"; then
    echo -e "  $OK Déjà corrigé (host=127.0.0.1 trouvé)"
else
    echo "→ Application du correctif routing"
    
    # Compter les occurrences
    COUNT_BEFORE=$(grep -c 'host=\$DB_MASTER port=5432' "$SCRIPT_06" || echo "0")
    
    if [ "$COUNT_BEFORE" -gt 0 ]; then
        sed -i 's|\* = host=\$DB_MASTER port=5432|* = host=127.0.0.1 port=5432|g' "$SCRIPT_06"
        
        # Vérifier
        if grep -q "host=127.0.0.1 port=5432" "$SCRIPT_06"; then
            echo -e "  $OK Correctif appliqué ($COUNT_BEFORE corrections)"
        else
            echo -e "  $KO Échec du correctif"
        fi
    else
        echo -e "  $WARN Pattern non trouvé - vérification manuelle requise"
    fi
fi

echo ""

# ============================================================================
# RÉSUMÉ
# ============================================================================

echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Compter les correctifs appliqués
FIXES_APPLIED=0

# Vérifier correctif 1
if ! grep -q "0\.0\.0\.0/0" "$SCRIPT_04" 2>/dev/null; then
    ((FIXES_APPLIED++))
fi

# Vérifier correctif 3
if grep -q "host=127.0.0.1 port=5432" "$SCRIPT_06" 2>/dev/null; then
    ((FIXES_APPLIED++))
fi

if [ $FIXES_APPLIED -ge 2 ]; then
    echo -e "$OK CORRECTIFS APPLIQUÉS ($FIXES_APPLIED/3)"
else
    echo -e "$WARN CORRECTIFS PARTIELS ($FIXES_APPLIED/3)"
fi

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📝 Scripts modifiés:"
echo "   • $SCRIPT_04"
echo "   • $SCRIPT_06"
echo ""
echo "💾 Backups créés:"
echo "   • ${SCRIPT_04}.backup.*"
echo "   • ${SCRIPT_06}.backup.*"
echo ""
echo "⚠️  CORRECTIF 2 (userlist.txt):"
echo "   → Nécessite modification manuelle"
echo "   → Instructions dans: /tmp/userlist_patch.txt"
echo ""
echo "🔄 Prochaines étapes:"
echo ""
echo "   1. Vérifier les correctifs appliqués:"
echo "      grep -n '10.0.0.0/16' $SCRIPT_04"
echo "      grep -n '127.0.0.1' $SCRIPT_06"
echo ""
echo "   2. Appliquer correctif 2 manuellement (si nécessaire):"
echo "      nano $SCRIPT_06"
echo ""
echo "   3. Réinstaller PostgreSQL/Patroni (si déjà installé):"
echo "      cd $(dirname $SCRIPT_04)"
echo "      bash 03_db_clean_reset.sh  # yes"
echo "      bash $(basename $SCRIPT_04)"
echo ""
echo "   4. Réinstaller PgBouncer:"
echo "      cd $(dirname $SCRIPT_06)"
echo "      ./cleanup_pgbouncer.sh  # yes"
echo "      bash $(basename $SCRIPT_06)"
echo ""
echo "   5. Valider:"
echo "      ./diagnostic_rapide_V2_FINAL.sh"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
