#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                  ETCD CLUSTER CLEANUP                              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

HOSTS="k3s-master-01 k3s-master-02 k3s-master-03"

for host in $HOSTS; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && { echo -e "$KO IP introuvable pour $host"; continue; }
    
    echo "Nettoyage $host ($IP)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" <<'EOSSH'
set -u

CFG="/opt/keybuzz/etcd/config"

if [[ -f "$CFG/docker-compose.yml" ]]; then
    cd "$CFG"
    docker compose down 2>/dev/null || true
    docker rm -f etcd 2>/dev/null || true
fi

# Ne pas démonter les volumes, juste nettoyer les données
if [[ -d /opt/keybuzz/etcd/data/member ]]; then
    echo "  Nettoyage données etcd..."
    rm -rf /opt/keybuzz/etcd/data/member 2>/dev/null || true
fi

echo "  Nettoyé"
EOSSH
    
    echo -e "$OK $host nettoyé"
done

echo
echo -e "$OK Nettoyage terminé"
echo "Vous pouvez relancer: ./etcd_cluster_deploy.sh --hosts k3s-master-01,k3s-master-02,k3s-master-03"
