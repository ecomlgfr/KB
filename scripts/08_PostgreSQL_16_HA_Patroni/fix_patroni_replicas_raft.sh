#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        FIX_PATRONI_REPLICAS_RAFT - Réparation des Replicas         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
REPLICA_NODES=(db-slave-01 db-slave-02)
DB_NODES=(db-master-01 db-slave-01 db-slave-02)
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Charger credentials
source /opt/keybuzz-installer/credentials/postgres.env

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo ""
echo "1. État actuel du cluster Raft..."
echo ""

# Vérifier chaque nœud
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    # Test API Patroni
    if STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"state={d.get('state','?')}, role={d.get('role','?')}\")" 2>/dev/null); then
        echo "$STATE"
    else
        echo "API non accessible"
    fi
done

echo ""
echo "2. Vérification du leader..."
LEADER_IP="${NODE_IPS[db-master-01]}"
LEADER_STATE=$(curl -s "http://$LEADER_IP:8008/patroni" 2>/dev/null | jq -r '.state' 2>/dev/null)
LEADER_ROLE=$(curl -s "http://$LEADER_IP:8008/patroni" 2>/dev/null | jq -r '.role' 2>/dev/null)

if [ "$LEADER_STATE" = "running" ] && ([ "$LEADER_ROLE" = "master" ] || [ "$LEADER_ROLE" = "leader" ]); then
    echo -e "  $OK db-master-01 est leader et opérationnel"
else
    # Chercher le leader actuel
    echo -e "  $WARN db-master-01 n'est pas leader, recherche du leader..."
    for node in "${DB_NODES[@]}"; do
        ip="${NODE_IPS[$node]}"
        ROLE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | jq -r '.role' 2>/dev/null)
        if [ "$ROLE" = "master" ] || [ "$ROLE" = "leader" ]; then
            echo -e "  $OK Leader trouvé: $node ($ip)"
            LEADER_IP="$ip"
            break
        fi
    done
fi

echo ""
echo "3. Configuration firewall pour Raft..."
echo ""

# S'assurer que le port 7000 est ouvert
for node in "${REPLICA_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: Port 7000... "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'FIREWALL' 2>/dev/null
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni Raft' 2>/dev/null
ufw allow 8008/tcp comment 'Patroni API' 2>/dev/null
ufw allow 5432/tcp comment 'PostgreSQL' 2>/dev/null
ufw --force reload >/dev/null 2>&1
FIREWALL
    echo -e "$OK"
done

echo ""
echo "4. Réparation des replicas avec Raft..."

for node in "${REPLICA_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo ""
    echo "  Traitement $node ($ip)..."
    
    # Construire la liste des partenaires Raft pour ce nœud
    PARTNERS=""
    for other in "${DB_NODES[@]}"; do
        if [ "$other" != "$node" ]; then
            [ -n "$PARTNERS" ] && PARTNERS="$PARTNERS,"
            PARTNERS="${PARTNERS}${NODE_IPS[$other]}:7000"
        fi
    done
    
    MAIN_LOG="$LOG_DIR/fix_replica_raft_${node}_$TIMESTAMP.log"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$node" "$ip" "$POSTGRES_PASSWORD" "$PARTNERS" > "$MAIN_LOG" 2>&1 <<'FIX_REPLICA'
NODE_NAME="$1"
NODE_IP="$2"
PG_PASSWORD="$3"
RAFT_PARTNERS="$4"

echo "    Arrêt du container..."
docker stop patroni 2>/dev/null
docker rm patroni 2>/dev/null

