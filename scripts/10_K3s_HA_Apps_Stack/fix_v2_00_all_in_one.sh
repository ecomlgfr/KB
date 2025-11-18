#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: fix_v2_00_all_in_one.sh
# Description: Master script - Execute tous les fix V2
# Date: 2025-11-18
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OK='✓'
KO='✗'
WARN='⚠'
INFO='ℹ'

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         FIX V2 - ALL IN ONE (Master Script)                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

log "$INFO Ce script va exécuter tous les fix V2 en séquence:"
log "   1. fix_v2_01_connect_api_image.sh    - Fix Connect API ImagePullBackOff"
log "   2. fix_v2_02_airbyte_dns.sh          - Fix Airbyte DNS resolution"
log "   3. fix_v2_03_dolibarr_init.sh        - Fix Dolibarr initialization"
log "   4. fix_v2_04_grafana_sidecars.sh     - Fix Grafana sidecar crashes"
echo ""

read -p "Continuer? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "$WARN Annulé par l'utilisateur"
    exit 0
fi

# Tableau pour tracker les résultats
declare -A RESULTS

###############################################################################
# FIX 1: Connect API Image
###############################################################################
echo ""
log "$INFO ═══════════════════════════════════════════════════════════════"
log "$INFO [1/4] FIX Connect API Image Pull"
log "$INFO ═══════════════════════════════════════════════════════════════"
echo ""

if [ -f "$SCRIPT_DIR/fix_v2_01_connect_api_image.sh" ]; then
    if bash "$SCRIPT_DIR/fix_v2_01_connect_api_image.sh"; then
        RESULTS["connect"]="$OK SUCCESS"
        log "$OK Fix Connect API terminé avec succès"
    else
        RESULTS["connect"]="$KO FAILED"
        log "$KO Fix Connect API a échoué"
    fi
else
    RESULTS["connect"]="$WARN SCRIPT NOT FOUND"
    log "$WARN Script fix_v2_01_connect_api_image.sh non trouvé"
fi

sleep 5

###############################################################################
# FIX 2: Airbyte DNS
###############################################################################
echo ""
log "$INFO ═══════════════════════════════════════════════════════════════"
log "$INFO [2/4] FIX Airbyte DNS Resolution"
log "$INFO ═══════════════════════════════════════════════════════════════"
echo ""

if [ -f "$SCRIPT_DIR/fix_v2_02_airbyte_dns.sh" ]; then
    if bash "$SCRIPT_DIR/fix_v2_02_airbyte_dns.sh"; then
        RESULTS["airbyte"]="$OK SUCCESS"
        log "$OK Fix Airbyte terminé avec succès"
    else
        RESULTS["airbyte"]="$KO FAILED"
        log "$KO Fix Airbyte a échoué"
    fi
else
    RESULTS["airbyte"]="$WARN SCRIPT NOT FOUND"
    log "$WARN Script fix_v2_02_airbyte_dns.sh non trouvé"
fi

sleep 5

###############################################################################
# FIX 3: Dolibarr Initialization
###############################################################################
echo ""
log "$INFO ═══════════════════════════════════════════════════════════════"
log "$INFO [3/4] FIX Dolibarr Initialization"
log "$INFO ═══════════════════════════════════════════════════════════════"
echo ""

if [ -f "$SCRIPT_DIR/fix_v2_03_dolibarr_init.sh" ]; then
    if bash "$SCRIPT_DIR/fix_v2_03_dolibarr_init.sh"; then
        RESULTS["dolibarr"]="$OK SUCCESS"
        log "$OK Fix Dolibarr terminé avec succès"
    else
        RESULTS["dolibarr"]="$KO FAILED"
        log "$KO Fix Dolibarr a échoué"
    fi
else
    RESULTS["dolibarr"]="$WARN SCRIPT NOT FOUND"
    log "$WARN Script fix_v2_03_dolibarr_init.sh non trouvé"
fi

sleep 5

###############################################################################
# FIX 4: Grafana Sidecars
###############################################################################
echo ""
log "$INFO ═══════════════════════════════════════════════════════════════"
log "$INFO [4/4] FIX Grafana Sidecar Crashes"
log "$INFO ═══════════════════════════════════════════════════════════════"
echo ""

if [ -f "$SCRIPT_DIR/fix_v2_04_grafana_sidecars.sh" ]; then
    if bash "$SCRIPT_DIR/fix_v2_04_grafana_sidecars.sh"; then
        RESULTS["grafana"]="$OK SUCCESS"
        log "$OK Fix Grafana terminé avec succès"
    else
        RESULTS["grafana"]="$KO FAILED"
        log "$KO Fix Grafana a échoué"
    fi
else
    RESULTS["grafana"]="$WARN SCRIPT NOT FOUND"
    log "$WARN Script fix_v2_04_grafana_sidecars.sh non trouvé"
