#!/usr/bin/env bash
set -uo pipefail

export HCLOUD_TOKEN='PvaKOohQayiL8MpTsPpkzDMdWqRLauDErV4NTCwUKF333VeZ5wDDqFbKZb1q7HrE'
INVENTORY="/opt/keybuzz-installer/inventory/servers.tsv"

ok(){ echo -e "\033[0;32m✓\033[0m $*"; }
ko(){ echo -e "\033[0;31m✗\033[0m $*"; }
warn(){ echo -e "\033[0;33m⚠\033[0m $*"; }

if ! command -v hcloud &>/dev/null; then
    wget -q https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz
    tar -xzf hcloud-linux-amd64.tar.gz && mv hcloud /usr/local/bin/
    rm hcloud-linux-amd64.tar.gz
    ok "hcloud installé"
fi

if ! command -v jq &>/dev/null; then
    rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null
    apt-get update -qq 2>/dev/null && apt-get install -y jq -qq 2>/dev/null
    ok "jq installé"
fi

hcloud server list &>/dev/null || { ko "API Hetzner inaccessible"; exit 1; }

get_server_location() {
    hcloud server describe "$1" -o json 2>/dev/null | jq -r '.datacenter.location.name'
}

get_mount_point() {
    case "$1" in
        *db-master*|*db-slave*) echo "/opt/keybuzz/postgres/data" ;;
        *redis*) echo "/opt/keybuzz/redis/data" ;;
        *minio*) echo "/opt/keybuzz/minio/data" ;;
        *backup*) echo "/opt/keybuzz/backup/data" ;;
        *queue*|*rabbitmq*) echo "/opt/keybuzz/rabbitmq/data" ;;
        *vector*|*qdrant*) echo "/opt/keybuzz/qdrant/data" ;;
        *mail-core*) echo "/opt/keybuzz/mail/data" ;;
        *k3s-master*) echo "/var/lib/rancher/k3s" ;;
        *k3s-worker*) echo "/var/lib/containerd" ;;
        *monitor*) echo "/opt/keybuzz/monitor/data" ;;
        *vault*) echo "/opt/keybuzz/vault/data" ;;
        *siem*) echo "/opt/keybuzz/siem/data" ;;
        *temporal-db*) echo "/opt/keybuzz/temporal-db/data" ;;
        *analytics-db*) echo "/opt/keybuzz/analytics-db/data" ;;
        *analytics-01*) echo "/opt/keybuzz/superset/data" ;;
        *etl*) echo "/opt/keybuzz/airbyte/data" ;;
        *baserow*) echo "/opt/keybuzz/baserow/data" ;;
        *nocodb*) echo "/opt/keybuzz/nocodb/data" ;;
        *ml-platform*) echo "/opt/keybuzz/mlflow/data" ;;
        *api-gateway*) echo "/opt/keybuzz/gateway/data" ;;
        *litellm*) echo "/opt/keybuzz/litellm/data" ;;
        *n8n*) echo "/opt/keybuzz/n8n/data" ;;
        *) echo "/opt/keybuzz/data" ;;
    esac
}

get_wg_ip() {
    grep "	$1	" "$INVENTORY" 2>/dev/null | awk '{print $3}'
}

