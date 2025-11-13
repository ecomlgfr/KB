#!/usr/bin/env bash
# reset_parallel_safe.sh - SAFE parallel reset using ONLY servers.tsv
# This version ONLY rebuilds servers listed in servers.tsv, NOT all Hetzner servers!

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
SERVERS_TSV="${SERVERS_TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
LOG_DIR="${LOG_DIR:-/opt/keybuzz-installer/logs}"
DRY_RUN=false
FORCE=false
ACTION=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --rebuild)
            ACTION="rebuild"
            ;;
        --force)
            FORCE=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --help)
            echo "Usage: $0 --rebuild [--force] [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --rebuild   Rebuild ONLY servers from servers.tsv"
            echo "  --force     Skip confirmation"
            echo "  --dry-run   Test mode (don't actually rebuild)"
            echo ""
            echo "IMPORTANT: Only rebuilds servers listed in:"
            echo "  $SERVERS_TSV"
            echo ""
            echo "Example:"
            echo "  $0 --rebuild --force"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
    shift
done

# Header
clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   KeyBuzz SAFE Parallel Reset (servers.tsv ONLY)     ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${MAGENTA}⚠️  This version ONLY rebuilds servers from servers.tsv${NC}"
echo -e "${MAGENTA}   Other servers are NOT touched${NC}"
echo

# Check action
if [[ -z "$ACTION" ]]; then
    echo -e "${RED}Error: No action specified${NC}"
    echo "Use: $0 --rebuild [--force]"
    exit 1
fi

# Check servers.tsv exists
if [[ ! -f "$SERVERS_TSV" ]]; then
    echo -e "${RED}Error: servers.tsv not found at $SERVERS_TSV${NC}"
    exit 1
fi

# Check hcloud
if ! command -v hcloud >/dev/null 2>&1; then
    echo -e "${RED}Error: hcloud CLI not found${NC}"
    exit 1
fi

# Check token
if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
    echo -e "${RED}Error: HCLOUD_TOKEN not set${NC}"
    exit 1
fi

# ========================================
# EXTRACT SERVER LIST FROM servers.tsv
# ========================================
echo "Reading server list from servers.tsv..."
echo "File: $SERVERS_TSV"
echo

# Parse servers.tsv to get hostnames
declare -a TSV_HOSTNAMES=()
declare -a TSV_IPS=()

