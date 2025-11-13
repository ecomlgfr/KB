#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       PATRONI_MONITOR - Surveillance et Auto-Réparation            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)
MODE="${1:-check}"  # check, fix, monitor

# Charger credentials
if [ -f /opt/keybuzz-installer/credentials/secrets.json ]; then
    PATRONI_PASSWORD=$(jq -r '.patroni.password // .postgres.password' /opt/keybuzz-installer/credentials/secrets.json)
else
    source /opt/keybuzz-installer/credentials/postgres.env
    PATRONI_PASSWORD="${PATRONI_PASSWORD:-$POSTGRES_PASSWORD}"
fi

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

check_cluster() {
    echo "Vérification du cluster..."
    
    local PROBLEMS=()
    local CLUSTER_INFO=$(curl -s -u patroni:$PATRONI_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null)
    
    if [ -z "$CLUSTER_INFO" ]; then
        # Essayer un autre nœud
        CLUSTER_INFO=$(curl -s -u patroni:$PATRONI_PASSWORD "http://${NODE_IPS[db-slave-01]}:8008/cluster" 2>/dev/null)
    fi
    
    if [ -z "$CLUSTER_INFO" ]; then
        echo -e "$KO Impossible d'accéder au cluster"
        return 1
    fi
    
    # Vérifier chaque membre
    for node in "${DB_NODES[@]}"; do
        local STATE=$(echo "$CLUSTER_INFO" | jq -r ".members[] | select(.name==\"$node\") | .state")
        local LAG=$(echo "$CLUSTER_INFO" | jq -r ".members[] | select(.name==\"$node\") | .lag")
        local ROLE=$(echo "$CLUSTER_INFO" | jq -r ".members[] | select(.name==\"$node\") | .role")
        
        echo -n "  $node: "
        
        if [ -z "$STATE" ]; then
            echo -e "$KO Absent du cluster"
            PROBLEMS+=("$node:absent")
        elif [ "$LAG" = "unknown" ]; then
            echo -e "$WARN Lag unknown (role: $ROLE, state: $STATE)"
            PROBLEMS+=("$node:lag_unknown")
        elif [ "$STATE" != "running" ] && [ "$STATE" != "streaming" ]; then
            echo -e "$WARN État anormal: $STATE"
            PROBLEMS+=("$node:state_$STATE")
        else
            echo -e "$OK Role: $ROLE, State: $STATE, Lag: ${LAG:-0}"
        fi
    done
    
    if [ ${#PROBLEMS[@]} -eq 0 ]; then
        echo ""
        echo -e "$OK Cluster sain"
        return 0
    else
        echo ""
        echo -e "$WARN Problèmes détectés: ${#PROBLEMS[@]}"
        for problem in "${PROBLEMS[@]}"; do
            echo "  - $problem"
        done
        return 1
    fi
}

fix_lag_unknown() {
    local node="$1"
    local ip="${NODE_IPS[$node]}"
    
    echo "Réparation de $node (lag unknown)..."
    
    # 1. Essayer un simple restart
    echo "  Tentative 1: Restart container..."
    ssh -o StrictHostKeyChecking=no root@"$ip" "docker restart patroni" 2>/dev/null
    sleep 20
    
    # Vérifier
    local NEW_LAG=$(curl -s -u patroni:$PATRONI_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null | \
        jq -r ".members[] | select(.name==\"$node\") | .lag")
    
    if [ "$NEW_LAG" != "unknown" ] && [ "$NEW_LAG" != "null" ]; then
        echo -e "  $OK Réparé par restart (lag: $NEW_LAG)"
        return 0
    fi
    
    # 2. Reinitialiser le nœud
    echo "  Tentative 2: Réinitialisation complète..."
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'REINIT'
docker stop patroni
docker rm patroni
rm -rf /opt/keybuzz/postgres/data/*

docker run -d --name patroni --hostname $(hostname) --network host --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/patroni/config:/etc/patroni \
  patroni-pg17:latest
REINIT
    
    echo "  Attente resynchronisation (40s)..."
    sleep 40
    
    # Vérifier final
    NEW_LAG=$(curl -s -u patroni:$PATRONI_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null | \
        jq -r ".members[] | select(.name==\"$node\") | .lag")
    
    if [ "$NEW_LAG" != "unknown" ] && [ "$NEW_LAG" != "null" ]; then
        echo -e "  $OK Réparé par réinitialisation (lag: $NEW_LAG)"
        return 0
    else
        echo -e "  $KO Échec réparation - intervention manuelle nécessaire"
        return 1
    fi
}

fix_problems() {
    echo "Tentative de réparation automatique..."
    
    local CLUSTER_INFO=$(curl -s -u patroni:$PATRONI_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null)
    
    for node in "${DB_NODES[@]}"; do
        local LAG=$(echo "$CLUSTER_INFO" | jq -r ".members[] | select(.name==\"$node\") | .lag")
        
        if [ "$LAG" = "unknown" ]; then
            fix_lag_unknown "$node"
        fi
    done
}

monitor_loop() {
    echo "Mode monitoring continu (CTRL+C pour arrêter)"
    echo ""
    
    while true; do
        echo "[$(date '+%F %T')]"
        
        if ! check_cluster; then
            if [ "$MODE" = "monitor" ]; then
                echo "  Réparation automatique activée..."
                fix_problems
            fi
        fi
        
        echo "----------------------------------------"
        sleep 60
    done
}

# Installation crontab
install_cron() {
    echo "Installation surveillance automatique..."
    
    local SCRIPT_PATH="/opt/keybuzz-installer/scripts/patroni_monitor.sh"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    # Ajouter au crontab
    (crontab -l 2>/dev/null | grep -v "patroni_monitor") ; echo "*/5 * * * * $SCRIPT_PATH fix > /dev/null 2>&1" | crontab -
    
    echo -e "$OK Surveillance installée (toutes les 5 minutes)"
}

# Main
case "$MODE" in
    check)
        check_cluster
        ;;
    fix)
        if ! check_cluster; then
            fix_problems
        fi
        ;;
    monitor)
        monitor_loop
        ;;
    install)
        install_cron
        ;;
    *)
        echo "Usage: $0 {check|fix|monitor|install}"
        echo "  check   - Vérifier l'état du cluster"
        echo "  fix     - Réparer les problèmes détectés"
        echo "  monitor - Surveillance continue"
        echo "  install - Installer en crontab"
        exit 1
        ;;
esac