fi

###############################################################################
# VALIDATION FINALE
###############################################################################
echo ""
echo ""
log "$INFO ═══════════════════════════════════════════════════════════════"
log "$INFO VALIDATION FINALE"
log "$INFO ═══════════════════════════════════════════════════════════════"
echo ""

sleep 10

log "$INFO Test de tous les services..."
echo ""

# Test Connect API
log "$INFO [1/4] Test Connect API..."
CONNECT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://connect.keybuzz.io/health --max-time 10 || echo "TIMEOUT")
if [ "$CONNECT_STATUS" = "200" ]; then
    log "$OK Connect API: HTTP $CONNECT_STATUS"
elif [ "$CONNECT_STATUS" = "503" ]; then
    log "$WARN Connect API: HTTP $CONNECT_STATUS (backend non prêt)"
else
    log "$KO Connect API: HTTP $CONNECT_STATUS"
fi

# Test Airbyte
log "$INFO [2/4] Test Airbyte..."
AIRBYTE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://airbyte.keybuzz.io --max-time 10 || echo "TIMEOUT")
if [ "$AIRBYTE_STATUS" = "200" ] || [ "$AIRBYTE_STATUS" = "302" ]; then
    log "$OK Airbyte: HTTP $AIRBYTE_STATUS"
else
    log "$KO Airbyte: HTTP $AIRBYTE_STATUS"
fi

# Test Dolibarr
log "$INFO [3/4] Test Dolibarr..."
DOLIBARR_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://erp.keybuzz.io --max-time 30 || echo "TIMEOUT")
if [ "$DOLIBARR_STATUS" = "200" ]; then
    log "$OK Dolibarr: HTTP $DOLIBARR_STATUS"
elif [ "$DOLIBARR_STATUS" = "202" ]; then
    log "$WARN Dolibarr: HTTP $DOLIBARR_STATUS (initialisation en cours)"
else
    log "$KO Dolibarr: HTTP $DOLIBARR_STATUS"
fi

# Test Grafana
log "$INFO [4/4] Test Grafana..."
GRAFANA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://monitor.keybuzz.io --max-time 10 || echo "TIMEOUT")
if [ "$GRAFANA_STATUS" = "200" ] || [ "$GRAFANA_STATUS" = "302" ]; then
    log "$OK Grafana: HTTP $GRAFANA_STATUS"
else
    log "$KO Grafana: HTTP $GRAFANA_STATUS"
fi

# Vérifier les pods
echo ""
log "$INFO État des pods:"
echo ""

log "$INFO Connect (namespace: connect):"
kubectl get pods -n connect -l app=connect-api 2>/dev/null || log "$WARN Namespace connect vide"

echo ""
log "$INFO Airbyte (namespace: etl):"
kubectl get pods -n etl 2>/dev/null | head -10 || log "$WARN Namespace etl vide"

echo ""
log "$INFO Dolibarr (namespace: erp):"
kubectl get pods -n erp 2>/dev/null || log "$WARN Namespace erp vide"

echo ""
log "$INFO Grafana (namespace: monitoring):"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null || log "$WARN Namespace monitoring vide"

###############################################################################
# RAPPORT FINAL
###############################################################################
echo ""
echo ""
log "═════════════════════════════════════════════════════════════════════"
log "                    RAPPORT FINAL - FIX V2"
log "═════════════════════════════════════════════════════════════════════"
echo ""

log "Résultats des fix:"
for service in connect airbyte dolibarr grafana; do
    log "  • $(printf '%-20s' "$service"): ${RESULTS[$service]}"
done

echo ""
log "URLs des services:"
log "  • Connect API:  http://connect.keybuzz.io"
log "  • Airbyte:      http://airbyte.keybuzz.io"
log "  • Dolibarr:     http://erp.keybuzz.io"
log "  • Grafana:      http://monitor.keybuzz.io"

echo ""
log "Credentials par défaut:"
log "  • Connect API:  Vérifier /health"
log "  • Airbyte:      airbyte / password"
log "  • Dolibarr:     admin / Admin123!"
log "  • Grafana:      admin / AdminGrafana123!"

echo ""
log "Commandes utiles:"
log "  • Voir tous les pods:        kubectl get pods -A"
log "  • Logs Connect API:          kubectl logs -n connect -l app=connect-api --tail=50"
log "  • Logs Airbyte:              kubectl logs -n etl -l app.kubernetes.io/name=server --tail=50"
log "  • Logs Dolibarr:             kubectl logs -n erp -l component=web --tail=50"
log "  • Logs Grafana:              kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50"

echo ""
log "═════════════════════════════════════════════════════════════════════"
log "$OK Tous les fix V2 ont été exécutés"
log "═════════════════════════════════════════════════════════════════════"
