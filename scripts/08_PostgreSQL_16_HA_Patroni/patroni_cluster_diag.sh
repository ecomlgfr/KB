#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              PATRONI CLUSTER DIAGNOSTIC                            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

HOSTS="db-master-01 db-slave-01 db-slave-02"

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "VÉRIFICATION CONTAINERS"
echo "═══════════════════════════════════════════════════════════════════"

for host in $HOSTS; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && continue
    
    echo
    echo -e "${CYAN}$host ($IP)${NC}"
    
    RUNNING=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps --filter name=patroni --format '{{.Status}}' 2>/dev/null" 2>/dev/null)
    
    if [[ -n "$RUNNING" ]]; then
        echo -e "  Container: $OK ($RUNNING)"
        
        HEALTH=$(curl -sf "http://$IP:8008/health" 2>/dev/null)
        if [[ "$HEALTH" == *"true"* ]]; then
            echo -e "  Health: $OK"
        else
            echo -e "  Health: $KO"
        fi
        
        ROLE=$(curl -sf "http://$IP:8008" 2>/dev/null | jq -r '.role' 2>/dev/null)
        STATE=$(curl -sf "http://$IP:8008" 2>/dev/null | jq -r '.state' 2>/dev/null)
        TIMELINE=$(curl -sf "http://$IP:8008" 2>/dev/null | jq -r '.timeline' 2>/dev/null)
        
        echo "  Rôle: ${ROLE:-inconnu}"
        echo "  État: ${STATE:-inconnu}"
        echo "  Timeline: ${TIMELINE:-inconnu}"
    else
        echo -e "  Container: $KO (pas de container)"
    fi
done

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "CLUSTER INFO"
echo "═══════════════════════════════════════════════════════════════════"

# Essayer sur chaque nœud pour trouver le cluster
for host in $HOSTS; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && continue
    
    CLUSTER=$(curl -sf "http://$IP:8008/cluster" 2>/dev/null)
    if [[ -n "$CLUSTER" ]]; then
        echo
        echo "Cluster info depuis $host:"
        echo "$CLUSTER" | jq '.' 2>/dev/null || echo "$CLUSTER"
        break
    fi
done

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "LOGS RÉCENTS"
echo "═══════════════════════════════════════════════════════════════════"

for host in $HOSTS; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && continue
    
    echo
    echo -e "${CYAN}$host - Dernières 10 lignes${NC}"
    ssh -o StrictHostKeyChecking=no root@"$IP" "docker logs patroni --tail 10 2>&1" 2>/dev/null | tail -10
done

echo
