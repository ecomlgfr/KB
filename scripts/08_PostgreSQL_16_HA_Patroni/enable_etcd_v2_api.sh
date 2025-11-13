#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              ENABLE ETCD V2 API ON K3S MASTERS                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

MASTERS="k3s-master-01 k3s-master-02 k3s-master-03"

echo
echo "Modification config K3s pour activer API v2 etcd..."
echo

for master in $MASTERS; do
    IP=$(awk -F'\t' -v h="$master" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && continue
    
    echo -n "$master ($IP): "
    
    ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" <<'REMOTE_SCRIPT'
set -e

# Config K3s
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
mkdir -p /etc/rancher/k3s

# Vérifier si déjà présent
if [[ -f "$K3S_CONFIG" ]] && grep -q "enable-v2: true" "$K3S_CONFIG"; then
    echo "ALREADY"
    exit 0
fi

# Backup
[[ -f "$K3S_CONFIG" ]] && cp "$K3S_CONFIG" "${K3S_CONFIG}.bak"

# Ajouter/modifier la config etcd
if [[ ! -f "$K3S_CONFIG" ]]; then
    cat > "$K3S_CONFIG" <<'EOF'
etcd-arg:
  - "--enable-v2=true"
EOF
else
    # Ajouter si absent
    if ! grep -q "etcd-arg:" "$K3S_CONFIG"; then
        echo "" >> "$K3S_CONFIG"
        echo "etcd-arg:" >> "$K3S_CONFIG"
        echo '  - "--enable-v2=true"' >> "$K3S_CONFIG"
    elif ! grep -q "enable-v2" "$K3S_CONFIG"; then
        sed -i '/etcd-arg:/a\  - "--enable-v2=true"' "$K3S_CONFIG"
    fi
fi

echo "UPDATED"

# Redémarrer K3s
systemctl restart k3s
REMOTE_SCRIPT
    
    RESULT=$?
    if [[ $RESULT -eq 0 ]]; then
        echo -e " $OK"
    else
        echo -e " $KO"
    fi
done

echo
echo "Attente 45s pour que K3s redémarre et etcd soit prêt..."
sleep 45

echo
echo "Vérification de l'API v2..."
echo

SUCCESS=0
FAILED=0

for master in $MASTERS; do
    IP=$(awk -F'\t' -v h="$master" '$2==h {print $3; exit}' "$SERVERS_TSV")
    [[ -z "$IP" ]] && continue
    
    echo -n "$master ($IP): "
    
    # Test API v2
    V2_TEST=$(curl -sf "http://$IP:2379/v2/keys" 2>/dev/null)
    if [[ -n "$V2_TEST" ]]; then
        echo -e "$OK API v2 active"
        ((SUCCESS++))
    else
        echo -e "$KO API v2 inactive"
        ((FAILED++))
    fi
done

echo
echo "Résultat: $SUCCESS/3 masters avec API v2 active"

if [[ $SUCCESS -eq 3 ]]; then
    echo
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ API v2 activée - Relancer Patroni       ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo
    echo "Prochaines étapes:"
    echo "  ./patroni_cluster_cleanup.sh"
    echo "  for host in db-master-01 db-slave-01 db-slave-02; do"
    echo "      ./patroni_node_deploy.sh --host \$host"
    echo "  done"
    exit 0
else
    echo
    echo -e "${RED}═══════════════════════════════════════════${NC}"
    echo -e "${RED}⚠ API v2 non activée sur tous les masters ${NC}"
    echo -e "${RED}═══════════════════════════════════════════${NC}"
    echo
    echo "Vérifier les logs K3s:"
    echo "  ssh root@10.0.0.100 'journalctl -u k3s -n 50'"
    exit 1
fi
