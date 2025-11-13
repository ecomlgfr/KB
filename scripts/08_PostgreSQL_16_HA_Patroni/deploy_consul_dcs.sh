#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          CONSUL DCS DEPLOYMENT FOR PATRONI                         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
OK="${GREEN}OK${NC}"; KO="${RED}KO${NC}"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[[ ! -f "$SERVERS_TSV" ]] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Déployer Consul sur les 3 nœuds DB
NODES="db-master-01 db-slave-01 db-slave-02"

echo
echo "Déploiement Consul cluster (3 nœuds)..."
echo

declare -a IPS=()
for node in $NODES; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3; exit}' "$SERVERS_TSV")
    IPS+=("$IP")
done

echo "Nœuds Consul:"
for i in "${!IPS[@]}"; do
    echo "  $(echo $NODES | cut -d' ' -f$((i+1))): ${IPS[$i]}"
done
echo

# Générer une clé de chiffrement Consul (commune à tous les nœuds)
ENCRYPT_KEY=$(head -c 32 /dev/urandom | base64)

IDX=0
for node in $NODES; do
    IP="${IPS[$IDX]}"
    echo "Déploiement Consul sur $node ($IP)..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" <<REMOTE_SCRIPT
set -e

mkdir -p /opt/consul/{data,config}

# Docker Compose pour Consul
cat > /opt/consul/docker-compose.yml <<'EOF'
services:
  consul:
    image: hashicorp/consul:1.18
    container_name: consul
    hostname: $node
    restart: unless-stopped
    network_mode: host
    command:
      - agent
      - -server
      - -bootstrap-expect=3
      - -ui
      - -bind=$IP
      - -advertise=$IP
      - -client=0.0.0.0
      - -retry-join=${IPS[0]}
      - -retry-join=${IPS[1]}
      - -retry-join=${IPS[2]}
      - -encrypt=$ENCRYPT_KEY
      - -data-dir=/consul/data
    volumes:
      - /opt/consul/data:/consul/data
EOF

# Démarrer Consul
cd /opt/consul
docker compose down 2>/dev/null || true
docker compose up -d

echo "OK"
REMOTE_SCRIPT
    
    if [[ $? -eq 0 ]]; then
        echo -e "  $OK $node Consul démarré"
    else
        echo -e "  $KO $node Consul échec"
    fi
    
    ((IDX++))
done

echo
echo "Attente 20s pour que le cluster Consul se forme..."
sleep 20

echo
echo "Vérification cluster Consul..."
echo

LEADER_IP="${IPS[0]}"
MEMBERS=$(curl -sf "http://$LEADER_IP:8500/v1/agent/members" 2>/dev/null | jq -r '.[].Name' | wc -l)

if [[ $MEMBERS -eq 3 ]]; then
    echo -e "$OK Cluster Consul formé: $MEMBERS/3 membres"
else
    echo -e "$KO Cluster Consul incomplet: $MEMBERS/3 membres"
fi

echo
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Consul cluster prêt                      ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo
echo "Consul UI: http://$LEADER_IP:8500"
echo
echo "Prochaines étapes:"
echo "  ./patroni_cluster_cleanup.sh"
echo "  for host in db-master-01 db-slave-01 db-slave-02; do"
echo "      ./patroni_node_deploy_consul.sh --host \$host"
echo "  done"
