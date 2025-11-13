#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              PATRONI CLUSTER CLEANUP                               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

HOSTS="db-master-01 db-slave-01 db-slave-02"

for host in $HOSTS; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && { echo -e "$KO IP introuvable pour $host"; continue; }
    
    echo "Nettoyage $host ($IP)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" <<'EOSSH'
set -u

CFG="/opt/keybuzz/postgres/config"
DATA="/opt/keybuzz/postgres/data"

if [[ -f "$CFG/docker-compose.yml" ]]; then
    cd "$CFG"
    docker compose down 2>/dev/null || true
    docker rm -f patroni 2>/dev/null || true
fi

# Nettoyer données PostgreSQL (mais pas le volume monté)
if [[ -d "$DATA/pgdata" ]]; then
    echo "  Nettoyage données PostgreSQL..."
    rm -rf "$DATA/pgdata" 2>/dev/null || true
fi

if [[ -d "$DATA/pg_wal" ]]; then
    rm -rf "$DATA/pg_wal" 2>/dev/null || true
fi

# Nettoyer fichiers divers dans data
find "$DATA" -maxdepth 1 -type f -delete 2>/dev/null || true

echo "  Nettoyé"
EOSSH
    
    echo -e "$OK $host nettoyé"
done

echo
echo -e "$OK Nettoyage terminé"
echo "Vous pouvez relancer:"
echo "  for host in db-master-01 db-slave-01 db-slave-02; do"
echo "      ./patroni_node_deploy.sh --host \$host"
echo "  done"
