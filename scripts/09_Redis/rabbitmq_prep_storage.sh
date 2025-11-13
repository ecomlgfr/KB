#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         RABBITMQ_PREP_STORAGE - Préparation des nœuds              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR" "$CREDS_DIR"

# Parser les arguments
HOST=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift 2 ;;
        *) echo "Usage: $0 --host queue-0X"; exit 1 ;;
    esac
done

[ -z "$HOST" ] && { echo -e "$KO Host requis (--host queue-01/02/03)"; exit 1; }

LOG_FILE="$LOG_DIR/rabbitmq_prep_${HOST}_$TIMESTAMP.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo ""
echo "Préparation de $HOST pour RabbitMQ"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Obtenir l'IP privée depuis servers.tsv
IP_PRIV=$(awk -F'\t' -v h="$HOST" '$2==h {print $3}' "$SERVERS_TSV")
[ -z "$IP_PRIV" ] && { echo -e "$KO IP privée de $HOST introuvable dans servers.tsv"; exit 1; }

echo "  Host: $HOST"
echo "  IP privée: $IP_PRIV"
echo ""

# Générer le cookie Erlang si absent (partagé entre tous les nœuds)
if [ ! -f "$CREDS_DIR/rabbitmq.env" ]; then
    echo "  Génération des credentials RabbitMQ..."
    
    RABBITMQ_ERLANG_COOKIE=$(openssl rand -hex 32)
    RABBITMQ_ADMIN_PASS=$(openssl rand -base64 32 | tr -d "=+/\n" | cut -c1-25)
    
    cat > "$CREDS_DIR/rabbitmq.env" <<EOF
#!/bin/bash
# RabbitMQ Credentials - NE JAMAIS COMMITER
# Généré le $(date)
export RABBITMQ_ERLANG_COOKIE="$RABBITMQ_ERLANG_COOKIE"
export RABBITMQ_ADMIN_USER="admin"
export RABBITMQ_ADMIN_PASS="$RABBITMQ_ADMIN_PASS"
export RABBITMQ_CLUSTER_NAME="keybuzz-queue"
EOF
    chmod 600 "$CREDS_DIR/rabbitmq.env"
    
    # Ajouter à secrets.json
    if [ -f "$CREDS_DIR/secrets.json" ]; then
        jq ".rabbitmq_erlang_cookie = \"$RABBITMQ_ERLANG_COOKIE\" | .rabbitmq_admin_pass = \"$RABBITMQ_ADMIN_PASS\"" \
           "$CREDS_DIR/secrets.json" > /tmp/secrets.tmp && mv /tmp/secrets.tmp "$CREDS_DIR/secrets.json"
    else
        echo "{\"rabbitmq_erlang_cookie\": \"$RABBITMQ_ERLANG_COOKIE\", \"rabbitmq_admin_pass\": \"$RABBITMQ_ADMIN_PASS\"}" | \
        jq '.' > "$CREDS_DIR/secrets.json"
    fi
    chmod 600 "$CREDS_DIR/secrets.json"
    
    echo "  Credentials générés et sécurisés"
else
    echo "  Chargement des credentials existants..."
    source "$CREDS_DIR/rabbitmq.env"
fi

echo ""
echo "═══ Configuration du serveur $HOST ═══"
echo ""

# Copier les credentials sur le serveur
echo "  Copie des credentials..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" "mkdir -p /opt/keybuzz-installer/credentials"
scp -q -o ConnectTimeout=10 "$CREDS_DIR/rabbitmq.env" root@"$IP_PRIV":/opt/keybuzz-installer/credentials/

# Préparer le serveur
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash <<'PREPARE'
set -u
set -o pipefail

# Charger les credentials
source /opt/keybuzz-installer/credentials/rabbitmq.env

BASE="/opt/keybuzz/rabbitmq"
DATA="$BASE/data"
CONFIG="$BASE/config"
LOGS="$BASE/logs"
STATUS="$BASE/status"

echo "  Création de la structure..."
mkdir -p "$DATA" "$CONFIG" "$LOGS" "$STATUS"

# Vérifier si le volume est monté
echo "  Vérification du volume..."
if mountpoint -q "$DATA"; then
    # Vérifier le système de fichiers
    FS_TYPE=$(df -T "$DATA" | tail -1 | awk '{print $2}')
    echo "    Volume monté (système de fichiers: $FS_TYPE)"
    
    if [ "$FS_TYPE" != "xfs" ]; then
        echo "    ⚠ Attention: Volume en $FS_TYPE au lieu de XFS"
    fi
else
    echo "    ⚠ Volume non monté sur $DATA"
    echo "    Tentative de montage..."
    
    # Chercher un device libre
    DEVICE=""
    for dev in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
        [ -e "$dev" ] || continue
        real=$(readlink -f "$dev" 2>/dev/null || echo "$dev")
        mount | grep -q " $real " && continue
        DEVICE="$real"
        break
    done
    
    if [ -n "$DEVICE" ]; then
        # Vérifier si XFS
        if blkid "$DEVICE" 2>/dev/null | grep -q "TYPE=\"xfs\""; then
            mount "$DEVICE" "$DATA"
            UUID=$(blkid -s UUID -o value "$DEVICE")
            grep -q " $DATA " /etc/fstab || echo "UUID=$UUID $DATA xfs defaults,nofail 0 2" >> /etc/fstab
            echo "    ✓ Volume XFS monté"
        else
            echo "    Volume trouvé mais pas en XFS, formatage..."
            mkfs.xfs -f "$DEVICE" >/dev/null 2>&1
            mount "$DEVICE" "$DATA"
            UUID=$(blkid -s UUID -o value "$DEVICE")
            grep -q " $DATA " /etc/fstab || echo "UUID=$UUID $DATA xfs defaults,nofail 0 2" >> /etc/fstab
            echo "    ✓ Volume formaté en XFS et monté"
        fi
    else
        echo "    ✗ Aucun device libre trouvé"
    fi
fi

# Permissions pour RabbitMQ (UID 999)
chown -R 999:999 "$DATA" "$LOGS"
chmod 755 "$DATA" "$LOGS"

# Copier les credentials localement
cp /opt/keybuzz-installer/credentials/rabbitmq.env "$BASE/.env"
chmod 600 "$BASE/.env"

# Nettoyer les anciens containers
docker ps -aq --filter "name=rabbitmq" | xargs -r docker stop 2>/dev/null
docker ps -aq --filter "name=rabbitmq" | xargs -r docker rm 2>/dev/null

echo "OK" > "$STATUS/STATE"
echo "  ✓ Préparation terminée"
PREPARE

echo ""
echo "═══ Résumé ═══"
echo ""

# Vérifier l'état
STATE=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP_PRIV" "cat /opt/keybuzz/rabbitmq/status/STATE 2>/dev/null" || echo "KO")

if [ "$STATE" = "OK" ]; then
    echo -e "$OK $HOST préparé avec succès"
else
    echo -e "$KO Problème lors de la préparation de $HOST"
fi

echo ""
echo "Logs (50 dernières lignes):"
echo "═══════════════════════════"
tail -n 50 "$LOG_FILE" | grep -E "(✓|✗|OK|KO|Erreur|Warning)"
