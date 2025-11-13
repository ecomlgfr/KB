#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  PATCH_02_HAPROXY_PATRONI_AWARE - HAProxy intelligent avec checks  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

PROXY_NODES=(haproxy-01 haproxy-02)
DB_NODES=(db-master-01 db-slave-01 db-slave-02)

echo ""
echo "Ce patch va:"
echo "  1. Reconfigurer HAProxy avec checks Patroni HTTP"
echo "  2. Port :5432 → suit automatiquement le master actuel"
echo "  3. Port :5433 → balance sur les replicas actifs"
echo "  4. Stats sécurisées sur :8404"
echo "  5. Bind sur IP privée (pas 0.0.0.0)"
echo ""

# Récupérer les IPs
declare -A PROXY_IPS
for node in "${PROXY_NODES[@]}"; do
    PROXY_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

declare -A DB_IPS
for node in "${DB_NODES[@]}"; do
    DB_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo "Proxies:"
for node in "${PROXY_NODES[@]}"; do
    echo "  $node: ${PROXY_IPS[$node]}"
done

echo ""
echo "DB Nodes:"
for node in "${DB_NODES[@]}"; do
    echo "  $node: ${DB_IPS[$node]}"
done
echo ""

read -p "Continuer avec le patch HAProxy? (y/N) " -r
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Annulé"; exit 0; }

# Stats credentials
STATS_USER="admin"
STATS_PASS=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)

echo ""
echo "Credentials stats HAProxy:"
echo "  User: $STATS_USER"
echo "  Pass: $STATS_PASS"
echo ""

# Sauvegarder
mkdir -p /opt/keybuzz-installer/credentials
cat >> /opt/keybuzz-installer/credentials/haproxy.env <<EOF
HAPROXY_STATS_USER=$STATS_USER
HAPROXY_STATS_PASS=$STATS_PASS
EOF

for PROXY_NODE in "${PROXY_NODES[@]}"; do
    PROXY_IP="${PROXY_IPS[$PROXY_NODE]}"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "Configuration de $PROXY_NODE ($PROXY_IP)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$PROXY_IP" \
        "${DB_IPS[db-master-01]}" "${DB_IPS[db-slave-01]}" "${DB_IPS[db-slave-02]}" \
        "$STATS_USER" "$STATS_PASS" <<'HAPROXY_RECONFIG'
PROXY_IP="$1"
DB1_IP="$2"
DB2_IP="$3"
DB3_IP="$4"
STATS_USER="$5"
STATS_PASS="$6"

echo "→ Arrêt HAProxy existant..."
docker stop haproxy 2>/dev/null
docker rm haproxy 2>/dev/null

# Créer la config
mkdir -p /opt/keybuzz/haproxy/config

echo "→ Génération config HAProxy Patroni-aware..."

cat > /opt/keybuzz/haproxy/config/haproxy.cfg <<EOF
global
    log stdout local0
    maxconn 10000
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 10s
    timeout client 1h
    timeout server 1h
    timeout check 5s

# ============================================================================
# STATS HTTP (Interface web)
# ============================================================================
listen stats
    bind ${PROXY_IP}:8404
    mode http
    stats enable
    stats uri /
    stats refresh 10s
    stats show-legends
    stats show-desc "HAProxy PostgreSQL Load Balancer"
    stats auth ${STATS_USER}:${STATS_PASS}
    stats admin if TRUE

# ============================================================================
# FRONTEND WRITE (5432) - Suit le master Patroni automatiquement
# ============================================================================
frontend fe_postgres_write
    bind ${PROXY_IP}:5432
    default_backend be_postgres_master

backend be_postgres_master
    mode tcp
    balance first
    option httpchk GET /master
    http-check expect status 200
    default-server inter 5s fall 3 rise 2 on-marked-down shutdown-sessions
    
    server db-master-01 ${DB1_IP}:5432 check port 8008
    server db-slave-01 ${DB2_IP}:5432 check port 8008
    server db-slave-02 ${DB3_IP}:5432 check port 8008

