#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         NETTOYAGE CONTENEURS PGBOUNCER                             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "Ce script va:"
echo "  1. Lister tous les conteneurs pgbouncer (actifs et arrêtés)"
echo "  2. Supprimer tous les conteneurs pgbouncer"
echo "  3. Libérer le port 6432"
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
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'CLEANUP'
    set -e
    
    echo "→ Liste des conteneurs pgbouncer:"
    docker ps -a --filter name=pgbouncer --format "  {{.ID}}\t{{.Names}}\t{{.Status}}"
    
    echo ""
    echo "→ Arrêt de tous les conteneurs pgbouncer..."
    docker ps -a --filter name=pgbouncer -q | xargs -r docker stop 2>/dev/null || true
    
    echo "→ Suppression de tous les conteneurs pgbouncer..."
    docker ps -a --filter name=pgbouncer -q | xargs -r docker rm -f 2>/dev/null || true
    
    echo "→ Libération du port 6432..."
    fuser -k 6432/tcp 2>/dev/null || true
    sleep 2
    
    echo "→ Vérification..."
    REMAINING=$(docker ps -a --filter name=pgbouncer -q | wc -l)
    if [ "$REMAINING" -eq 0 ]; then
        echo "  ✓ Tous les conteneurs pgbouncer supprimés"
    else
        echo "  ⚠ Il reste $REMAINING conteneur(s)"
        docker ps -a --filter name=pgbouncer
    fi
    
    # Vérifier le port
    if ss -tln | grep -q ":6432 "; then
        echo "  ⚠ Port 6432 encore utilisé"
        ss -tln | grep ":6432"
    else
        echo "  ✓ Port 6432 libre"
    fi
CLEANUP
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Nettoyage réussi"
    else
        echo -e "  $KO Échec"
    fi
    
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK NETTOYAGE TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Prochaine étape: Réinstaller PgBouncer"
echo "   bash 06_pgbouncer_scram_CORRECTED_V5.sh"
echo ""
