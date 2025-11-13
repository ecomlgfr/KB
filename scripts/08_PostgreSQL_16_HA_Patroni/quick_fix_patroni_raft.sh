#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          QUICK_FIX_PATRONI_RAFT - Réparation rapide                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-KeyBuzz2024Postgres}"

# Récupérer les IPs
declare -A NODE_IPS
NODE_IPS[db-master-01]="10.0.0.120"
NODE_IPS[db-slave-01]="10.0.0.121"
NODE_IPS[db-slave-02]="10.0.0.122"

echo ""
echo "1. Arrêt de tous les containers..."
for node in "${DB_NODES[@]}"; do
    ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[$node]}" \
        "docker stop patroni 2>/dev/null; docker rm patroni 2>/dev/null" &
done
wait
echo "  Fait"

echo ""
echo "2. Correction des configurations Patroni..."

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "  Configuration $node..."
    
    # Construire la liste des partenaires
    PARTNERS=""
    for other in "${DB_NODES[@]}"; do
        if [ "$other" != "$node" ]; then
            [ -n "$PARTNERS" ] && PARTNERS="$PARTNERS
    - ${NODE_IPS[$other]}:7000"
            [ -z "$PARTNERS" ] && PARTNERS="    - ${NODE_IPS[$other]}:7000"
        fi
    done
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<PATRONI_CONFIG
# Créer les répertoires
mkdir -p /opt/keybuzz/postgres/{data,raft,archive}
mkdir -p /opt/keybuzz/patroni/config

# Permissions
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft

# Nettoyer le répertoire Raft
rm -rf /opt/keybuzz/postgres/raft/*

# Créer la config simplifiée
cat > /opt/keybuzz/patroni/config/patroni.yml <<'EOF'
scope: postgres-keybuzz
namespace: /service/
name: $node

restapi:
  listen: ${ip}:8008
  connect_address: ${ip}:8008

raft:
  data_dir: /opt/keybuzz/postgres/raft
  self_addr: ${ip}:7000
  partner_addrs:
$PARTNERS

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 100
        shared_buffers: 256MB
        wal_level: replica
        max_wal_senders: 10
        hot_standby: 'on'

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5

postgresql:
  listen: '*:5432'
  connect_address: ${ip}:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    superuser:
      username: postgres
      password: '$POSTGRES_PASSWORD'
    replication:
      username: replicator
      password: '$POSTGRES_PASSWORD'
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off
EOF

echo "    Config créée"
PATRONI_CONFIG
done

echo ""
echo "3. Reconstruction des images Docker..."

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  Build sur $node... "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'BUILD' >/dev/null 2>&1
cd /opt/keybuzz/patroni

cat > Dockerfile <<'DOCKERFILE'
FROM postgres:17

RUN apt-get update && \
    apt-get install -y python3-pip python3-dev gcc curl && \
    pip3 install --break-system-packages \
        patroni[raft]==3.3.2 \
        psycopg2-binary \
        python-dateutil && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

EXPOSE 5432 8008 7000

CMD ["patroni", "/etc/patroni/patroni.yml"]
DOCKERFILE

docker build -t patroni-pg17-raft:latest .
BUILD
    
    echo -e "$OK"
done

echo ""
echo "4. Nettoyage des données pour un démarrage propre..."

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node... "
    ssh -o StrictHostKeyChecking=no root@"$ip" \
        "rm -rf /opt/keybuzz/postgres/data/* /opt/keybuzz/postgres/raft/*" 2>/dev/null
    echo -e "$OK"
done

echo ""
echo "5. Démarrage du cluster..."

# Démarrer db-master-01 en premier (bootstrap)
echo "  Démarrage db-master-01 (bootstrap)..."
ssh -o StrictHostKeyChecking=no root@"${NODE_IPS[db-master-01]}" bash <<'START_MASTER'
docker run -d \
  --name patroni \
  --hostname db-master-01 \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg17-raft:latest

sleep 5

# Vérifier
if docker ps | grep -q patroni; then
    echo "    Container démarré"
else
    echo "    ERREUR - Logs:"
    docker logs patroni --tail 20
fi
START_MASTER

echo "  Attente initialisation (20s)..."
sleep 20

# Démarrer les slaves
for node in db-slave-01 db-slave-02; do
    ip="${NODE_IPS[$node]}"
    echo "  Démarrage $node..."
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START_SLAVE'
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg17-raft:latest

sleep 5
START_SLAVE
done

echo ""
echo "6. Attente stabilisation (20s)..."
sleep 20

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "VÉRIFICATION FINALE"
echo "═══════════════════════════════════════════════════════════════════"

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo ""
    echo "$node ($ip):"
    
    # Container status
    echo -n "  Container: "
    if ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q patroni" 2>/dev/null; then
        echo -e "$OK Running"
        
        # Test API
        echo -n "  API Patroni: "
        if curl -s "http://$ip:8008/patroni" >/dev/null 2>&1; then
            STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('state','?')}/{d.get('role','?')}\")" 2>/dev/null || echo "?/?")
            echo -e "$OK ($STATE)"
        else
            echo -e "$KO"
            
            # Afficher les derniers logs d'erreur
            echo "  Derniers logs:"
            ssh -o StrictHostKeyChecking=no root@"$ip" \
                "docker logs patroni --tail 10 2>&1 | grep -E 'ERROR|FATAL|error'" | head -5 | sed 's/^/    /'
        fi
        
        # Test port Raft
        echo -n "  Port Raft 7000: "
        if ssh -o StrictHostKeyChecking=no root@"$ip" \
            "docker exec patroni netstat -tln | grep -q ':7000'" 2>/dev/null; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    else
        echo -e "$KO Not running"
    fi
done

echo ""
echo "État du cluster:"
curl -s "http://10.0.0.120:8008/cluster" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  Cluster non accessible"

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Déterminer le succès
NODES_OK=0
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    curl -s "http://$ip:8008/patroni" >/dev/null 2>&1 && NODES_OK=$((NODES_OK + 1))
done

if [ "$NODES_OK" -eq 3 ]; then
    echo -e "$OK CLUSTER PATRONI RAFT OPÉRATIONNEL"
    echo ""
    echo "Test de connexion PostgreSQL:"
    echo "  psql -h 10.0.0.120 -U postgres -c 'SELECT version()'"
elif [ "$NODES_OK" -gt 0 ]; then
    echo -e "$KO CLUSTER PARTIELLEMENT OPÉRATIONNEL ($NODES_OK/3 nœuds)"
    echo ""
    echo "Utiliser: ./diagnostic_patroni_raft.sh pour plus de détails"
else
    echo -e "$KO CLUSTER NON OPÉRATIONNEL"
    echo ""
    echo "Vérifier les logs sur chaque nœud:"
    echo "  ssh root@10.0.0.120 'docker logs patroni --tail 50'"
fi

echo "═══════════════════════════════════════════════════════════════════"
