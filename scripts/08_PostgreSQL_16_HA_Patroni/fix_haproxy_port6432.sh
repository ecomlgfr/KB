#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX HAPROXY - RETIRER PORT 6432                            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "HAProxy écoute actuellement sur le port 6432, ce qui empêche"
echo "PgBouncer de démarrer. Ce script va:"
echo ""
echo "  1. Identifier les sections HAProxy qui bindent sur 6432"
echo "  2. Commenter/supprimer ces bindings"
echo "  3. Redémarrer HAProxy"
echo "  4. Vérifier que le port 6432 est libre"
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
    
    CFG_PATH="/opt/keybuzz/haproxy/config"
    CFG_FILE="$CFG_PATH/haproxy.cfg"
    
    echo "→ Vérification du port 6432 dans HAProxy..."
    if docker exec haproxy cat "$CFG_FILE" 2>/dev/null | grep -q ":6432"; then
        echo "  ⚠ Port 6432 trouvé dans haproxy.cfg"
        
        # Backup de la config
        docker exec haproxy cp "$CFG_FILE" "$CFG_FILE.backup.$(date +%s)" 2>/dev/null || true
        
        # Afficher les lignes concernées
        echo ""
        echo "  Lignes contenant 6432:"
        docker exec haproxy grep -n "6432" "$CFG_FILE" 2>/dev/null | sed 's/^/    /' || true
        echo ""
        
        # Créer une nouvelle config sans le port 6432
        echo "  → Création d'une nouvelle config sans le port 6432..."
        docker exec haproxy bash -c "sed '/6432/d' $CFG_FILE > $CFG_FILE.new && mv $CFG_FILE.new $CFG_FILE"
        
        echo "  ✓ Config modifiée"
    else
        echo "  ✓ Port 6432 non trouvé dans haproxy.cfg (déjà OK)"
    fi
    
    echo ""
    echo "→ Vérification du port actuel..."
    if ss -tln | grep -q ":6432"; then
        echo "  ⚠ Port 6432 en écoute (HAProxy ou autre)"
        ss -tln | grep ":6432" | sed 's/^/    /'
        
        # Redémarrer HAProxy pour appliquer les changements
        echo ""
        echo "  → Redémarrage de HAProxy..."
        docker restart haproxy >/dev/null 2>&1
        sleep 5
        
        # Re-vérifier
        if ss -tln | grep -q ":6432"; then
            echo "  ⚠ Port 6432 toujours en écoute"
            ss -tln | grep ":6432" | sed 's/^/    /'
        else
            echo "  ✓ Port 6432 maintenant libre"
        fi
    else
        echo "  ✓ Port 6432 libre"
    fi
FIX
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Correction appliquée"
    else
        echo -e "  $KO Échec"
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
echo "Le port 6432 devrait maintenant être libre."
echo ""
echo "Prochaines étapes:"
echo "  1. Nettoyer et réinstaller PgBouncer"
echo "     ./cleanup_pgbouncer.sh"
echo "     bash 06_pgbouncer_scram_CORRECTED_V5.sh"
echo ""
echo "  2. Vérifier que PgBouncer démarre correctement"
echo "     ssh root@10.0.0.11 'docker ps | grep pgbouncer'"
echo ""
