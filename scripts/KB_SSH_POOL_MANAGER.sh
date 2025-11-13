#!/usr/bin/env bash
set -u
set -o pipefail

# KB_SSH_POOL_MANAGER.sh - Gestion intelligente des pools et interconnexions SSH
# Version Production - Lecture dynamique de servers.tsv

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
INSTALL_01_IP="91.98.128.153"

echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     KeyBuzz SSH Pool Manager - Production Ready      ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo

# Vérifier servers.tsv
if [ ! -f "$SERVERS_TSV" ]; then
    echo -e "${RED}✗ Fichier $SERVERS_TSV introuvable${NC}"
    exit 1
fi

# Parser servers.tsv et détecter les pools
declare -A POOLS
declare -A SERVER_INFO

echo -e "${YELLOW}Analyse de l'infrastructure...${NC}"
while IFS=$'\t' read -r ip hostname wg_ip fqdn user pool; do
    # Skip comments and header
    [[ "$ip" =~ ^#.*$ ]] && continue
    [[ "$ip" == "IP_PUBLIQUE" ]] && continue
    
    if [ -n "$pool" ] && [ "$pool" != "POOL" ]; then
        # Ajouter au pool
        if [ -z "${POOLS[$pool]:-}" ]; then
            POOLS[$pool]="$hostname"
        else
            POOLS[$pool]="${POOLS[$pool]} $hostname"
        fi
        
        # Stocker les infos du serveur
        SERVER_INFO["${hostname}_ip"]="$ip"
        SERVER_INFO["${hostname}_wg"]="$wg_ip"
        SERVER_INFO["${hostname}_pool"]="$pool"
    fi
done < "$SERVERS_TSV"

# Afficher les pools détectés
echo -e "${GREEN}Pools détectés :${NC}"
for pool in "${!POOLS[@]}"; do
    count=$(echo "${POOLS[$pool]}" | wc -w)
    echo "  • $pool: $count serveurs"
done
echo

# Fonction pour configurer SSH sans interaction
configure_ssh_no_prompt() {
    local ip=$1
    local hostname=$2
    
    ssh -o BatchMode=yes -o ConnectTimeout=5 root@$ip << 'SSH_CONFIG' >/dev/null 2>&1
mkdir -p /root/.ssh
chmod 700 /root/.ssh

cat > /root/.ssh/config << 'EOF'
Host *
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /root/.ssh/known_hosts
    PasswordAuthentication no
    PubkeyAuthentication yes
    PreferredAuthentications publickey
    ConnectTimeout 10
    ServerAliveInterval 60
    ServerAliveCountMax 3
    LogLevel ERROR
EOF
chmod 600 /root/.ssh/config

# Générer clé si absente
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "$(hostname)" -q
fi
chmod 600 /root/.ssh/id_ed25519
chmod 644 /root/.ssh/id_ed25519.pub

> /root/.ssh/known_hosts
chmod 644 /root/.ssh/known_hosts
SSH_CONFIG
}

# Fonction pour interconnecter un pool
interconnect_pool() {
    local pool_name=$1
    local members="${POOLS[$pool_name]}"
    
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Pool: $pool_name${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    
    # Configurer SSH sur chaque membre
    echo -e "${YELLOW}[1/3] Configuration SSH...${NC}"
    for member in $members; do
        local ip="${SERVER_INFO[${member}_ip]}"
        echo -n "  $member: "
        if configure_ssh_no_prompt "$ip" "$member"; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    
    # Collecter les clés publiques
    echo -e "\n${YELLOW}[2/3] Collecte des clés...${NC}"
    declare -A PUBKEYS
    for member in $members; do
        local ip="${SERVER_INFO[${member}_ip]}"
        echo -n "  $member: "
        KEY=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@$ip "cat /root/.ssh/id_ed25519.pub 2>/dev/null")
        if [ -n "$KEY" ]; then
            PUBKEYS[$member]="$KEY"
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    
    # Distribuer les clés entre membres du pool
    echo -e "\n${YELLOW}[3/3] Distribution des clés dans le pool...${NC}"
    for source in $members; do
        local source_ip="${SERVER_INFO[${source}_ip]}"
        echo "  $source:"
        
        for target in $members; do
            [ "$source" == "$target" ] && continue
            
            local target_key="${PUBKEYS[$target]}"
            if [ -n "$target_key" ]; then
                echo -n "    → $target "
                
                # Ajouter la clé
                ssh -o BatchMode=yes -o ConnectTimeout=5 root@$source_ip \
                    "grep -qF '$target_key' /root/.ssh/authorized_keys 2>/dev/null || echo '$target_key' >> /root/.ssh/authorized_keys" 2>/dev/null
                
                # Scanner les fingerprints (IP publique + WireGuard)
                local target_ip="${SERVER_INFO[${target}_ip]}"
                local target_wg="${SERVER_INFO[${target}_wg]}"
                
                ssh -o BatchMode=yes -o ConnectTimeout=5 root@$source_ip << EOF >/dev/null 2>&1
ssh-keyscan -H $target_ip >> /root/.ssh/known_hosts 2>/dev/null
ssh-keyscan -H $target_wg >> /root/.ssh/known_hosts 2>/dev/null
ssh-keyscan -H $target >> /root/.ssh/known_hosts 2>/dev/null
sort -u /root/.ssh/known_hosts > /tmp/kh.tmp && mv /tmp/kh.tmp /root/.ssh/known_hosts
chmod 644 /root/.ssh/known_hosts
EOF
                echo -e "${GREEN}✓${NC}"
            fi
        done
    done
    
    # Test de connectivité
    echo -e "\n${YELLOW}Tests de connexion :${NC}"
    local test_ok=0
    local test_total=0
    
    for source in $members; do
        local source_ip="${SERVER_INFO[${source}_ip]}"
        for target in $members; do
            [ "$source" == "$target" ] && continue
            ((test_total++))
            
            local target_wg="${SERVER_INFO[${target}_wg]}"
            echo -n "  $source → $target (WG: $target_wg): "
            
            RESULT=$(ssh -o BatchMode=yes -o ConnectTimeout=3 root@$source_ip \
                "ssh -o BatchMode=yes -o ConnectTimeout=2 root@$target_wg 'hostname' 2>&1")
            
            if echo "$RESULT" | grep -q "$target"; then
                echo -e "${GREEN}✓ OK${NC}"
                ((test_ok++))
            else
                echo -e "${RED}✗ FAIL${NC}"
            fi
        done
    done
    
    echo -e "\n  Résultat: $test_ok/$test_total connexions OK"
}

# Menu principal
echo -e "${CYAN}Que voulez-vous faire ?${NC}"
echo "  1. Interconnecter TOUS les pools automatiquement"
echo "  2. Interconnecter un pool spécifique"
echo "  3. Afficher l'état des connexions"
echo "  4. Ajouter un nouveau serveur"
echo
read -p "Choix (1-4): " choice

case $choice in
    1)
        echo -e "\n${YELLOW}Interconnexion de tous les pools...${NC}\n"
        for pool in "${!POOLS[@]}"; do
            interconnect_pool "$pool"
            echo
        done
        ;;
    
    2)
        echo -e "\nPools disponibles:"
        i=1
        declare -a pool_array
        for pool in "${!POOLS[@]}"; do
            echo "  $i. $pool"
            pool_array[$i]="$pool"
            ((i++))
        done
        echo
        read -p "Numéro du pool: " pool_num
        if [ -n "${pool_array[$pool_num]:-}" ]; then
            interconnect_pool "${pool_array[$pool_num]}"
        else
            echo -e "${RED}Pool invalide${NC}"
        fi
        ;;
    
    3)
        echo -e "\n${CYAN}État des connexions par pool :${NC}\n"
        for pool in "${!POOLS[@]}"; do
            echo "Pool $pool:"
            members="${POOLS[$pool]}"
            for source in $members; do
                source_ip="${SERVER_INFO[${source}_ip]}"
                echo -n "  $source: "
                ok=0
                total=0
                for target in $members; do
                    [ "$source" == "$target" ] && continue
                    ((total++))
                    target_wg="${SERVER_INFO[${target}_wg]}"
                    if ssh -o BatchMode=yes -o ConnectTimeout=2 root@$source_ip \
                        "ssh -o BatchMode=yes -o ConnectTimeout=1 root@$target_wg 'true'" 2>/dev/null; then
                        ((ok++))
                    fi
                done
                [ $total -gt 0 ] && echo "$ok/$total OK" || echo "N/A"
            done
            echo
        done
        ;;
    
    4)
        echo -e "\n${YELLOW}Ajout d'un nouveau serveur${NC}"
        echo "Ajoutez la ligne dans $SERVERS_TSV puis relancez ce script"
        echo "Format: IP_PUBLIQUE[TAB]HOSTNAME[TAB]IP_WIREGUARD[TAB]FQDN[TAB]USER[TAB]POOL"
        echo
        echo "Le script va automatiquement:"
        echo "  • Déployer les clés SSH"
        echo "  • Configurer WireGuard"
        echo "  • L'interconnecter avec son pool"
        ;;
esac

echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}           Pool Manager Terminé             ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
