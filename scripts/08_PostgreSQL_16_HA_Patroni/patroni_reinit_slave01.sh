#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         PATRONI REINIT DB-SLAVE-01 FROM MASTER                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
SLAVE_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3; exit}' "$SERVERS_TSV")

echo
echo "Réinitialisation de db-slave-01 ($SLAVE_IP)..."
echo

ssh -o StrictHostKeyChecking=no root@"$SLAVE_IP" "bash -s" <<'REMOTE_SCRIPT'
set -e

echo "Arrêt Patroni..."
cd /opt/keybuzz/postgres/config
docker compose down

echo "Nettoyage data directory..."
rm -rf /opt/keybuzz/postgres/data/*

echo "Correction permissions..."
chmod 700 /opt/keybuzz/postgres/data
chown -R 999:999 /opt/keybuzz/postgres/data

echo "Redémarrage Patroni (va se synchroniser automatiquement)..."
docker compose up -d

echo "OK"
REMOTE_SCRIPT

if [[ $? -ne 0 ]]; then
    echo -e "$KO Échec reinit"
    exit 1
fi

echo -e "$OK db-slave-01 réinitialisé"
echo

echo "Attente 30s pour synchronisation initiale..."
for i in {30..1}; do
    echo -ne "\r  $i secondes restantes..."
    sleep 1
done
echo
echo

echo "Vérification état..."
for i in {1..10}; do
    if curl -sf "http://$SLAVE_IP:8008/health" >/dev/null 2>&1; then
        echo -e "$OK db-slave-01 healthy !"
        echo
        echo "État du cluster:"
        curl -sf "http://$SLAVE_IP:8008/cluster" | jq -r '.members[] | "\(.name): \(.role) - \(.state)"'
        exit 0
    fi
    echo -n "."
    sleep 5
done

echo
echo -e "${YELLOW}⚠${NC} db-slave-01 pas encore healthy, vérifiez:"
echo "  ssh root@$SLAVE_IP 'docker logs patroni 2>&1 | tail -30'"
echo "  ./patroni_cluster_diag.sh"
