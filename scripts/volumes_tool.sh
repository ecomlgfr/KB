#!/usr/bin/env bash
set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok() { echo -e "${GREEN}✓${NC} $*"; }
ko() { echo -e "${RED}✗${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
info() { echo -e "${CYAN}ℹ${NC} $*"; }

cat << 'EOF'
╔════════════════════════════════════════════════════════════════════╗
║    GESTION VOLUMES HETZNER - KEYBUZZ v5.0 OPTIMIZED (XFS)          ║
╚════════════════════════════════════════════════════════════════════╝
EOF

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
LOG_FILE="$LOG_DIR/volumes_tool.log"
STATE_DIR="/opt/keybuzz/volumes/status"
STATE_FILE="$STATE_DIR/STATE"
SSH_KEY="/root/.ssh/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ConnectionAttempts=2"
AUTO_YES=false
FORCE_DELETE=false

# Locations Hetzner disponibles (ordre de préférence pour EU)
LOCATIONS_EU=("fsn1" "nbg1" "hel1")
LOCATIONS_US=("ash" "hil")
LOCATIONS_ASIA=("sin")
ALL_LOCATIONS=("${LOCATIONS_EU[@]}" "${LOCATIONS_US[@]}" "${LOCATIONS_ASIA[@]}")

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

test_ssh() {
    local host=$1
    local ip=$2
    timeout 10 ssh $SSH_OPTS -i "$SSH_KEY" root@"$ip" "echo 1" &>/dev/null
    return $?
}

# Obtenir la location préférée d'un serveur
get_server_preferred_location() {
    local hostname=$1
    local server_info datacenter location
    
    server_info=$(hcloud server describe "$hostname" -o json 2>/dev/null)
    
    if [[ -z "$server_info" || "$server_info" == "null" ]]; then
        echo "fsn1"  # Default
        return
    fi
    
    # Obtenir la location actuelle du serveur
    location=$(echo "$server_info" | jq -r '.datacenter.location.name')
    
    if [[ -n "$location" && "$location" != "null" ]]; then
        echo "$location"
    else
        echo "fsn1"  # Default
    fi
}

# Créer un volume avec retry sur différentes locations
create_volume_with_retry() {
    local vol_name=$1
    local size=$2
    local preferred_location=$3
    
    # D'abord essayer la location préférée
    if hcloud volume create --name "$vol_name" --size "$size" --location "$preferred_location" &>/dev/null; then
        ok "$vol_name créé (${size}GB @ $preferred_location)"
        return 0
    fi
    
    # Si échec, essayer les autres locations EU dans l'ordre
    for loc in "${LOCATIONS_EU[@]}"; do
        if [[ "$loc" == "$preferred_location" ]]; then
            continue  # Déjà essayé
        fi
        
        if hcloud volume create --name "$vol_name" --size "$size" --location "$loc" &>/dev/null; then
            warn "$vol_name créé @ $loc (au lieu de $preferred_location)"
            return 0
        fi
    done
    
    # En dernier recours, essayer US
    for loc in "${LOCATIONS_US[@]}"; do
        if hcloud volume create --name "$vol_name" --size "$size" --location "$loc" &>/dev/null; then
            warn "$vol_name créé @ $loc US (fallback)"
            return 0
        fi
    done
    
    ko "$vol_name échec création (toutes locations)"
    return 1
}

get_volume_config() {
    local hostname=$1
    local size mount_path
    
    # EXCLUSIONS - Pas de volumes pour ces serveurs
    case "$hostname" in
        k3s-master-*|mail-mx-*|dev-aio-*|install-*)
            return 1  # Skip
            ;;
    esac
    
    # Configuration des volumes par type de serveur
    case "$hostname" in
        # Database
        db-master-*) size=100; mount_path="/opt/keybuzz/postgres/data" ;;
        db-slave-*) size=50; mount_path="/opt/keybuzz/postgres/data" ;;
        
        # HAProxy
        haproxy-*) size=10; mount_path="/opt/keybuzz/haproxy/data" ;;
        
        # Redis
        redis-*) size=20; mount_path="/opt/keybuzz/redis/data" ;;
        
        # Queue
        queue-*) size=40; mount_path="/opt/keybuzz/rabbitmq/data" ;;
        
        # Storage
        minio-*) size=100; mount_path="/opt/keybuzz/minio/data" ;;
        backup-*) size=200; mount_path="/opt/keybuzz/backup/data" ;;
        
        # K3s Workers (ont des volumes)
        k3s-worker-*) size=50; mount_path="/var/lib/containerd" ;;
        
        # Monitoring & Security
        monitor-*) size=100; mount_path="/opt/keybuzz/monitor/data" ;;
        vault-*) size=20; mount_path="/opt/keybuzz/vault/data" ;;
        siem-*) size=200; mount_path="/opt/keybuzz/siem/data" ;;
        
        # Services
        vector-db-*) size=50; mount_path="/opt/keybuzz/qdrant/data" ;;
        temporal-db-*) size=50; mount_path="/opt/keybuzz/temporal-db/data" ;;
        temporal-*) size=20; mount_path="/opt/keybuzz/temporal/data" ;;
        analytics-db-*) size=100; mount_path="/opt/keybuzz/analytics-db/data" ;;
        analytics-*) size=20; mount_path="/opt/keybuzz/analytics/data" ;;
        mail-core-*) size=50; mount_path="/opt/keybuzz/mail/data" ;;
        
        # Apps
        python-api-*) size=20; mount_path="/opt/keybuzz/api/data" ;;
        billing-*) size=20; mount_path="/opt/keybuzz/billing/data" ;;
        api-gateway-*) size=10; mount_path="/opt/keybuzz/gateway/data" ;;
        litellm-*) size=20; mount_path="/opt/keybuzz/litellm/data" ;;
        etl-*) size=50; mount_path="/opt/keybuzz/airbyte/data" ;;
        baserow-*) size=20; mount_path="/opt/keybuzz/baserow/data" ;;
        nocodb-*) size=20; mount_path="/opt/keybuzz/nocodb/data" ;;
        ml-platform-*) size=50; mount_path="/opt/keybuzz/mlflow/data" ;;
        n8n-*) size=20; mount_path="/opt/keybuzz/n8n/data" ;;
        
        *) 
            return 1  # Serveur inconnu ou pas de volume
            ;;
    esac
    
    echo "$size|$mount_path"
}

