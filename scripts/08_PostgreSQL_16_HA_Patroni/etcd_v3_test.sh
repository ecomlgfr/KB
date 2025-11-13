#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                   ETCD V3 API TEST                                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

ETCD_HOSTS="k3s-master-01 k3s-master-02 k3s-master-03"

echo
echo "Test etcd v3 API sur les masters K3s..."
echo

for host in $ETCD_HOSTS; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && continue
    
    echo -n "$host ($IP): "
    
    # Test v2 (devrait échouer)
    V2=$(curl -sf "http://$IP:2379/v2/keys" 2>/dev/null)
    if [[ -n "$V2" ]]; then
        echo -e "$OK v2 actif (étrange)"
    else
        echo -n "v2 KO (normal) - "
    fi
    
    # Test v3 health
    V3=$(curl -sf "http://$IP:2379/health" 2>/dev/null)
    if [[ "$V3" == *"true"* ]]; then
        echo -e "$OK v3 healthy"
    else
        echo -e "$KO v3 inaccessible"
    fi
done

echo
echo "Test avec etcdctl v3..."
echo

# Test sur le premier master
FIRST_IP=$(awk -F'\t' '$2=="k3s-master-01" {print $3; exit}' "$SERVERS_TSV")

ssh -o StrictHostKeyChecking=no root@"$FIRST_IP" "bash -s" <<'REMOTE'
if docker exec etcd etcdctl --endpoints=http://127.0.0.1:2379 endpoint health 2>/dev/null; then
    echo "✓ etcdctl v3 fonctionne"
else
    echo "✗ etcdctl v3 échec"
fi
REMOTE

echo