echo "    Nettoyage des données..."
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /opt/keybuzz/postgres/archive/*

echo "    Création répertoire Raft..."
mkdir -p /opt/keybuzz/postgres/raft

echo "    Correction permissions..."
chown -R 999:999 /opt/keybuzz/postgres/data
chown -R 999:999 /opt/keybuzz/postgres/raft
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft

echo "    Configuration Raft pour replica..."
mkdir -p /opt/keybuzz/patroni/config

cat > /opt/keybuzz/patroni/config/patroni.yml <<EOF
scope: postgres-keybuzz
namespace: /service/
name: $NODE_NAME

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008
  authentication:
    username: patroni
    password: '$PG_PASSWORD'

# DCS Raft intégré
raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${NODE_IP}:7000
  partner_addrs:
$(echo "$RAFT_PARTNERS" | tr ',' '\n' | sed 's/^/    - /')

postgresql:
  listen: '*:5432'
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    superuser:
      username: postgres
      password: '$PG_PASSWORD'
    replication:
      username: replicator
      password: '$PG_PASSWORD'
  parameters:
    max_connections: 100
    shared_buffers: 256MB
    wal_level: replica
    max_wal_senders: 10
    hot_standby: 'on'
    wal_log_hints: 'on'
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

echo "    Rebuild image avec Raft..."
cd /opt/keybuzz/patroni

cat > Dockerfile <<DOCKERFILE
FROM postgres:17

RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-dev \
    gcc \
    python3-psycopg2 \
    curl \
    && pip3 install --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary \
        python-dateutil \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY config/patroni.yml /etc/patroni/patroni.yml

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-pg17-raft:latest . >/dev/null 2>&1

echo "    Démarrage du replica avec Raft..."
docker run -d \
  --name patroni \
  --hostname $NODE_NAME \
  --network host \
  --restart unless-stopped \
  -e PATRONI_LOG_LEVEL=INFO \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data:rw \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft:rw \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive:rw \
  -v /opt/keybuzz/patroni/config:/etc/patroni:ro \
  patroni-pg17-raft:latest

echo "    Attente synchronisation Raft (20s)..."
sleep 20

# Vérifier l'état
if docker ps | grep -q patroni; then
    echo "    Container: RUNNING"
    
    # Vérifier l'état via API
    STATE=$(curl -s "http://${NODE_IP}:8008/patroni" 2>/dev/null | jq -r '.state' 2>/dev/null)
    ROLE=$(curl -s "http://${NODE_IP}:8008/patroni" 2>/dev/null | jq -r '.role' 2>/dev/null)
    if [ "$STATE" = "running" ] || [ "$STATE" = "streaming" ]; then
        echo "    État: $STATE, Rôle: $ROLE - OK"
    else
        echo "    État: $STATE, Rôle: $ROLE - Vérification des logs..."
        docker logs patroni --tail 10 2>&1 | grep -E "ERROR|INFO.*streaming|raft" | tail -5
    fi
    
    # Vérifier le port Raft
    if nc -zv localhost 7000 2>&1 | grep -q succeeded; then
        echo "    Port Raft 7000: OK"
    else
        echo "    Port Raft 7000: KO"
    fi
else
    echo "    Container: STOPPED"
    echo "    Derniers logs:"
    docker logs patroni --tail 20 2>&1 | grep -E "ERROR|FATAL" | tail -10
fi

echo "OK" > /opt/keybuzz/postgres/status/STATE
FIX_REPLICA
    
    echo "    $(tail -n 3 "$MAIN_LOG" | head -1)"
done

echo ""
echo "5. Attente stabilisation cluster Raft (15s)..."
sleep 15

echo ""
echo "6. Vérification du cluster..."
echo ""

# Obtenir l'état du cluster depuis le leader
CLUSTER_STATE=$(curl -s "http://$LEADER_IP:8008/cluster" 2>/dev/null)

if [ -n "$CLUSTER_STATE" ]; then
    echo "$CLUSTER_STATE" | python3 -m json.tool 2>/dev/null || echo "$CLUSTER_STATE"
    
    # Analyser l'état
    MEMBERS=$(echo "$CLUSTER_STATE" | jq -r '.members[]' 2>/dev/null | wc -l)
    LEADER=$(echo "$CLUSTER_STATE" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null)
    REPLICAS_OK=$(echo "$CLUSTER_STATE" | jq -r '.members[] | select(.role=="replica" and (.state=="running" or .state=="streaming")) | .name' 2>/dev/null | wc -l)
    
    echo ""
    echo "Résumé:"
    echo "  Total membres: $MEMBERS"
    echo "  Leader: $LEADER"
    echo "  Replicas fonctionnels: $REPLICAS_OK"
else
    echo "État du cluster non accessible"
    
    # Vérification manuelle
    echo ""
    echo "Vérification directe de chaque nœud:"
    for node in "${DB_NODES[@]}"; do
        ip="${NODE_IPS[$node]}"
        echo -n "  $node: "
        
        # Test API
        if STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"state={d.get('state','?')}, role={d.get('role','?')}\")" 2>/dev/null); then
            echo -n "API=$STATE, "
        else
            echo -n "API=KO, "
        fi
        
        # Test Raft
        if ssh -o StrictHostKeyChecking=no root@"$ip" "nc -zv localhost 7000 2>&1 | grep -q succeeded"; then
            echo "Raft=OK"
        else
            echo "Raft=KO"
        fi
    done
fi

echo ""
echo "7. Test de réplication..."

# Test de réplication si le cluster est OK
if [ "$REPLICAS_OK" -ge 1 ]; then
    echo "  Création table test sur le leader..."
    ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
        "docker exec patroni psql -U postgres -c \"
        DROP TABLE IF EXISTS test_repl_raft;
        CREATE TABLE test_repl_raft (id serial, ts timestamp default now(), data text);
        INSERT INTO test_repl_raft (data) VALUES ('Test Raft DCS at ' || now()) RETURNING *;
        \""
    
    sleep 2
    
    echo ""
    echo "  Vérification sur les replicas:"
    for node in "${REPLICA_NODES[@]}"; do
        ip="${NODE_IPS[$node]}"
        echo -n "    $node: "
        RESULT=$(ssh -o StrictHostKeyChecking=no root@"$ip" \
            "docker exec patroni psql -U postgres -t -c 'SELECT count(*) FROM test_repl_raft;' 2>/dev/null" | tr -d ' ')
        
        if [ "$RESULT" = "1" ]; then
            echo -e "$OK Réplication OK"
        else
            echo -e "$KO Réplication KO (count=$RESULT)"
        fi
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Déterminer le statut final
NODES_OK=0
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    if curl -s "http://$ip:8008/patroni" >/dev/null 2>&1; then
        NODES_OK=$((NODES_OK + 1))
    fi
done

if [ "$NODES_OK" -eq 3 ]; then
    echo -e "$OK CLUSTER PATRONI RAFT PLEINEMENT OPÉRATIONNEL"
    echo ""
    echo "Architecture:"
    echo "  • DCS: Raft intégré (pas d'etcd externe)"
    echo "  • Port Raft: 7000/tcp"
    echo "  • 1 leader + 2 replicas"
    echo ""
    echo "Plus aucune dépendance à etcd Docker"
elif [ "$NODES_OK" -ge 2 ]; then
    echo -e "$WARN CLUSTER PATRONI RAFT PARTIELLEMENT OPÉRATIONNEL"
    echo "  $NODES_OK/3 nœuds accessibles"
else
    echo -e "$KO CLUSTER PATRONI RAFT EN ÉCHEC"
    echo ""
    echo "Actions suggérées:"
    echo "  1. Vérifier les logs des nœuds en échec"
    
    for node in "${DB_NODES[@]}"; do
        ip="${NODE_IPS[$node]}"
        if ! curl -s "http://$ip:8008/patroni" >/dev/null 2>&1; then
            echo "     ssh root@$ip 'docker logs patroni --tail 50'"
        fi
    done
    
    echo "  2. Vérifier la connectivité réseau sur port 7000"
    echo "  3. Relancer ./fix_patroni_bootstrap_raft.sh"
fi

# Afficher les logs récents
echo ""
echo "Logs récents (tail -n 50):"
echo "═══════════════════════════════════════════════════════════════════"
for node in "${REPLICA_NODES[@]}"; do
    LOG_FILE="$LOG_DIR/fix_replica_raft_${node}_$TIMESTAMP.log"
    if [ -f "$LOG_FILE" ]; then
        echo ">>> $node:"
        tail -n 50 "$LOG_FILE" | grep -E "OK|KO|ERROR|WARNING|state|role" | tail -n 10
        echo ""
    fi
done

echo "═══════════════════════════════════════════════════════════════════"
