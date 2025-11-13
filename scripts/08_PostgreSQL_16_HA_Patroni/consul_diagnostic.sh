#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              CONSUL CLUSTER DIAGNOSTIC                             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
NODES="db-master-01 db-slave-01 db-slave-02"

echo
echo "Vérification des conteneurs Consul..."
echo

for node in $NODES; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3; exit}' "$SERVERS_TSV")
    echo -n "$node ($IP): "
    
    STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps --filter name=consul --format '{{.Status}}'" 2>/dev/null)
    if [[ -n "$STATUS" ]]; then
        echo -e "$OK $STATUS"
    else
        echo -e "$KO Consul non démarré"
    fi
done

echo
echo "Vérification de l'API Consul..."
echo

for node in $NODES; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3; exit}' "$SERVERS_TSV")
    echo -n "$node ($IP): "
    
    if curl -sf "http://$IP:8500/v1/status/leader" >/dev/null 2>&1; then
        LEADER=$(curl -sf "http://$IP:8500/v1/status/leader" 2>/dev/null)
        echo -e "$OK API répond (leader: $LEADER)"
    else
        echo -e "$KO API ne répond pas"
    fi
done

echo
echo "Vérification des membres du cluster..."
echo

MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3; exit}' "$SERVERS_TSV")

if command -v jq &>/dev/null; then
    MEMBERS=$(curl -sf "http://$MASTER_IP:8500/v1/agent/members" 2>/dev/null)
    if [[ -n "$MEMBERS" ]]; then
        echo "Membres détectés:"
        echo "$MEMBERS" | jq -r '.[] | "  • \(.Name) (\(.Addr):\(.Port)) - \(.Status)"'
        
        MEMBER_COUNT=$(echo "$MEMBERS" | jq -r '. | length')
        echo
        if [[ $MEMBER_COUNT -eq 3 ]]; then
            echo -e "$OK Cluster complet: $MEMBER_COUNT/3 membres"
        else
            echo -e "${YELLOW}⚠${NC} Cluster incomplet: $MEMBER_COUNT/3 membres"
        fi
    else
        echo -e "$KO Impossible de récupérer la liste des membres"
    fi
else
    echo -e "${YELLOW}⚠${NC} jq non installé, installation..."
    apt-get update -qq && apt-get install -y jq -qq
    echo "Relancez ce script"
fi

echo
echo "Logs Consul (db-master-01):"
echo "────────────────────────────────────────────────────────────────────"
ssh -o StrictHostKeyChecking=no root@"$MASTER_IP" "docker logs consul 2>&1 | tail -20"
echo "────────────────────────────────────────────────────────────────────"
echo

echo "Consul UI: http://$MASTER_IP:8500/ui/"
