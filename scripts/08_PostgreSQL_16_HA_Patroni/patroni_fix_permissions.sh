#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         PATRONI PERMISSIONS & PASSWORDS FIX                        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

SECRETS_FILE="$CREDS_DIR/secrets.json"
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo -e "$KO Fichier secrets introuvable"
    exit 1
fi

POSTGRES_PASS=$(jq -r '.postgres_password' "$SECRETS_FILE")
REPLICATOR_PASS=$(jq -r '.replicator_password' "$SECRETS_FILE")

echo "Correction des nœuds..."
echo

for node in db-master-01 db-slave-01 db-slave-02; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3; exit}' "$SERVERS_TSV")
    echo -n "$node ($IP): "
    
    ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s $POSTGRES_PASS $REPLICATOR_PASS" <<'REMOTE_SCRIPT'
set -e

POSTGRES_PASS="$1"
REPLICATOR_PASS="$2"

# Fix permissions
chmod 700 /opt/keybuzz/postgres/data
chown -R 999:999 /opt/keybuzz/postgres/data

# Fix patroni.yml passwords
sed -i "s/password: 'null'/password: '$POSTGRES_PASS'/g" /opt/keybuzz/postgres/config/patroni.yml
sed -i "s/password: 'null'/password: '$REPLICATOR_PASS'/g" /opt/keybuzz/postgres/config/patroni.yml

# Restart
cd /opt/keybuzz/postgres/config
docker compose restart patroni

echo "OK"
REMOTE_SCRIPT
    
    if [[ $? -eq 0 ]]; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo
echo "Attente 20s pour stabilisation..."
sleep 20

echo
echo "Vérification santé..."
for node in db-master-01 db-slave-01 db-slave-02; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3; exit}' "$SERVERS_TSV")
    echo -n "$node ($IP): "
    
    if curl -sf "http://$IP:8008/health" >/dev/null 2>&1; then
        echo -e "$OK Healthy"
    else
        echo -e "$KO Unhealthy"
    fi
done

echo
echo -e "${GREEN}Correction terminée${NC}"
echo
echo "Vérifiez le cluster:"
echo "  ./patroni_cluster_diag.sh"