while IFS=$'\t' read -r ip hostname wg_ip fqdn ssh_user || [[ -n "$ip" ]]; do
    # Skip comments and header
    if [[ "$ip" =~ ^#.*$ ]] || [[ "$ip" == "PUBLIC_IP" ]]; then
        continue
    fi
    
    # Skip empty lines
    if [[ -z "$ip" ]] || [[ -z "$hostname" ]]; then
        continue
    fi
    
    TSV_HOSTNAMES+=("$hostname")
    TSV_IPS+=("$ip")
done < "$SERVERS_TSV"

echo "Found ${#TSV_HOSTNAMES[@]} servers in servers.tsv:"
for i in "${!TSV_HOSTNAMES[@]}"; do
    echo "  ${TSV_HOSTNAMES[$i]} (${TSV_IPS[$i]})"
done
echo

# ========================================
# MATCH WITH HETZNER SERVERS
# ========================================
echo "Matching with Hetzner Cloud servers..."

# Get all Hetzner servers
declare -a HETZNER_SERVERS=()
while IFS= read -r line; do
    server_name=$(echo "$line" | awk '{print $2}')
    HETZNER_SERVERS+=("$server_name")
done < <(hcloud server list -o noheader)

# Find servers to rebuild (intersection of TSV and Hetzner)
declare -a SERVERS_TO_REBUILD=()
declare -a SERVERS_NOT_FOUND=()

for tsv_hostname in "${TSV_HOSTNAMES[@]}"; do
    found=false
    for hetzner_name in "${HETZNER_SERVERS[@]}"; do
        if [[ "$tsv_hostname" == "$hetzner_name" ]]; then
            SERVERS_TO_REBUILD+=("$tsv_hostname")
            found=true
            break
        fi
    done
    
    if [[ "$found" == "false" ]]; then
        SERVERS_NOT_FOUND+=("$tsv_hostname")
    fi
done

echo
echo -e "${GREEN}Servers to rebuild (${#SERVERS_TO_REBUILD[@]}):${NC}"
for server in "${SERVERS_TO_REBUILD[@]}"; do
    echo "  ✓ $server"
done

if [[ ${#SERVERS_NOT_FOUND[@]} -gt 0 ]]; then
    echo
    echo -e "${YELLOW}Servers in TSV but NOT in Hetzner (${#SERVERS_NOT_FOUND[@]}):${NC}"
    for server in "${SERVERS_NOT_FOUND[@]}"; do
        echo "  ✗ $server"
    done
fi

# Check if there are Hetzner servers NOT in TSV (these will be SAFE)
declare -a SERVERS_SAFE=()
for hetzner_name in "${HETZNER_SERVERS[@]}"; do
    found=false
    for tsv_hostname in "${TSV_HOSTNAMES[@]}"; do
        if [[ "$hetzner_name" == "$tsv_hostname" ]]; then
            found=true
            break
        fi
    done
    
    if [[ "$found" == "false" ]]; then
        SERVERS_SAFE+=("$hetzner_name")
    fi
done

if [[ ${#SERVERS_SAFE[@]} -gt 0 ]]; then
    echo
    echo -e "${CYAN}Servers in Hetzner but NOT in TSV (WILL BE KEPT SAFE):${NC}"
    for server in "${SERVERS_SAFE[@]}"; do
        echo "  🛡️  $server - PROTECTED"
    done
fi

echo

# Check if we have servers to rebuild
if [[ ${#SERVERS_TO_REBUILD[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No servers to rebuild${NC}"
    exit 0
fi

# Dry run mode
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${BLUE}DRY RUN MODE - No changes will be made${NC}"
    echo
    echo "Would rebuild ${#SERVERS_TO_REBUILD[@]} servers from servers.tsv"
    echo "Would keep ${#SERVERS_SAFE[@]} other servers safe"
    exit 0
fi

# Confirmation
if [[ "$FORCE" != "true" ]]; then
    echo -e "${RED}════════════════════════════════════════${NC}"
    echo -e "${RED}         ⚠️  WARNING ⚠️${NC}"
    echo -e "${RED}════════════════════════════════════════${NC}"
    echo
    echo "This will REBUILD ${#SERVERS_TO_REBUILD[@]} servers from servers.tsv"
    echo "ALL DATA ON THESE SERVERS WILL BE LOST!"
    echo
    echo -e "${GREEN}These ${#SERVERS_SAFE[@]} servers will be KEPT SAFE:${NC}"
    for server in "${SERVERS_SAFE[@]}"; do
        echo "  • $server"
    done
    echo
    read -rp "Type 'yes' to confirm rebuild of TSV servers only: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted"
        exit 1
    fi
fi

# Create log directory
mkdir -p "$LOG_DIR"
REBUILD_LOG="$LOG_DIR/rebuild_safe_$(date +%Y%m%d_%H%M%S).log"

echo "Starting SAFE parallel rebuild at $(date)" | tee "$REBUILD_LOG"
echo "Rebuilding ONLY servers from servers.tsv" | tee -a "$REBUILD_LOG"
echo

# ========================================
# PHASE 1: Launch rebuilds for TSV servers only
# ========================================
echo -e "${BLUE}[Phase 1/3] Launching rebuilds for servers.tsv servers ONLY...${NC}"
echo

START_TIME=$(date +%s)
REBUILD_PIDS=()
FAILED_SERVERS=()

# Get the image ID (Ubuntu 24.04)
IMAGE_ID=$(hcloud image list -o noheader | grep -i "ubuntu-24.04" | head -1 | awk '{print $1}')
if [[ -z "$IMAGE_ID" ]]; then
    echo -e "${RED}Error: Ubuntu 24.04 image not found${NC}"
    exit 1
fi

# Function to rebuild one server
rebuild_server() {
    local server_name="$1"
    local log_file="$LOG_DIR/.rebuild_${server_name}.log"
    
    echo "[$(date +%H:%M:%S)] Starting rebuild: $server_name" >> "$log_file"
    
    # Get server ID
    local server_id=$(hcloud server list -o noheader | grep -w "$server_name" | awk '{print $1}')
    
    if [[ -z "$server_id" ]]; then
        echo "ERROR: Server $server_name not found in Hetzner" >> "$log_file"
        return 1
    fi
    
    # Rebuild the server
    if hcloud server rebuild "$server_id" --image "$IMAGE_ID" >> "$log_file" 2>&1; then
        echo "[$(date +%H:%M:%S)] Rebuild initiated: $server_name" >> "$log_file"
        return 0
    else
        echo "ERROR: Failed to rebuild $server_name" >> "$log_file"
        return 1
    fi
}

# Export function for background jobs
export -f rebuild_server
export LOG_DIR IMAGE_ID

# Launch rebuilds ONLY for servers in TSV
for server in "${SERVERS_TO_REBUILD[@]}"; do
    echo -n "  Launching rebuild for $server... "
    
    # Start rebuild in background
    rebuild_server "$server" &
    pid=$!
    REBUILD_PIDS+=($pid)
    
    echo -e "${GREEN}[PID: $pid]${NC}"
    
    # Small delay to avoid API rate limiting
    sleep 0.2
done

echo
echo -e "${GREEN}Launched ${#SERVERS_TO_REBUILD[@]} rebuilds (servers.tsv only)${NC}"
echo -e "${CYAN}Protected ${#SERVERS_SAFE[@]} other servers${NC}"
echo

# ========================================
# PHASE 2: Wait for rebuilds to complete
# ========================================
echo -e "${BLUE}[Phase 2/3] Waiting for rebuilds to complete...${NC}"
echo "This typically takes 2-3 minutes..."
echo

# Show progress
show_progress() {
    local elapsed=$1
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    printf "\rElapsed: %02d:%02d | Active rebuilds: %d/%d  " $mins $secs $2 ${#SERVERS_TO_REBUILD[@]}
}

# Wait for all background jobs
ACTIVE_COUNT=${#REBUILD_PIDS[@]}
while [[ $ACTIVE_COUNT -gt 0 ]]; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    # Count active jobs
    ACTIVE_COUNT=0
    for pid in "${REBUILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            ((ACTIVE_COUNT++))
        fi
    done
    
    show_progress $ELAPSED $ACTIVE_COUNT
    
    if [[ $ACTIVE_COUNT -gt 0 ]]; then
        sleep 2
    fi
done

echo
echo

# Check results
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_LIST=()

for server in "${SERVERS_TO_REBUILD[@]}"; do
    log_file="$LOG_DIR/.rebuild_${server}.log"
    if grep -q "ERROR:" "$log_file" 2>/dev/null; then
        FAILED_LIST+=("$server")
        ((FAIL_COUNT++))
        echo -e "  ${RED}✗${NC} $server - FAILED"
    else
        ((SUCCESS_COUNT++))
        echo -e "  ${GREEN}✓${NC} $server - Rebuild initiated"
    fi
done

echo
echo "Rebuild Status: Success=$SUCCESS_COUNT, Failed=$FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}Failed servers:${NC}"
    for server in "${FAILED_LIST[@]}"; do
        echo "  - $server"
    done
fi

echo

# ========================================
# PHASE 3: Wait for TSV servers to boot
# ========================================
echo -e "${BLUE}[Phase 3/3] Waiting for rebuilt servers to boot...${NC}"
echo "Checking status of servers.tsv servers only..."
echo

MAX_WAIT=300  # 5 minutes max
WAIT_TIME=0
ALL_RUNNING=false

while [[ $WAIT_TIME -lt $MAX_WAIT ]] && [[ "$ALL_RUNNING" == "false" ]]; do
    RUNNING_COUNT=0
    
    # Check each TSV server status
    for server in "${SERVERS_TO_REBUILD[@]}"; do
        status=$(hcloud server list -o noheader | grep -w "$server" | awk '{print $4}')
        if [[ "$status" == "running" ]]; then
            ((RUNNING_COUNT++))
        fi
    done
    
    printf "\rTSV servers running: %d/%d  " $RUNNING_COUNT ${#SERVERS_TO_REBUILD[@]}
    
    if [[ $RUNNING_COUNT -eq ${#SERVERS_TO_REBUILD[@]} ]]; then
        ALL_RUNNING=true
        echo
        echo -e "${GREEN}All TSV servers are running!${NC}"
    else
        sleep 10
        ((WAIT_TIME+=10))
    fi
done

if [[ "$ALL_RUNNING" == "false" ]]; then
    echo
    echo -e "${YELLOW}Warning: Not all TSV servers are running after ${MAX_WAIT} seconds${NC}"
fi

echo

# ========================================
# Final Summary
# ========================================
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_MINS=$((TOTAL_TIME / 60))
TOTAL_SECS=$((TOTAL_TIME % 60))

echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}      SAFE Rebuild Complete${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo
echo "Summary:"
echo "  • TSV servers rebuilt: $SUCCESS_COUNT"
echo "  • TSV servers failed: $FAIL_COUNT"
echo "  • Other servers protected: ${#SERVERS_SAFE[@]}"
echo "  • Total time: ${TOTAL_MINS}m ${TOTAL_SECS}s"
echo
echo "Log file: $REBUILD_LOG"
echo

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${GREEN}✓ All TSV servers successfully rebuilt!${NC}"
else
    echo -e "${YELLOW}⚠ Some TSV servers failed to rebuild${NC}"
fi

echo
echo -e "${CYAN}Protected servers (not touched):${NC}"
for server in "${SERVERS_SAFE[@]}"; do
    echo "  🛡️  $server"
done

echo
echo "Next steps:"
echo "1. Wait 1-2 minutes for SSH to be ready"
echo "2. Run Windows script to deploy SSH keys"
echo "3. Run: ./kb_master_install.sh"
echo

# Cleanup temp logs
rm -f "$LOG_DIR"/.rebuild_*.log 2>/dev/null

exit 0
