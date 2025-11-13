#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              FIX_HAPROXY_STATS - Correction stats HAProxy          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
HOST="${1:-haproxy-01}"

# Récupérer l'IP du proxy
IP_PRIV=$(awk -F'\t' -v h="$HOST" '$2==h {print $3}' "$SERVERS_TSV")
[ -z "$IP_PRIV" ] && { echo -e "$KO $HOST IP introuvable"; exit 1; }

# IPs des DB
DB_MASTER=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "Correction des stats HAProxy sur $HOST ($IP_PRIV)"
echo ""

# Vérifier l'état actuel
echo "1. État actuel..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'CHECK'
echo "  Container HAProxy:"
docker ps --format "{{.Names}} - {{.Status}}" | grep haproxy || echo "    Pas de container HAProxy"

echo ""
echo "  Port 8404:"
ss -tlnp | grep ":8404" || echo "    Port 8404 non écouté"

echo ""
echo "  Config HAProxy:"
if [ -f /opt/keybuzz/db-proxy/config/haproxy.cfg ]; then
    echo "    Fichier trouvé dans /opt/keybuzz/db-proxy/config/"
elif [ -f /opt/keybuzz/haproxy/config/haproxy.cfg ]; then
    echo "    Fichier trouvé dans /opt/keybuzz/haproxy/config/"
fi
CHECK

# Corriger la configuration HAProxy
echo ""
echo "2. Mise à jour configuration HAProxy..."

ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$DB_MASTER" "$DB_SLAVE1" "$DB_SLAVE2" <<'FIX'
DB_MASTER="$1"
DB_SLAVE1="$2"
DB_SLAVE2="$3"

# Trouver le répertoire de config
if [ -d /opt/keybuzz/db-proxy ]; then
    CFG_DIR="/opt/keybuzz/db-proxy/config"
elif [ -d /opt/keybuzz/haproxy ]; then
    CFG_DIR="/opt/keybuzz/haproxy/config"
else
    CFG_DIR="/opt/keybuzz/haproxy/config"
    mkdir -p "$CFG_DIR"
fi

# Créer une config HAProxy corrigée avec stats
cat > "$CFG_DIR/haproxy.cfg" <<EOF
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 10s
    timeout client 30s
    timeout server 30s
    log global

# Stats HTTP sur port 8404
listen stats
    bind 0.0.0.0:8404
    mode http
    stats enable
    stats uri /
    stats refresh 10s
    stats show-node
    stats show-desc "HAProxy Load Balancer"

# Frontend RW (master)
frontend postgres_rw
    bind 0.0.0.0:5432
    mode tcp
    default_backend postgres_master

# Backend master avec failover
backend postgres_master
    mode tcp
    option httpchk GET /master
    http-check expect status 200
    server db-master ${DB_MASTER}:5432 check port 8008 inter 5s fall 3 rise 2
    server db-slave1-backup ${DB_SLAVE1}:5432 backup check port 8008 inter 5s fall 3 rise 2
    server db-slave2-backup ${DB_SLAVE2}:5432 backup check port 8008 inter 5s fall 3 rise 2

# Frontend RO (replicas)
frontend postgres_ro
    bind 0.0.0.0:5433
    mode tcp
    default_backend postgres_replicas

# Backend replicas
backend postgres_replicas
    mode tcp
    balance leastconn
    option httpchk GET /replica
    http-check expect status 200
    server db-slave1 ${DB_SLAVE1}:5432 check port 8008 inter 5s fall 3 rise 2
    server db-slave2 ${DB_SLAVE2}:5432 check port 8008 inter 5s fall 3 rise 2
    server db-master-backup ${DB_MASTER}:5432 backup check port 8008 inter 5s fall 3 rise 2
EOF

echo "  Configuration mise à jour"

# Redémarrer HAProxy
docker stop haproxy 2>/dev/null
docker rm haproxy 2>/dev/null

# Démarrer avec la bonne config
docker run -d \
  --name haproxy \
  --restart unless-stopped \
  --network host \
  -v ${CFG_DIR}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.9-alpine

sleep 3

# Vérifier
if docker ps | grep -q haproxy; then
    echo "  ✓ HAProxy redémarré"
else
    echo "  ✗ Échec redémarrage"
    docker logs haproxy --tail 10
fi
FIX

# Test des stats
echo ""
echo "3. Test des stats..."

echo -n "  Port 8404 local: "
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "nc -zv localhost 8404 2>&1" | grep -q succeeded && echo "✓" || echo "✗"

echo -n "  HTTP Stats: "
if curl -s --max-time 3 "http://$IP_PRIV:8404/" | grep -q "Statistics Report"; then
    echo -e "$OK"
    echo "    URL: http://$IP_PRIV:8404/"
else
    echo -e "$KO"
fi

# Si toujours KO, essayer un restart simple
if ! curl -s --max-time 3 "http://$IP_PRIV:8404/" | grep -q "Statistics"; then
    echo ""
    echo "4. Restart HAProxy..."
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "docker restart haproxy"
    sleep 5
    
    echo -n "  Test après restart: "
    if curl -s --max-time 3 "http://$IP_PRIV:8404/" | grep -q "Statistics"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
fi

# État final
echo ""
echo "5. État final..."
ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'FINAL'
echo "  Ports HAProxy:"
ss -tlnp | grep -E ":(5432|5433|8404) " | awk '{print "    " $4}'

echo ""
echo "  Container HAProxy:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "NAME|haproxy"
FINAL

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if curl -s --max-time 3 "http://$IP_PRIV:8404/" | grep -q "Statistics"; then
    echo -e "$OK HAProxy Stats fonctionnelles sur $HOST"
    echo ""
    echo "URL des stats: http://$IP_PRIV:8404/"
else
    echo -e "$KO HAProxy Stats non fonctionnelles"
    echo ""
    echo "Debug: ssh root@$IP_PRIV 'docker logs haproxy --tail 20'"
fi
echo "═══════════════════════════════════════════════════════════════════"
