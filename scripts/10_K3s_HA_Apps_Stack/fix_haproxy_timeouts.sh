#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Script: fix_haproxy_timeouts.sh
# Description: Corriger les timeouts HAProxy (50s → 600s)
# Date: 2025-11-17
###############################################################################

OK='✓'
KO='✗'
WARN='⚠'
INFO='ℹ'

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         CORRECTION TIMEOUTS HAProxy (50s → 600s)                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

HAPROXY_IPS=("10.0.0.11" "10.0.0.12")

for HAPROXY_IP in "${HAPROXY_IPS[@]}"; do
    log "$INFO === HAProxy $HAPROXY_IP ==="
    echo ""

    # Test SSH
    if ! timeout 5 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@$HAPROXY_IP "echo OK" &>/dev/null; then
        log "$KO SSH non accessible sur $HAPROXY_IP"
        log "$WARN Passez au serveur suivant ou corrigez manuellement"
        echo ""
        continue
    fi

    log "$OK SSH accessible"

    # Backup config actuelle
    log "$INFO Backup de la config actuelle..."
    ssh -o StrictHostKeyChecking=no root@$HAPROXY_IP \
        "cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d_%H%M%S)"

    # Afficher timeouts actuels
    log "$INFO Timeouts actuels:"
    ssh -o StrictHostKeyChecking=no root@$HAPROXY_IP \
        "grep -E '^[[:space:]]*(timeout connect|timeout client|timeout server)' /etc/haproxy/haproxy.cfg" || \
        log "$WARN Impossible de lire les timeouts"

    echo ""
    log "$INFO Application des nouveaux timeouts (600s)..."

    # Modifier les timeouts
    ssh -o StrictHostKeyChecking=no root@$HAPROXY_IP bash <<'REMOTE_SCRIPT'
# Modifier timeout connect
sed -i 's/^[[:space:]]*timeout connect[[:space:]].*/    timeout connect 10s/' /etc/haproxy/haproxy.cfg

# Modifier timeout client
sed -i 's/^[[:space:]]*timeout client[[:space:]].*/    timeout client  600s/' /etc/haproxy/haproxy.cfg

# Modifier timeout server
sed -i 's/^[[:space:]]*timeout server[[:space:]].*/    timeout server  600s/' /etc/haproxy/haproxy.cfg

# Afficher les nouvelles valeurs
echo "Nouveaux timeouts:"
grep -E '^[[:space:]]*(timeout connect|timeout client|timeout server)' /etc/haproxy/haproxy.cfg

# Vérifier syntaxe
echo ""
echo "Vérification syntaxe HAProxy..."
if haproxy -c -f /etc/haproxy/haproxy.cfg; then
    echo "✓ Config valide"

    # Recharger HAProxy
    echo ""
    echo "Rechargement HAProxy..."
    systemctl reload haproxy

    if [ $? -eq 0 ]; then
        echo "✓ HAProxy rechargé avec succès"
    else
        echo "✗ Erreur lors du rechargement"
        exit 1
    fi
else
    echo "✗ Config invalide - restauration backup"
    cp /etc/haproxy/haproxy.cfg.bak.* /etc/haproxy/haproxy.cfg
    exit 1
fi
REMOTE_SCRIPT

    if [ $? -eq 0 ]; then
        log "$OK HAProxy $HAPROXY_IP corrigé et rechargé"
    else
        log "$KO Erreur lors de la correction sur $HAPROXY_IP"
    fi

    echo ""
done

###############################################################################
# TEST FINAL
###############################################################################
echo ""
log "$INFO === TEST APRÈS CORRECTION ==="
echo ""

log "$INFO Attente propagation (10s)..."
sleep 10

log "$INFO Test Grafana via HAProxy..."
START=$(date +%s.%N)
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 120 https://monitor.keybuzz.io 2>/dev/null || echo "TIMEOUT")
END=$(date +%s.%N)
DURATION=$(echo "$END - $START" | bc)

log "  → HTTP $HTTP_CODE en ${DURATION}s"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    if (( $(echo "$DURATION < 30" | bc -l) )); then
        log "$OK Grafana fonctionne ! (réponse en moins de 30s)"
    else
        log "$WARN Grafana répond mais lent (${DURATION}s)"
    fi
elif [ "$HTTP_CODE" = "TIMEOUT" ]; then
    log "$KO Timeout encore présent - vérifier Load Balancer Hetzner"
else
    log "$WARN HTTP $HTTP_CODE - vérifier logs Grafana"
fi

echo ""
log "$INFO Test Connect API via HAProxy..."
START=$(date +%s.%N)
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 120 https://connect.keybuzz.io 2>/dev/null || echo "TIMEOUT")
END=$(date +%s.%N)
DURATION=$(echo "$END - $START" | bc)

log "  → HTTP $HTTP_CODE en ${DURATION}s"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    if (( $(echo "$DURATION < 30" | bc -l) )); then
        log "$OK Connect API fonctionne ! (réponse en moins de 30s)"
    else
        log "$WARN Connect API répond mais lent (${DURATION}s)"
    fi
elif [ "$HTTP_CODE" = "TIMEOUT" ]; then
    log "$KO Timeout encore présent - vérifier Load Balancer Hetzner"
else
    log "$WARN HTTP $HTTP_CODE - vérifier logs Connect"
fi

###############################################################################
# RÉSUMÉ
###############################################################################
echo ""
log "═══════════════════════════════════════════════════════════════════"
log "$INFO RÉSUMÉ"
log "═══════════════════════════════════════════════════════════════════"
echo ""

log "Timeouts HAProxy modifiés:"
log "  • timeout connect: 10s"
log "  • timeout client:  600s (10 minutes)"
log "  • timeout server:  600s (10 minutes)"
echo ""

log "Backups créés:"
log "  • /etc/haproxy/haproxy.cfg.bak.<timestamp>"
echo ""

log "Si timeout persiste:"
log "  1. Vérifier Load Balancer Hetzner (interface web)"
log "  2. Vérifier firewall intermédiaire"
log "  3. Logs HAProxy: sudo tail -f /var/log/haproxy.log"
echo ""

log "$OK Script terminé"
