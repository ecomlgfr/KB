#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                  04_CHECK_ETCD - Vérification                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

ETCD_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)

echo ""
echo "═══ Vérification etcd ═══"
echo ""

SUCCESS=0
FAILED=0

for node in "${ETCD_NODES[@]}"; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP" ] && { echo -e "$node: $KO IP introuvable"; ((FAILED++)); continue; }
    
    echo -n "$node ($IP): "
    
    # Test conteneur
    if ! ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps | grep -q etcd" 2>/dev/null; then
        echo -e "$KO conteneur absent"
        ((FAILED++))
        continue
    fi
    
    # Test endpoint health
    if ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker exec etcd etcdctl --endpoints=http://127.0.0.1:2379 endpoint health" 2>/dev/null | grep -q "successfully committed"; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO endpoint unhealthy"
        ((FAILED++))
    fi
done

echo ""
echo "═══════════════════════════════════════════"
echo "Résultat: $SUCCESS/$((SUCCESS + FAILED)) nœuds OK"
echo ""

if [ $SUCCESS -ge 2 ]; then
    echo -e "$OK Quorum etcd disponible (2/3 minimum)"
    
    # Test depuis un nœud DB
    DB_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
    if [ -n "$DB_IP" ]; then
        echo ""
        echo "Test depuis db-master-01:"
        for node in "${ETCD_NODES[@]}"; do
            ETCD_IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
            echo -n "  $ETCD_IP:2379: "
            if ssh -o StrictHostKeyChecking=no root@"$DB_IP" \
                "curl -s http://$ETCD_IP:2379/version" 2>/dev/null | grep -q "etcdserver"; then
                echo -e "$OK"
            else
                echo -e "$KO"
            fi
        done
    fi
    
    exit 0
else
    echo -e "$KO Quorum insuffisant"
    exit 1
fi