load_servers() {
    if [[ ! -f "$INVENTORY_TSV" ]]; then
        ko "Fichier servers.tsv introuvable: $INVENTORY_TSV"
        exit 1
    fi
    
    local filter_pattern=${1:-}
    local filter_host=${2:-}
    
    while IFS=$'\t' read -r ip_pub hostname ip_wg fqdn user_ssh group; do
        [[ "$ip_pub" =~ ^# || -z "$ip_pub" ]] && continue
        [[ "$ip_pub" == "IP_PUBLIQUE" || "$hostname" == "HOSTNAME" ]] && continue
        
        if [[ -n "$filter_pattern" && ! "$hostname" =~ $filter_pattern ]]; then
            continue
        fi
        
        if [[ -n "$filter_host" && "$hostname" != "$filter_host" ]]; then
            continue
        fi
        
        local config
        config=$(get_volume_config "$hostname") || continue
        
        local size mount_path
        IFS='|' read -r size mount_path <<< "$config"
        
        echo "$hostname|$ip_pub|$ip_wg|$size|$mount_path"
    done < "$INVENTORY_TSV"
}

create_volumes() {
    log "Création optimisée des volumes Hetzner"
    
    local servers failed=0 created=0 skipped=0
    mapfile -t servers < <(load_servers "$FILTER_PATTERN" "$FILTER_HOST")
    
    [[ ${#servers[@]} -eq 0 ]] && { ko "Aucun serveur nécessitant un volume trouvé"; return 1; }
    
    info "Création de ${#servers[@]} volumes avec retry intelligent..."
    echo ""
    
    # Grouper par location préférée pour optimiser
    declare -A volumes_by_location
    
    for server_line in "${servers[@]}"; do
        IFS='|' read -r hostname ip_pub ip_wg size mount_path <<< "$server_line"
        local vol_name="vol-$hostname"
        
        # Vérifier si le serveur existe
        if ! hcloud server describe "$hostname" &>/dev/null; then
            warn "$hostname - serveur inexistant, skip"
            ((skipped++))
            continue
        fi
        
        # Vérifier si le volume existe déjà
        if hcloud volume describe "$vol_name" &>/dev/null; then
            warn "$vol_name existe déjà"
            ((skipped++))
            continue
        fi
        
        # Obtenir la location préférée
        local preferred_location
        preferred_location=$(get_server_preferred_location "$hostname")
        
        # Créer le volume avec retry
        if create_volume_with_retry "$vol_name" "$size" "$preferred_location"; then
            ((created++))
        else
            ((failed++))
        fi
        
        # Pause courte pour éviter rate limiting
        sleep 0.5
    done
    
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "Résumé: $created créés | $skipped existants | $failed échecs"
    echo "════════════════════════════════════════════════════════════════════"
    
    [[ $failed -gt 0 ]] && { ko "Il y a eu $failed échecs"; return 1; }
    ok "Création terminée avec succès"
}

attach_volumes() {
    log "Attachement des volumes aux serveurs"
    
    local servers failed=0 attached=0 skipped=0
    mapfile -t servers < <(load_servers "$FILTER_PATTERN" "$FILTER_HOST")
    
    [[ ${#servers[@]} -eq 0 ]] && { ko "Aucun serveur trouvé"; return 1; }
    
    info "Attachement de ${#servers[@]} volumes..."
    echo ""
    
    for server_line in "${servers[@]}"; do
        IFS='|' read -r hostname ip_pub ip_wg size mount_path <<< "$server_line"
        local vol_name="vol-$hostname"
        
        # Vérifier si le volume existe
        if ! hcloud volume describe "$vol_name" &>/dev/null; then
            warn "$vol_name n'existe pas, skip"
            ((skipped++))
            continue
        fi
        
        # Vérifier si déjà attaché
        local current_server
        current_server=$(hcloud volume describe "$vol_name" -o json 2>/dev/null | jq -r '.server')
        
        if [[ -n "$current_server" && "$current_server" != "null" ]]; then
            warn "$vol_name déjà attaché"
            ((skipped++))
        else
            if hcloud volume attach "$vol_name" --server "$hostname" 2>/dev/null; then
                ok "$vol_name attaché → $hostname"
                ((attached++))
                sleep 2
            else
                ko "$vol_name échec attachement"
                ((failed++))
            fi
        fi
    done
    
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "Résumé: $attached attachés | $skipped déjà attachés | $failed échecs"
    echo "════════════════════════════════════════════════════════════════════"
    
    [[ $failed -gt 0 ]] && { ko "Il y a eu $failed échecs"; return 1; }
    ok "Attachement terminé avec succès"
}

mount_volumes() {
    log "Montage des volumes XFS sur les serveurs"
    
    local servers failed=0 mounted=0 skipped=0
    mapfile -t servers < <(load_servers "$FILTER_PATTERN" "$FILTER_HOST")
    
    [[ ${#servers[@]} -eq 0 ]] && { ko "Aucun serveur trouvé"; return 1; }
    
    info "Montage de ${#servers[@]} volumes en XFS..."
    echo ""
    
    for server_line in "${servers[@]}"; do
        IFS='|' read -r hostname ip_pub ip_wg size mount_path <<< "$server_line"
        
        if ! test_ssh "$hostname" "$ip_pub"; then
            ko "$hostname → erreur SSH"
            ((failed++))
            continue
        fi
        
        # Vérifier si déjà monté
        local is_mounted
        is_mounted=$(ssh $SSH_OPTS -i "$SSH_KEY" root@"$ip_pub" "mountpoint -q '$mount_path' && echo 1 || echo 0" 2>/dev/null)
        
        if [[ "$is_mounted" == "1" ]]; then
            warn "$hostname déjà monté"
            ((skipped++))
        else
            if ssh $SSH_OPTS -i "$SSH_KEY" root@"$ip_pub" "
                # Installation XFS si nécessaire
                if ! command -v mkfs.xfs &>/dev/null; then
                    apt-get update -qq && apt-get install -y -qq xfsprogs
                fi
                
                mkdir -p '$mount_path'
                
                # Détection automatique du device
                DEVICE=\$(ls -1 /dev/disk/by-id/scsi-* 2>/dev/null | grep -v part | head -1 | xargs readlink -f 2>/dev/null)
                
                if [ -z \"\$DEVICE\" ]; then
                    TARGET_SIZE=\$((${size} * 1000000000))
                    TOLERANCE=\$((TARGET_SIZE / 10))
                    for dev in /dev/sd{b..z} /dev/vd{b..z}; do
                        [ -b \"\$dev\" ] || continue
                        DEV_SIZE=\$(lsblk -b -n -o SIZE \"\$dev\" 2>/dev/null | head -1)
                        [ -z \"\$DEV_SIZE\" ] && continue
                        if [ \$DEV_SIZE -gt \$((TARGET_SIZE - TOLERANCE)) ] && [ \$DEV_SIZE -lt \$((TARGET_SIZE + TOLERANCE)) ]; then
                            mount | grep -q \"\$dev\" || { DEVICE=\"\$dev\"; break; }
                        fi
                    done
                fi
                
                [ -z \"\$DEVICE\" ] && { echo 'KO: aucun device trouvé' >&2; exit 1; }
                
                # FORMATAGE EN XFS
                if ! blkid \"\$DEVICE\" 2>/dev/null | grep -q 'TYPE=\"xfs\"'; then
                    wipefs -af \"\$DEVICE\" 2>/dev/null
                    mkfs.xfs -f \"\$DEVICE\" &>/dev/null || exit 1
                fi
                
                # Montage XFS avec options optimisées
                mount -t xfs -o noatime,nodiratime,logbufs=8,logbsize=256k \"\$DEVICE\" '$mount_path' 2>/dev/null || exit 1
                
                UUID=\$(blkid -s UUID -o value \"\$DEVICE\")
                if ! grep -q \"\$UUID\" /etc/fstab; then
                    echo \"UUID=\$UUID $mount_path xfs defaults,noatime,nodiratime,logbufs=8,logbsize=256k,nofail 0 2\" >> /etc/fstab
                fi
                
                chown -R 999:999 '$mount_path' 2>/dev/null || true
            "; then
                ok "$hostname monté (XFS)"
                ((mounted++))
            else
                ko "$hostname échec montage"
                ((failed++))
            fi
        fi
    done
    
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "Résumé: $mounted montés | $skipped déjà montés | $failed échecs"
    echo "════════════════════════════════════════════════════════════════════"
    
    [[ $failed -gt 0 ]] && { ko "Il y a eu $failed échecs"; return 1; }
    ok "Montage terminé avec succès"
}

delete_volumes() {
    log "Suppression des volumes Hetzner"
    
    local servers
    mapfile -t servers < <(load_servers "$FILTER_PATTERN" "$FILTER_HOST")
    
    [[ ${#servers[@]} -eq 0 ]] && { ko "Aucun serveur trouvé"; return 1; }
    
    if [[ "$FORCE_DELETE" != "true" && "$AUTO_YES" != "true" ]]; then
        echo ""
        warn "ATTENTION: Cette action va SUPPRIMER définitivement les volumes suivants:"
        echo ""
        for server_line in "${servers[@]}"; do
            IFS='|' read -r hostname ip_pub ip_wg size mount_path <<< "$server_line"
            echo "  • vol-$hostname (${size}GB)"
        done
        echo ""
        read -p "Tapez 'DELETE' pour confirmer la suppression: " confirm
        [[ "$confirm" != "DELETE" ]] && { warn "Suppression annulée"; return 1; }
    fi
    
    local failed=0 deleted=0 skipped=0
    echo ""
    info "Suppression des volumes..."
    
    for server_line in "${servers[@]}"; do
        IFS='|' read -r hostname ip_pub ip_wg size mount_path <<< "$server_line"
        local vol_name="vol-$hostname"
        
        # Vérifier si le volume existe
        if ! hcloud volume describe "$vol_name" &>/dev/null; then
            warn "$vol_name n'existe pas"
            ((skipped++))
            continue
        fi
        
        # Détacher le volume s'il est attaché
        local attached
        attached=$(hcloud volume describe "$vol_name" -o json 2>/dev/null | jq -r '.server')
        if [[ -n "$attached" && "$attached" != "null" ]]; then
            info "Détachement de $vol_name..."
            if ! hcloud volume detach "$vol_name" &>/dev/null; then
                ko "$vol_name échec détachement"
                ((failed++))
                continue
            fi
            sleep 2
        fi
        
        # Supprimer le volume
        if hcloud volume delete "$vol_name" &>/dev/null; then
            ok "$vol_name supprimé"
            ((deleted++))
        else
            ko "$vol_name échec suppression"
            ((failed++))
        fi
    done
    
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "Résumé: $deleted supprimés | $skipped inexistants | $failed échecs"
    echo "════════════════════════════════════════════════════════════════════"
    
    [[ $failed -gt 0 ]] && { ko "Il y a eu $failed échecs"; return 1; }
    ok "Suppression terminée avec succès"
}

check_status() {
    log "Vérification de l'état des volumes"
    
    echo ""
    echo "SERVEURS EXCLUS (pas de volumes par design):"
    echo "════════════════════════════════════════════════════════════════════"
    echo "• k3s-master-01, k3s-master-02, k3s-master-03"
    echo "• mail-mx-01, mail-mx-02"
    echo "• dev-aio-01"
    echo "• install-01"
    echo ""
    
    local servers total=0 created=0 attached=0 mounted=0
    mapfile -t servers < <(load_servers)
    total=${#servers[@]}
    
    echo "SERVEURS AVEC VOLUMES:"
    echo "════════════════════════════════════════════════════════════════════"
    printf "%-20s %-10s %-10s %-10s %-8s %-10s\n" "SERVEUR" "VOLUME" "ATTACHÉ" "MONTÉ" "FORMAT" "LOCATION"
    echo "────────────────────────────────────────────────────────────────────"
    
    for server_line in "${servers[@]}"; do
        IFS='|' read -r hostname ip_pub ip_wg size mount_path <<< "$server_line"
        local vol_name="vol-$hostname"
        
        local vol_status="KO" attach_status="KO" mount_status="KO" fs_type="-" location="-"
        
        if hcloud volume describe "$vol_name" &>/dev/null; then
            vol_status="OK"
            ((created++))
            
            # Récupérer la location du volume
            location=$(hcloud volume describe "$vol_name" -o json 2>/dev/null | jq -r '.location.name')
            
            local attached
            attached=$(hcloud volume describe "$vol_name" -o json 2>/dev/null | jq -r '.server')
            if [[ -n "$attached" && "$attached" != "null" ]]; then
                attach_status="OK"
                ((attached++))
            fi
        fi
        
        if test_ssh "$hostname" "$ip_pub" 2>/dev/null; then
            local is_mounted
            is_mounted=$(ssh $SSH_OPTS -i "$SSH_KEY" root@"$ip_pub" "mountpoint -q '$mount_path' && echo 1 || echo 0" 2>/dev/null)
            if [[ "$is_mounted" == "1" ]]; then
                mount_status="OK"
                ((mounted++))
                # Vérifier le type de filesystem
                fs_type=$(ssh $SSH_OPTS -i "$SSH_KEY" root@"$ip_pub" "df -T '$mount_path' | tail -1 | awk '{print \$2}'" 2>/dev/null)
            fi
        fi
        
        printf "%-20s %-10s %-10s %-10s %-8s %-10s\n" "$hostname" "$vol_status" "$attach_status" "$mount_status" "$fs_type" "$location"
    done
    
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "RÉSUMÉ: $created/$total volumes créés | $attached/$total attachés | $mounted/$total montés"
    echo ""
    
    if [[ $created -eq $total && $attached -eq $total && $mounted -eq $total ]]; then
        echo "OK" > "$STATE_FILE"
        ok "Infrastructure volumes prête !"
    else
        echo "INCOMPLETE" > "$STATE_FILE"
        warn "Infrastructure volumes incomplète"
    fi
}

list_volumes() {
    log "Liste des volumes Hetzner"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    printf "%-25s %-10s %-20s %-10s\n" "VOLUME" "TAILLE" "SERVEUR" "LOCATION"
    echo "────────────────────────────────────────────────────────────────────"
    
    hcloud volume list -o json | jq -r '.[] | "\(.name)|\(.size)|\(.server // "non-attaché")|\(.location.name)"' | while IFS='|' read -r name size server loc; do
        printf "%-25s %-10sGB %-20s %-10s\n" "$name" "$size" "$server" "$loc"
    done
    
    echo "════════════════════════════════════════════════════════════════════"
    
    # Statistiques par location
    echo ""
    echo "VOLUMES PAR LOCATION:"
    echo "────────────────────────────────────────────────────────────────────"
    for loc in "${ALL_LOCATIONS[@]}"; do
        count=$(hcloud volume list -o json | jq -r --arg loc "$loc" '[.[] | select(.location.name == $loc)] | length')
        if [[ $count -gt 0 ]]; then
            echo "  $loc: $count volumes"
        fi
    done
}

# ═════════════════ MAIN ═════════════════

MODE=""
FILTER_PATTERN=""
FILTER_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --pool) FILTER_PATTERN="$2"; shift 2 ;;
        --host) FILTER_HOST="$2"; shift 2 ;;
        --yes) AUTO_YES=true; shift ;;
        --force) FORCE_DELETE=true; shift ;;
        -h|--help)
            echo "Usage: $0 --mode <action> [options]"
            echo ""
            echo "Actions:"
            echo "  create  - Créer les volumes (avec retry intelligent)"
            echo "  attach  - Attacher les volumes aux serveurs"
            echo "  mount   - Monter les volumes en XFS"
            echo "  delete  - Supprimer les volumes"
            echo "  check   - Vérifier l'état des volumes"
            echo "  list    - Lister tous les volumes"
            echo ""
            echo "Options:"
            echo "  --pool <pattern>  - Filtrer par pattern (ex: db-*, redis-*)"
            echo "  --host <n>        - Traiter un seul serveur"
            echo "  --yes             - Mode automatique (pas de confirmation)"
            echo "  --force           - Force la suppression sans confirmation"
            echo ""
            echo "Locations disponibles: fsn1, nbg1, hel1, ash, hil, sin"
            echo ""
            echo "Serveurs EXCLUS (pas de volumes):"
            echo "  • k3s-master-*"
            echo "  • mail-mx-*"
            echo "  • dev-aio-*"
            echo "  • install-*"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ -n "$MODE" ]]; then
    [[ -z "${HCLOUD_TOKEN:-}" ]] && { ko "HCLOUD_TOKEN non configuré"; exit 1; }
    
    # Vérifier les outils nécessaires
    if ! command -v hcloud &>/dev/null; then
        ko "hcloud CLI non installé"
        exit 1
    fi
    
    if ! command -v jq &>/dev/null; then
        warn "jq non installé, installation..."
        apt-get update -qq && apt-get install -y -qq jq
    fi
    
    case "$MODE" in
        create) create_volumes ;;
        attach) attach_volumes ;;
        mount) mount_volumes ;;
        delete) delete_volumes ;;
        check) check_status ;;
        list) list_volumes ;;
        *) ko "Mode inconnu: $MODE"; exit 1 ;;
    esac
    
    echo ""
    ok "Opération '$MODE' terminée"
    echo "Logs: $LOG_FILE"
else
    ko "Aucun mode spécifié. Utilisez --help pour l'aide"
    exit 1
fi