format_and_mount() {
    local hostname=$1
    local size=$2
    local wg_ip=$(get_wg_ip "$hostname")
    local mount_point=$(get_mount_point "$hostname")
    
    [ -z "$wg_ip" ] && { ko "IP WG $hostname introuvable"; return 1; }
    
    ssh -o ConnectTimeout=10 root@"$wg_ip" bash <<EOSSH 2>&1 | grep -E "OK|KO|MOUNTED" | head -1
set -uo pipefail
MOUNT_POINT="$mount_point"
SIZE=$size

if mountpoint -q "\$MOUNT_POINT" 2>/dev/null; then
    echo "MOUNTED"
    exit 0
fi

DEVICE=\$(ls -1 /dev/disk/by-id/scsi-* 2>/dev/null | grep -v part | head -1 | xargs readlink -f 2>/dev/null)

if [ -z "\$DEVICE" ]; then
    TARGET_SIZE=\$((SIZE * 1000000000))
    TOLERANCE=\$((TARGET_SIZE / 10))
    for dev in /dev/sd[b-z] /dev/vd[b-z]; do
        [ -b "\$dev" ] || continue
        DEV_SIZE=\$(lsblk -b -n -o SIZE "\$dev" 2>/dev/null | head -1)
        [ -z "\$DEV_SIZE" ] && continue
        if [ \$DEV_SIZE -gt \$((TARGET_SIZE - TOLERANCE)) ] && [ \$DEV_SIZE -lt \$((TARGET_SIZE + TOLERANCE)) ]; then
            mount | grep -q "\$dev" || { DEVICE="\$dev"; break; }
        fi
    done
fi

[ -z "\$DEVICE" ] && { echo "KO"; exit 1; }

mkdir -p "\$MOUNT_POINT"

if ! blkid "\$DEVICE" 2>/dev/null | grep -q ext4; then
    wipefs -af "\$DEVICE" 2>/dev/null
    mkfs.ext4 -F -m0 -O dir_index,has_journal,extent "\$DEVICE" 2>/dev/null || { echo "KO"; exit 1; }
fi

mount "\$DEVICE" "\$MOUNT_POINT" 2>/dev/null || { echo "KO"; exit 1; }

UUID=\$(blkid -s UUID -o value "\$DEVICE")
grep -q "\$MOUNT_POINT" /etc/fstab || echo "UUID=\$UUID \$MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab

[ -d "\$MOUNT_POINT/lost+found" ] && chmod 700 "\$MOUNT_POINT/lost+found"
chown -R 999:999 "\$MOUNT_POINT" 2>/dev/null || true

echo "OK"
EOSSH
}

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║         GESTION VOLUMES HETZNER - KEYBUZZ              ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "0) CREER - Créer volumes par catégorie"
echo "1) LISTER - Afficher volumes existants"
echo "2) MONTER - Monter volumes existants"
echo "3) DETACHER - Détacher tous les volumes"
echo "4) SUPPRIMER - Supprimer tous les volumes (⚠️  DANGER)"
echo ""
read -p "Choix (0-4): " choice
echo ""

