#!/usr/bin/env bash
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓${NC} $*"; }
ko() { echo -e "${RED}✗${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

cat <<'EOF'
╔════════════════════════════════════════════════════════════════════╗
║         REDÉMARRAGE SERVEURS VÉRIFIÉ                               ║
╚════════════════════════════════════════════════════════════════════╝
EOF

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/reboot_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG") 2>&1

[[ ! -f "$SERVERS_TSV" ]] && { ko "servers.tsv introuvable"; exit 1; }

TOTAL=$(grep -cE "^[0-9]" "$SERVERS_TSV" || echo 0)
echo ""
warn "$TOTAL serveurs vont redémarrer après vérification"
warn "Vérifications: SSH + Docker + structure /opt/keybuzz"
echo ""

if [[ "${1:-}" != "-y" && "${1:-}" != "--yes" ]]; then
    read -p "Continuer? (y/N) " -r
    [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Annulé"; exit 0; }
fi

echo ""
ok "Démarrage redémarrage vérifié..."
echo ""

reboot_server() {
    local ip_pub="$1"
    local hostname="$2"
    local ip_priv="$3"
    
    # Tenter IP privée d'abord
    TARGET_IP="$ip_priv"
    if ! timeout 3 ssh -o BatchMode=yes -o ConnectTimeout=2 root@"$TARGET_IP" "echo 1" &>/dev/null; then
        # Fallback IP publique
        TARGET_IP="$ip_pub"
        if ! timeout 3 ssh -o BatchMode=yes -o ConnectTimeout=2 root@"$TARGET_IP" "echo 1" &>/dev/null; then
            echo "$hostname: KO (SSH impossible)"
            return 1
        fi
    fi
    
    # Vérifications
    if ! ssh -o BatchMode=yes root@"$TARGET_IP" "
        docker --version &>/dev/null && \
        docker compose version &>/dev/null && \
        [ -d /opt/keybuzz ]
    " 2>/dev/null; then
        echo "$hostname: KO (vérifications échouées)"
        return 1
    fi
    
    # Redémarrage
    ssh -o BatchMode=yes root@"$TARGET_IP" "reboot" 2>/dev/null
    echo "$hostname: OK (redémarrage lancé)"
    return 0
}

export -f reboot_server

if ! command -v parallel &>/dev/null; then
    warn "Installation GNU parallel..."
    apt-get update -qq && apt-get install -y -qq parallel >/dev/null 2>&1
fi

grep -E "^[0-9]" "$SERVERS_TSV" | parallel -j 10 --colsep '\t' \
    reboot_server {1} {2} {3}

echo ""
echo "══════════════════════════════════════════════════════════════════"

SUCCESS=$(grep "OK (redémarrage lancé)$" "$MAIN_LOG" | wc -l)
FAILED=$(grep "KO" "$MAIN_LOG" | wc -l)

echo "RÉSUMÉ:"
echo "  Total:      $TOTAL"
echo "  Redémarrés: $SUCCESS"
echo "  Échecs:     $FAILED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    ok "TOUS LES SERVEURS REDÉMARRÉS"
    echo ""
    warn "Attendre ~2 minutes pour stabilisation réseau"
    echo ""
    echo "Test connectivité après redémarrage:"
    echo "  ./DIAG_NETWORK_CURRENT.sh"
else
    warn "$FAILED serveurs non redémarrés"
    echo ""
    echo "Logs: $MAIN_LOG"
fi

exit 0
