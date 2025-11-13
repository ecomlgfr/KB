#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║            DB STORAGE PREPARATION (PostgreSQL Volumes)            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR"

usage() {
    echo "Usage: $0 --host <hostname>"
    echo "Exemple: $0 --host db-master-01"
    exit 1
}

HOST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$HOST" ]] && usage
[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_PRIVEE=$(awk -F'\t' -v h="$HOST" '$2==h {print $3; exit}' "$SERVERS_TSV")
[[ -z "$IP_PRIVEE" ]] && { echo -e "$KO IP introuvable pour $HOST"; exit 1; }

echo "Préparation stockage PostgreSQL sur $HOST ($IP_PRIVEE)..."
echo

LOGFILE="$LOG_DIR/db_prep_storage_${HOST}_${TIMESTAMP}.log"

ssh -o StrictHostKeyChecking=no root@"$IP_PRIVEE" "bash -s" <<'EOSSH' 2>&1 | tee "$LOGFILE"
set -u
set -o pipefail

BASE="/opt/keybuzz/postgres"
DATA="${BASE}/data"
CFG="${BASE}/config"
LOGS="${BASE}/logs"
ST="${BASE}/status"

echo "Création arborescence PostgreSQL..."
mkdir -p "$DATA" "$CFG" "$LOGS" "$ST"

if [[ ! -f /opt/keybuzz-installer/inventory/servers.tsv ]]; then
    echo "Note: servers.tsv absent localement (sera copié lors du déploiement)"
    mkdir -p /opt/keybuzz-installer/inventory
fi

if ! mountpoint -q "$DATA"; then
    echo "Recherche device pour PostgreSQL data..."
    
    DEV=""
    for candidate in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
        [[ -e "$candidate" ]] || continue
        real=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
        
        if mount | grep -q " $real "; then
            continue
        fi
        
        DEV="$real"
        break
    done
    
    if [[ -z "$DEV" ]]; then
        echo "ERREUR: Aucun device libre trouvé pour PostgreSQL"
        echo "KO" > "$ST/STATE"
        exit 1
    fi
    
    echo "Device trouvé: $DEV"
    
    if ! blkid "$DEV" 2>/dev/null | grep -q ext4; then
        echo "Formatage ext4..."
        if ! mkfs.ext4 -F -m0 -O dir_index,has_journal,extent "$DEV" >/dev/null 2>&1; then
            echo "ERREUR: Échec formatage $DEV"
            echo "KO" > "$ST/STATE"
            exit 1
        fi
    else
        echo "Device déjà formaté ext4"
    fi
    
    echo "Montage sur $DATA..."
    if ! mount "$DEV" "$DATA"; then
        echo "ERREUR: Échec montage $DEV sur $DATA"
        echo "KO" > "$ST/STATE"
        exit 1
    fi
    
    UUID=$(blkid -s UUID -o value "$DEV")
    
    if ! grep -q " $DATA " /etc/fstab; then
        echo "Ajout à fstab (UUID=$UUID)..."
        echo "UUID=$UUID $DATA ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    
    if [[ -d "$DATA/lost+found" ]]; then
        echo "Suppression lost+found..."
        rm -rf "$DATA/lost+found"
    fi
    
    echo "Volume PostgreSQL monté et configuré"
else
    echo "Volume déjà monté sur $DATA"
    
    if [[ -d "$DATA/lost+found" ]]; then
        echo "Suppression lost+found existant..."
        rm -rf "$DATA/lost+found"
    fi
fi

df -h "$DATA"
echo

chown -R 999:999 "$DATA" 2>/dev/null || true
chmod 755 "$DATA"

echo "Arborescence prête:"
ls -la "$BASE"
echo

echo "OK" > "$ST/STATE"
echo "Préparation stockage PostgreSQL terminée"
EOSSH

STATUS=$?

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "Logs (tail -50) pour $HOST:"
tail -n 50 "$LOGFILE"
echo "═══════════════════════════════════════════════════════════════════"
echo

if [[ $STATUS -eq 0 ]]; then
    echo -e "$OK Stockage préparé sur $HOST"
    
    STATE=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIVEE" "cat /opt/keybuzz/postgres/status/STATE 2>/dev/null")
    if [[ "$STATE" == "OK" ]]; then
        echo -e "$OK STATE=OK"
    else
        echo -e "$KO STATE=$STATE"
        exit 1
    fi
    
    exit 0
else
    echo -e "$KO Échec préparation stockage sur $HOST"
    exit 1
fi