case "$choice" in
    0)
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║            CREATION VOLUMES PAR CATEGORIE              ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        echo "1) OBLIGATOIRES (8 volumes - 620 GB)"
        echo "   db-master-01, db-slave-01/02, minio-01,"
        echo "   redis-01, vector-db-01, backup-01, mail-core-01"
        echo ""
        echo "2) RECOMMANDES (9 volumes - 460 GB)"
        echo "   queue-01/02/03, monitor-01, vault-01, siem-01,"
        echo "   haproxy-01/02"
        echo ""
        echo "3) K3S (8 volumes - 370 GB)"
        echo "   k3s-master-01/02/03, k3s-worker-02/03/04/05"
        echo "   (k3s-worker-01 déjà créé - 100GB)"
        echo ""
        echo "4) OPTIONNELS (13 volumes - 520 GB)"
        echo "   redis-02/03, temporal-db-01, analytics-db-01,"
        echo "   analytics-01, etl-01, baserow-01, nocodb-01,"
        echo "   ml-platform-01, api-gateway-01, litellm-01"
        echo ""
        read -p "Catégorie (1-4 ou 'all'): " category
        echo ""
        
        declare -A VOLUMES
        
        if [[ "$category" =~ ^(1|all)$ ]]; then
            VOLUMES["db-master-01"]="100"
            VOLUMES["db-slave-01"]="50"
            VOLUMES["db-slave-02"]="50"
            VOLUMES["minio-01"]="100"
            VOLUMES["redis-01"]="20"
            VOLUMES["vector-db-01"]="50"
            VOLUMES["backup-01"]="200"
            VOLUMES["mail-core-01"]="50"
        fi
        
        if [[ "$category" =~ ^(2|all)$ ]]; then
            VOLUMES["queue-01"]="40"
            VOLUMES["queue-02"]="40"
            VOLUMES["queue-03"]="40"
            VOLUMES["monitor-01"]="100"
            VOLUMES["vault-01"]="20"
            VOLUMES["siem-01"]="200"
            VOLUMES["haproxy-01"]="10"
            VOLUMES["haproxy-02"]="10"
        fi
        
        if [[ "$category" =~ ^(3|all)$ ]]; then
            VOLUMES["k3s-master-01"]="40"
            VOLUMES["k3s-master-02"]="40"
            VOLUMES["k3s-master-03"]="40"
            VOLUMES["k3s-worker-02"]="50"
            VOLUMES["k3s-worker-03"]="50"
            VOLUMES["k3s-worker-04"]="50"
            VOLUMES["k3s-worker-05"]="50"
        fi
        
        if [[ "$category" =~ ^(4|all)$ ]]; then
            VOLUMES["redis-02"]="20"
            VOLUMES["redis-03"]="20"
            VOLUMES["temporal-db-01"]="50"
            VOLUMES["analytics-db-01"]="100"
            VOLUMES["analytics-01"]="20"
            VOLUMES["etl-01"]="50"
            VOLUMES["baserow-01"]="20"
            VOLUMES["nocodb-01"]="20"
            VOLUMES["ml-platform-01"]="50"
            VOLUMES["api-gateway-01"]="10"
            VOLUMES["litellm-01"]="20"
        fi
        
        [ ${#VOLUMES[@]} -eq 0 ] && { ko "Catégorie invalide"; exit 1; }
        
        total_size=0
        for size in "${VOLUMES[@]}"; do
            total_size=$((total_size + size))
        done
        
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║              CONFIRMATION CREATION                      ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        echo "Volumes à créer: ${#VOLUMES[@]}"
        echo "Taille totale: ${total_size} GB"
        echo ""
        read -p "Confirmer? (yes/NO): " confirm
        [ "$confirm" != "yes" ] && exit 0
        
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "PHASE 1/3: CREATION VOLUMES"
        echo "═══════════════════════════════════════════════════════"
        
        created=0
        skipped=0
        failed=0
        
        for hostname in "${!VOLUMES[@]}"; do
            size="${VOLUMES[$hostname]}"
            vol_name="vol-${hostname}"
            
            if hcloud volume describe "$vol_name" &>/dev/null; then
                warn "$vol_name déjà existant"
                ((skipped++))
                continue
            fi
            
            location=$(get_server_location "$hostname")
            [ -z "$location" ] && { ko "$hostname serveur introuvable"; ((failed++)); continue; }
            
            if hcloud volume create --name "$vol_name" --size "$size" --location "$location" &>/dev/null; then
                ok "$vol_name créé (${size}GB @ $location)"
                ((created++))
            else
                ko "$vol_name échec création"
                ((failed++))
            fi
        done
        
        echo ""
        echo "Créés: $created | Déjà présents: $skipped | Échecs: $failed"
        
        [ $created -eq 0 ] && { warn "Aucun volume créé"; exit 0; }
        
        sleep 3
        
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "PHASE 2/3: ATTACHEMENT VOLUMES"
        echo "═══════════════════════════════════════════════════════"
        
        attached=0
        
        for hostname in "${!VOLUMES[@]}"; do
            vol_name="vol-${hostname}"
            
            hcloud volume describe "$vol_name" &>/dev/null || continue
            
            current_server=$(hcloud volume describe "$vol_name" -o json 2>/dev/null | jq -r '.server // empty')
            
            if [ -n "$current_server" ]; then
                warn "$vol_name déjà attaché"
                continue
            fi
            
            if hcloud volume attach "$vol_name" --server "$hostname" &>/dev/null; then
                ok "$vol_name → $hostname"
                ((attached++))
            else
                ko "$vol_name échec attachement"
            fi
        done
        
        echo ""
        echo "Attachés: $attached"
        
        [ $attached -eq 0 ] && { warn "Aucun attachement"; exit 0; }
        
        sleep 5
        
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "PHASE 3/3: FORMATAGE & MONTAGE"
        echo "═══════════════════════════════════════════════════════"
        
        mounted=0
        already_mounted=0
        mount_failed=0
        
        for hostname in "${!VOLUMES[@]}"; do
            size="${VOLUMES[$hostname]}"
            result=$(format_and_mount "$hostname" "$size")
            
            case "$result" in
                *MOUNTED*)
                    warn "$hostname déjà monté"
                    ((already_mounted++))
                    ;;
                *OK*)
                    ok "$hostname formaté & monté"
                    ((mounted++))
                    ;;
                *)
                    ko "$hostname échec montage"
                    ((mount_failed++))
                    ;;
            esac
        done
        
        echo ""
        echo "Montés: $mounted | Déjà montés: $already_mounted | Échecs: $mount_failed"
        echo ""
        
        total_ok=$((created + attached + mounted))
        if [ $total_ok -gt 0 ]; then
            ok "Création terminée avec succès"
        else
            warn "Aucune opération effectuée"
        fi
        ;;
        
    1)
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║              VOLUMES EXISTANTS                          ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        
        VOLS=$(hcloud volume list -o json 2>/dev/null)
        total=$(echo "$VOLS" | jq -r '. | length')
        
        if [ "$total" -eq 0 ]; then
            warn "Aucun volume"
            exit 0
        fi
        
        echo "$VOLS" | jq -r '.[] | "\(.name)|\(.size)GB|\(.server // "non-attaché")|\(.location.name)"' | while IFS='|' read -r name size server loc; do
            [ "$server" = "non-attaché" ] && warn "$name ($size) - $loc - NON ATTACHE" || ok "$name ($size) → $server ($loc)"
        done
        
        echo ""
        echo "Total: $total volumes"
        ;;
        
    2)
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║              MONTAGE VOLUMES                            ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        read -p "Confirmer montage? (y/N): " confirm
        [ "$confirm" != "y" ] && exit 0
        echo ""
        
        VOLS=$(hcloud volume list -o json 2>/dev/null | jq -r '.[] | select(.server != null) | "\(.name)|\(.size)|\(.server)"')
        
        [ -z "$VOLS" ] && { warn "Aucun volume attaché"; exit 0; }
        
        mounted=0
        already_mounted=0
        failed=0
        
        echo "$VOLS" | while IFS='|' read -r vol_name size server_id; do
            hostname=$(hcloud server describe "$server_id" -o json 2>/dev/null | jq -r '.name')
            [ -z "$hostname" ] && continue
            
            result=$(format_and_mount "$hostname" "$size")
            
            case "$result" in
                *MOUNTED*)
                    warn "$hostname déjà monté"
                    ((already_mounted++))
                    ;;
                *OK*)
                    ok "$hostname monté"
                    ((mounted++))
                    ;;
                *)
                    ko "$hostname échec"
                    ((failed++))
                    ;;
            esac
        done
        
        echo ""
        echo "Montés: $mounted | Déjà montés: $already_mounted | Échecs: $failed"
        ;;
        
    3)
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║              DETACHEMENT VOLUMES                        ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        echo "⚠️  Tous les volumes seront détachés"
        read -p "Tapez 'DETACH': " confirm
        [ "$confirm" != "DETACH" ] && exit 0
        echo ""
        
        VOLS=$(hcloud volume list -o noheader -o columns=name 2>/dev/null)
        [ -z "$VOLS" ] && { warn "Aucun volume"; exit 0; }
        
        detached=0
        
        echo "$VOLS" | while read -r vol; do
            if hcloud volume detach "$vol" &>/dev/null; then
                ok "$vol détaché"
                ((detached++))
            else
                ko "$vol échec"
            fi
        done
        
        echo ""
        echo "Détachés: $detached"
        ;;
        
    4)
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║              SUPPRESSION VOLUMES                        ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        echo "⚠️  ⚠️  ⚠️  DANGER ⚠️  ⚠️  ⚠️"
        echo "Tous les volumes seront SUPPRIMES définitivement"
        echo "TOUTES LES DONNEES SERONT PERDUES"
        echo ""
        read -p "Tapez 'DELETE-ALL': " confirm
        [ "$confirm" != "DELETE-ALL" ] && exit 0
        echo ""
        
        VOLS=$(hcloud volume list -o noheader -o columns=name 2>/dev/null)
        [ -z "$VOLS" ] && { warn "Aucun volume"; exit 0; }
        
        echo "Détachement..."
        echo "$VOLS" | while read -r vol; do
            hcloud volume detach "$vol" &>/dev/null || true
        done
        
        sleep 3
        
        deleted=0
        
        echo "Suppression..."
        echo "$VOLS" | while read -r vol; do
            if hcloud volume delete "$vol" &>/dev/null; then
                ok "$vol supprimé"
                ((deleted++))
            else
                ko "$vol échec"
            fi
        done
        
        echo ""
        echo "Supprimés: $deleted"
        ;;
        
    *)
        ko "Choix invalide"
        exit 1
        ;;
esac

echo ""