# ============================================================================
# FRONTEND READ (5433) - Balance sur les replicas actifs
# ============================================================================
frontend fe_postgres_read
    bind ${PROXY_IP}:5433
    default_backend be_postgres_replicas

backend be_postgres_replicas
    mode tcp
    balance leastconn
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 5s fall 3 rise 2 on-marked-down shutdown-sessions
    
    server db-slave-01 ${DB2_IP}:5432 check port 8008
    server db-slave-02 ${DB3_IP}:5432 check port 8008
    server db-master-01 ${DB1_IP}:5432 check port 8008 backup
EOF

echo "  ✓ Configuration générée"

echo "→ Démarrage HAProxy..."

docker run -d \
  --name haproxy \
  --restart unless-stopped \
  --network host \
  -v /opt/keybuzz/haproxy/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.9-alpine

sleep 5

if docker ps | grep -q haproxy; then
    echo "  ✓ HAProxy démarré"
    
    # Vérifier les ports
    for port in 5432 5433 8404; do
        if ss -tlnp | grep -q ":$port "; then
            echo "  ✓ Port $port actif"
        else
            echo "  ✗ Port $port inactif"
        fi
    done
else
    echo "  ✗ Échec démarrage HAProxy"
    docker logs haproxy 2>&1 | tail -10
fi
HAPROXY_RECONFIG
    
    echo ""
    echo "Tests sur $PROXY_NODE:"
    
    # Test stats
    echo -n "  Stats (8404): "
    if curl -s -u "$STATS_USER:$STATS_PASS" "http://$PROXY_IP:8404/" | grep -q "HAProxy"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Test connectivité DB
    if command -v psql &>/dev/null; then
        source /opt/keybuzz-installer/credentials/postgres.env 2>/dev/null || POSTGRES_PASSWORD="2GUhwWm2adQ9JX8MLK6PeJqM8"
        
        echo -n "  Write (5432): "
        if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$PROXY_IP" -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
        
        echo -n "  Read (5433): "
        if PGPASSWORD="$POSTGRES_PASSWORD" timeout 3 psql -h "$PROXY_IP" -p 5433 -U postgres -d postgres -c "SELECT 1" &>/dev/null; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    fi
done

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              HAPROXY PATRONI-AWARE CONFIGURÉ                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

echo "Changements appliqués:"
echo "  ✓ Checks HTTP Patroni /master et /replica"
echo "  ✓ Failover automatique sur :5432 (suit le leader)"
echo "  ✓ Load balancing intelligent sur :5433 (replicas only)"
echo "  ✓ Stats sécurisées avec auth"
echo "  ✓ Bind sur IP privée uniquement"
echo ""

echo "Stats HAProxy:"
for node in "${PROXY_NODES[@]}"; do
    echo "  • http://${PROXY_IPS[$node]}:8404/ (user: $STATS_USER, pass: $STATS_PASS)"
done
echo ""

echo "Test failover:"
echo "  1. Identifier le leader actuel:"
echo "     curl http://${DB_IPS[db-master-01]}:8008/patroni | jq .role"
echo ""
echo "  2. Provoquer un switchover:"
echo "     curl -X POST http://${DB_IPS[db-master-01]}:8008/switchover \\"
echo "       -d '{\"leader\":\"db-master-01\",\"candidate\":\"db-slave-01\"}'"
echo ""
echo "  3. Vérifier que :5432 suit automatiquement le nouveau master"
echo "     (HAProxy détecte via /master en <5s)"
echo ""

echo "Credentials sauvegardés:"
echo "  /opt/keybuzz-installer/credentials/haproxy.env"
echo ""

echo "Prochaine étape:"
echo "  ./PATCH_03_pgbouncer_docker_pool.sh"
echo ""
