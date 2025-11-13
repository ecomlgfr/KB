#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     CORRECTIF HAPROXY - Ajout bind localhost (127.0.0.1)          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SCRIPT_05="/opt/keybuzz-installer/scripts/08_PostgreSQL_16_HA_Patroni/05_haproxy_patroni_FIXED_V2.sh"

if [ ! -f "$SCRIPT_05" ]; then
    echo -e "$KO Script non trouvé: $SCRIPT_05"
    exit 1
fi

echo ""
echo "Ce script va modifier HAProxy pour écouter AUSSI sur localhost:"
echo "  • 127.0.0.1:5432 (Write)"
echo "  • 127.0.0.1:5433 (Read)"
echo "  • 127.0.0.1:6432 (PgBouncer backend)"
echo ""
read -p "Continuer ? (yes/NO): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Annulé"
    exit 0
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Backup
echo "→ Backup du script original"
cp "$SCRIPT_05" "${SCRIPT_05}.backup.$(date +%s)"
echo -e "  $OK Backup créé"

# Vérifier si déjà corrigé
if grep -q "bind 127.0.0.1:5432" "$SCRIPT_05"; then
    echo -e "  $OK Déjà corrigé (bind 127.0.0.1 trouvé)"
else
    echo "→ Application du correctif..."
    
    # Ajouter bind 127.0.0.1:5432 après bind ${IP_PRIVEE}:5432
    sed -i '/bind ${IP_PRIVEE}:5432/a\    bind 127.0.0.1:5432' "$SCRIPT_05"
    
    # Ajouter bind 127.0.0.1:5433 après bind ${IP_PRIVEE}:5433
    sed -i '/bind ${IP_PRIVEE}:5433/a\    bind 127.0.0.1:5433' "$SCRIPT_05"
    
    # Ajouter bind 127.0.0.1:6432 après bind ${IP_PRIVEE}:6432
    sed -i '/bind ${IP_PRIVEE}:6432/a\    bind 127.0.0.1:6432' "$SCRIPT_05"
    
    echo -e "  $OK Correctif appliqué"
fi

# Vérifier
echo ""
echo "→ Vérification de la correction"
COUNT=$(grep -c "bind 127.0.0.1:" "$SCRIPT_05" || echo "0")

if [ "$COUNT" -ge 3 ]; then
    echo -e "  $OK $COUNT binds localhost trouvés"
else
    echo -e "  $WARN Seulement $COUNT binds localhost (attendu: 3)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Script modifié avec succès"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🔄 Prochaines étapes:"
echo ""
echo "   1. Vérifier la modification:"
echo "      grep -B1 -A1 'bind 127.0.0.1' $SCRIPT_05"
echo ""
echo "   2. Réinstaller HAProxy (UN PAR UN):"
echo ""
echo "      # Sur haproxy-01"
echo "      ssh root@10.0.0.11 'docker stop haproxy; docker rm haproxy'"
echo "      sleep 5"
echo ""
echo "      # Relancer le script HAProxy (il va recréer haproxy-01 ET haproxy-02)"
echo "      bash $SCRIPT_05"
echo ""
echo "   3. Vérifier les ports écoutent sur localhost:"
echo "      ssh root@10.0.0.11 'ss -tln | grep 127.0.0.1'"
echo ""
echo "   4. Tester PgBouncer:"
echo "      PGPASSWORD='b2eUq9eBCxTMsatoQMNJ' psql -h 10.0.0.11 -p 6432 -U postgres -d postgres -c 'SELECT 1'"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
