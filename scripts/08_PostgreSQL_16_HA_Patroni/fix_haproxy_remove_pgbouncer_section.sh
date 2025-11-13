#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX HAPROXY - SUPPRIMER SECTION PGBOUNCER                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "Le fichier haproxy.cfg contient une section 'frontend pgbouncer_pool'"
echo "qui écoute sur le port 6432. Cette section doit être supprimée car"
echo "c'est PgBouncer qui doit gérer ce port, pas HAProxy."
echo ""
echo "Ce script va:"
echo "  1. Supprimer la section 'frontend pgbouncer_pool' complète"
echo "  2. Redémarrer HAProxy"
echo "  3. Vérifier que le port 6432 est libre"
echo ""
read -p "Continuer ? (yes/NO): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Annulé"
    exit 0
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "▓▓▓ $NAME ($IP) ▓▓▓"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'FIX'
    set -e
    
    CFG_HOST="/opt/keybuzz/haproxy/config/haproxy.cfg"
    CFG_CONTAINER="/usr/local/etc/haproxy/haproxy.cfg"
    
    echo "→ Backup de la config actuelle..."
    cp "$CFG_HOST" "$CFG_HOST.backup.$(date +%s)"
    
    echo "→ Affichage de la section problématique:"
    grep -A5 "frontend pgbouncer_pool" "$CFG_HOST" 2>/dev/null | sed 's/^/  /' || echo "  (Section non trouvée)"
    echo ""
    
    echo "→ Suppression de la section 'frontend pgbouncer_pool'..."
    # Supprimer depuis "frontend pgbouncer_pool" jusqu'à la prochaine ligne vide ou section
    sed -i '/^# Frontend PgBouncer/,/^$/d' "$CFG_HOST"
    sed -i '/^frontend pgbouncer_pool/,/^$/d' "$CFG_HOST"
    
    echo "→ Vérification de la suppression..."
    if grep -q "6432" "$CFG_HOST"; then
        echo "  ⚠ Le port 6432 est encore mentionné dans la config"
        grep -n "6432" "$CFG_HOST" | sed 's/^/  /'
        
        echo ""
        echo "  → Suppression de TOUTES les lignes contenant 6432..."
        sed -i '/6432/d' "$CFG_HOST"
    fi
    
    if grep -q "6432" "$CFG_HOST"; then
        echo "  ✗ Échec de la suppression"
        exit 1
    else
        echo "  ✓ Section pgbouncer_pool supprimée"
    fi
    
    echo ""
    echo "→ Copie de la nouvelle config dans le conteneur..."
    docker cp "$CFG_HOST" haproxy:"$CFG_CONTAINER"
    
    echo "→ Validation de la nouvelle config..."
    if docker exec haproxy haproxy -c -f "$CFG_CONTAINER" >/dev/null 2>&1; then
        echo "  ✓ Config valide"
    else
        echo "  ✗ Config invalide"
        docker exec haproxy haproxy -c -f "$CFG_CONTAINER"
        exit 1
    fi
    
    echo ""
    echo "→ Redémarrage de HAProxy..."
    docker restart haproxy >/dev/null 2>&1
    sleep 5
    
    echo "→ Vérification du port 6432..."
    if ss -tln | grep -q ":6432"; then
        echo "  ✗ Port 6432 encore en écoute"
        ss -tln | grep ":6432" | sed 's/^/  /'
    else
        echo "  ✓ Port 6432 maintenant libre"
    fi
    
    echo ""
    echo "→ Vérification des autres ports HAProxy..."
    echo "  Ports en écoute:"
    ss -tln | grep -E ":(5432|5433|8404)" | sed 's/^/    /' || echo "    (Aucun port HAProxy détecté)"
FIX
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Correction appliquée avec succès"
    else
        echo -e "  $KO Échec de la correction"
    fi
    
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK FIX HAPROXY TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Vérification finale:"
echo ""

# Vérifier sur haproxy-01
echo "→ Port 6432 sur haproxy-01:"
if ssh -o StrictHostKeyChecking=no root@"$HAPROXY1_IP" "ss -tln | grep -q ':6432'"; then
    echo -e "  $KO Encore en écoute"
else
    echo -e "  $OK Libre"
fi

# Vérifier sur haproxy-02
echo "→ Port 6432 sur haproxy-02:"
if ssh -o StrictHostKeyChecking=no root@"$HAPROXY2_IP" "ss -tln | grep -q ':6432'"; then
    echo -e "  $KO Encore en écoute"
else
    echo -e "  $OK Libre"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Prochaines étapes:"
echo "  1. Nettoyer et réinstaller PgBouncer"
echo "     ./cleanup_pgbouncer.sh"
echo "     bash 06_pgbouncer_scram_CORRECTED_V5.sh"
echo ""
echo "  2. Diagnostic final"
echo "     ./diagnostic_rapide_V2_FINAL.sh"
echo ""
