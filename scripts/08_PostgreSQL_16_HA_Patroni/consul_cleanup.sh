#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              CONSUL CLEANUP                                        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
NODES="db-master-01 db-slave-01 db-slave-02"

echo
for node in $NODES; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3; exit}' "$SERVERS_TSV")
    echo -n "$node ($IP): "
    
    ssh -o StrictHostKeyChecking=no root@"$IP" "
        cd /opt/consul 2>/dev/null && docker compose down 2>/dev/null || true
        docker rm -f consul 2>/dev/null || true
        rm -rf /opt/consul/data/*
    " 2>/dev/null
    
    echo -e "$OK Nettoyé"
done

echo
echo -e "$OK Consul nettoyé sur tous les nœuds"
echo
echo "Relancez: ./deploy_consul_dcs.sh"
