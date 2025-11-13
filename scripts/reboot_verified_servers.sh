#!/bin/bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INVENTORY="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/reboot_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"

echo "=== Redémarrage des serveurs vérifiés ===" | tee "$MAIN_LOG"
echo "" | tee -a "$MAIN_LOG"

reboot_server() {
    local ip="$1"
    local hostname="$2"
    
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "
        docker --version >/dev/null 2>&1 && \
        docker compose version >/dev/null 2>&1 && \
        wg --version >/dev/null 2>&1
    " 2>/dev/null; then
        echo -e "${RED}KO${NC} $hostname ($ip) - Vérification échouée" | tee -a "$MAIN_LOG"
        return 1
    fi
    
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@"$ip" "reboot" 2>/dev/null
    echo -e "${GREEN}OK${NC} $hostname ($ip) - Redémarrage lancé" | tee -a "$MAIN_LOG"
    return 0
}

export -f reboot_server
export RED GREEN YELLOW NC MAIN_LOG

if [ "$1" != "-y" ]; then
    TOTAL=$(tail -n +2 "$INVENTORY" | grep -c -E "^[0-9]" || echo "0")
    echo -e "${YELLOW}$TOTAL serveurs vont redémarrer${NC}"
    echo -n "Continuer ? (o/N) "
    read -r response
    if [[ ! "$response" =~ ^[Oo]$ ]]; then
        echo "Annulé"
        exit 0
    fi
fi

tail -n +2 "$INVENTORY" | grep -E "^[0-9]" | parallel -j 10 --colsep '\t' reboot_server {1} {2}

echo "" | tee -a "$MAIN_LOG"
echo "=== Terminé ===" | tee -a "$MAIN_LOG"
echo "Log: $MAIN_LOG"
