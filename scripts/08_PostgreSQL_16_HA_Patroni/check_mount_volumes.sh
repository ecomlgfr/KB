#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         CHECK_MOUNT_VOLUMES - Vérification volumes HAProxy         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
HOST="${1:-haproxy-01}"

IP_PRIV=$(awk -F'\t' -v h="$HOST" '$2==h {print $3}' "$SERVERS_TSV")
[ -z "$IP_PRIV" ] && { echo -e "$KO $HOST IP introuvable"; exit 1; }

echo ""
echo "Vérification des volumes sur $HOST ($IP_PRIV)"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'CHECK_MOUNT'
echo "1. Volumes disponibles:"
echo "   Devices disponibles:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "disk|part" | sed 's/^/   /'

echo ""
echo "2. Montages actuels:"
df -h | grep -E "^/dev|Filesystem" | sed 's/^/   /'

echo ""
echo "3. Volume HAProxy monté?"
MOUNT_POINT="/opt/keybuzz/haproxy/data"
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "   ✓ $MOUNT_POINT est monté"
    df -h "$MOUNT_POINT" | tail -1 | sed 's/^/   /'
else
    echo "   ✗ $MOUNT_POINT n'est PAS monté"
fi

echo ""
echo "4. Recherche d'un volume non monté:"
# Chercher un volume Hetzner non monté (généralement /dev/sdb ou scsi)
DEVICE=""
for dev in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
    if [ -b "$dev" ]; then
        real_dev=$(readlink -f "$dev" 2>/dev/null || echo "$dev")
        # Vérifier si ce device n'est pas déjà monté
        if ! mount | grep -q "$real_dev"; then
            size=$(lsblk -b -n -o SIZE "$real_dev" 2>/dev/null | head -1)
            if [ -n "$size" ]; then
                size_gb=$((size / 1000000000))
                echo "   Trouvé: $real_dev ($size_gb GB) - NON MONTÉ"
                DEVICE="$real_dev"
                break
            fi
        fi
    fi
done

if [ -z "$DEVICE" ]; then
    echo "   ✗ Aucun volume non monté trouvé"
else
    echo ""
    echo "5. Montage du volume:"
    
    # Créer le point de montage
    mkdir -p /opt/keybuzz/haproxy/data
    
    # Vérifier si formaté
    if ! blkid "$DEVICE" 2>/dev/null | grep -q "TYPE="; then
        echo "   Formatage en ext4..."
        mkfs.ext4 -F -m0 "$DEVICE" >/dev/null 2>&1
    fi
    
    # Monter le volume
    mount "$DEVICE" /opt/keybuzz/haproxy/data
    
    if [ $? -eq 0 ]; then
        echo "   ✓ Volume monté sur /opt/keybuzz/haproxy/data"
        
        # Ajouter à fstab
        UUID=$(blkid -s UUID -o value "$DEVICE")
        if ! grep -q "$UUID" /etc/fstab; then
            echo "UUID=$UUID /opt/keybuzz/haproxy/data ext4 defaults,nofail 0 2" >> /etc/fstab
            echo "   ✓ Ajouté à /etc/fstab"
        fi
        
        # Supprimer lost+found
        rm -rf /opt/keybuzz/haproxy/data/lost+found 2>/dev/null
        
        # Créer les répertoires pour HAProxy et PgBouncer
        mkdir -p /opt/keybuzz/haproxy/data/{haproxy,pgbouncer,logs,backups}
        
        # Déplacer les configs existantes
        if [ -d /opt/keybuzz/db-proxy ] && [ ! -L /opt/keybuzz/db-proxy ]; then
            echo "   Migration des données existantes..."
            cp -rp /opt/keybuzz/db-proxy/* /opt/keybuzz/haproxy/data/ 2>/dev/null || true
            rm -rf /opt/keybuzz/db-proxy
            ln -s /opt/keybuzz/haproxy/data /opt/keybuzz/db-proxy
            echo "   ✓ Données migrées vers le volume"
        fi
        
        df -h /opt/keybuzz/haproxy/data | tail -1
    else
        echo "   ✗ Échec du montage"
    fi
fi

echo ""
echo "6. État final:"
echo "   Montages:"
mount | grep "/opt/keybuzz" | sed 's/^/   /'

echo ""
echo "   Espace disque:"
df -h | grep -E "/opt/keybuzz|Filesystem" | sed 's/^/   /'

echo ""
echo "   Services Docker:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "NAME|haproxy|pgbouncer" | sed 's/^/   /'
CHECK_MOUNT

echo ""
echo "═══════════════════════════════════════════════════════════════════"
MOUNTED=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "mountpoint -q /opt/keybuzz/haproxy/data && echo YES || echo NO")
if [ "$MOUNTED" = "YES" ]; then
    echo -e "$OK Volume monté sur $HOST"
    echo ""
    echo "Pour vérifier l'autre serveur:"
    echo "  $0 haproxy-02"
else
    echo -e "$KO Volume non monté sur $HOST"
    echo ""
    echo "Le volume devrait être monté pour la persistance des données."
    echo "Contactez Hetzner si aucun volume n'est attaché au serveur."
fi
echo "═══════════════════════════════════════════════════════════════════"
