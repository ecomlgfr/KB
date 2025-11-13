#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         05_HAPROXY_DB - HAProxy avec détection Patroni API         ║"
echo "║              (Pour Load Balancer Hetzner 10.0.0.10)                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_FILE="/opt/keybuzz-installer/logs/haproxy_$(date +%Y%m%d_%H%M%S).log"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
[ ! -f "$CREDS_DIR/postgres.env" ] && { echo -e "$KO postgres.env introuvable"; exit 1; }

source "$CREDS_DIR/postgres.env"

mkdir -p "$(dirname "$LOG_FILE")"

PROXY_NODES=(haproxy-01 haproxy-02)
DB_IPS=("10.0.0.120" "10.0.0.121" "10.0.0.122")

echo "" | tee -a "$LOG_FILE"
echo "═══ Installation HAProxy sur les nœuds proxy ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Note: Le Load Balancer Hetzner (10.0.0.10) route le trafic" | tee -a "$LOG_FILE"
echo "      vers haproxy-01 (10.0.0.11) et haproxy-02 (10.0.0.12)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

for node in "${PROXY_NODES[@]}"; do
    PROXY_IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$PROXY_IP" ] && { echo -e "$KO $node IP introuvable" | tee -a "$LOG_FILE"; continue; }
    
    echo "→ Configuration $node ($PROXY_IP)" | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$PROXY_IP" bash -s "$PROXY_IP" "$PATRONI_API_PASSWORD" "${DB_IPS[0]}" "${DB_IPS[1]}" "${DB_IPS[2]}" <<'HAPROXY_INSTALL'
set -u
set -o pipefail

PROXY_IP="$1"
API_PASSWORD="$2"
DB1_IP="$3"
DB2_IP="$4"
DB3_IP="$5"

# Arrêter si existe
docker stop haproxy 2>/dev/null || true
docker rm -f haproxy 2>/dev/null || true

# Créer la structure
mkdir -p /opt/keybuzz/haproxy/{config,logs,status}

# Monter le volume si disponible (XFS ou ext4)
if ! mountpoint -q /opt/keybuzz/haproxy/data 2>/dev/null; then
    mkdir -p /opt/keybuzz/haproxy/data
    
    # Chercher un volume libre
    for device in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
        [ -e "$device" ] || continue
        real=$(readlink -f "$device" 2>/dev/null || echo "$device")
        mount | grep -q " $real " && continue
        
        # Détecter le système de fichiers existant
        FS_TYPE=$(blkid -s TYPE -o value "$real" 2>/dev/null)
        
        if [ -z "$FS_TYPE" ]; then
            # Pas de système de fichiers, créer XFS (comme les DB)
            echo "    Formatage XFS sur $real..."
            mkfs.xfs -f -m reflink=0 "$real" >/dev/null 2>&1
            FS_TYPE="xfs"
        else
            echo "    Système de fichiers détecté: $FS_TYPE"
        fi
        
        # Monter
        mount "$real" /opt/keybuzz/haproxy/data 2>/dev/null
        
        # fstab avec options adaptées au FS
        UUID=$(blkid -s UUID -o value "$real")
        if [ "$FS_TYPE" = "xfs" ]; then
            MOUNT_OPTS="defaults,noatime,nodiratime,logbufs=8,logbsize=256k,nofail"
        else
            MOUNT_OPTS="defaults,nofail"
        fi
        
        grep -q "/opt/keybuzz/haproxy/data" /etc/fstab || \
            echo "UUID=$UUID /opt/keybuzz/haproxy/data $FS_TYPE $MOUNT_OPTS 0 2" >> /etc/fstab
        
        # Supprimer lost+found si présent
        [ -d /opt/keybuzz/haproxy/data/lost+found ] && rm -rf /opt/keybuzz/haproxy/data/lost+found
        
        echo "    ✓ Volume monté: $real ($FS_TYPE)"
        break
    done
fi

# Configuration HAProxy avec détection automatique via Patroni API
cat > /opt/keybuzz/haproxy/config/haproxy.cfg <<EOF
global
    log stdout local0
    maxconn 4000
    daemon
    stats socket /var/run/haproxy.sock mode 600 level admin

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 10s
    timeout client  1h
    timeout server  1h
    retries 3

# Frontend écriture - BIND UNIQUEMENT SUR IP PRIVÉE
# Le LB Hetzner (10.0.0.10) route vers cette IP
frontend fe_pg_write
    bind ${PROXY_IP}:5432
    default_backend be_pg_master

# Backend master - détection via Patroni API /master endpoint
backend be_pg_master
    option httpchk GET /master
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server db-master-01 ${DB1_IP}:5432 check port 8008
    server db-slave-01 ${DB2_IP}:5432 check port 8008
    server db-slave-02 ${DB3_IP}:5432 check port 8008

# Frontend lecture - BIND UNIQUEMENT SUR IP PRIVÉE
frontend fe_pg_read
    bind ${PROXY_IP}:5433
    default_backend be_pg_replicas

# Backend replicas - round-robin sur tous les nœuds sains
backend be_pg_replicas
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
    server db-master-01 ${DB1_IP}:5432 check port 8008
    server db-slave-01 ${DB2_IP}:5432 check port 8008
    server db-slave-02 ${DB3_IP}:5432 check port 8008

# Stats page - BIND SUR IP PRIVÉE
listen stats
    bind ${PROXY_IP}:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:${API_PASSWORD}
    stats admin if TRUE

# Frontend PgBouncer local (pour pooling sur ce proxy)
frontend fe_pgbouncer_write
    bind 127.0.0.1:5432
    default_backend be_pg_master

frontend fe_pgbouncer_read
    bind 127.0.0.1:5433
    default_backend be_pg_replicas
EOF

# Docker compose
cat > /opt/keybuzz/haproxy/docker-compose.yml <<EOF
version: '3.8'

services:
  haproxy:
    image: haproxy:2.8-alpine
    container_name: haproxy
    hostname: haproxy-$(hostname)
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
      - ./logs:/var/log/haproxy
    healthcheck:
      test: ["CMD", "haproxy", "-c", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

# Ouvrir les ports dans UFW si nécessaire
if command -v ufw &>/dev/null; then
    ufw allow from 10.0.0.0/16 to any port 5432 proto tcp comment 'PostgreSQL via HAProxy' 2>/dev/null || true
    ufw allow from 10.0.0.0/16 to any port 5433 proto tcp comment 'PostgreSQL Read via HAProxy' 2>/dev/null || true
    ufw allow from 10.0.0.0/16 to any port 6432 proto tcp comment 'PgBouncer' 2>/dev/null || true
    ufw allow from 10.0.0.0/16 to any port 8404 proto tcp comment 'HAProxy Stats' 2>/dev/null || true
fi

# Démarrer HAProxy
cd /opt/keybuzz/haproxy
docker compose up -d

sleep 5

# Vérifier
if docker ps | grep -q haproxy; then
    echo "    ✓ HAProxy démarré"
    echo "    ✓ Ports ouverts: 5432, 5433, 6432 (PgBouncer), 8404 (Stats)"
    echo "    ✓ Prêt pour le LB Hetzner 10.0.0.10"
    echo "OK" > /opt/keybuzz/haproxy/status/STATE
    
    # Test health checks
    curl -s http://127.0.0.1:8404/stats >/dev/null 2>&1 && echo "    ✓ Stats page accessible"
else
    echo "    ✗ HAProxy échec démarrage"
    docker logs haproxy 2>&1 | tail -20
    echo "KO" > /opt/keybuzz/haproxy/status/STATE
    exit 1
fi
HAPROXY_INSTALL
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Installation terminée" | tee -a "$LOG_FILE"
    else
        echo -e "  $KO Échec installation" | tee -a "$LOG_FILE"
        exit 1
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "═══ Tests de connectivité ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

SUCCESS=0
TOTAL=0

for node in "${PROXY_NODES[@]}"; do
    PROXY_IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "→ Tests sur $node ($PROXY_IP):" | tee -a "$LOG_FILE"
    
    # Test port écriture (5432)
    echo -n "  Port 5432 (écriture): " | tee -a "$LOG_FILE"
    ((TOTAL++))
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$PROXY_IP" -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo -e "$OK" | tee -a "$LOG_FILE"
        ((SUCCESS++))
    else
        echo -e "$KO" | tee -a "$LOG_FILE"
    fi
    
    # Test port lecture (5433)
    echo -n "  Port 5433 (lecture): " | tee -a "$LOG_FILE"
    ((TOTAL++))
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$PROXY_IP" -p 5433 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo -e "$OK" | tee -a "$LOG_FILE"
        ((SUCCESS++))
    else
        echo -e "$KO" | tee -a "$LOG_FILE"
    fi
    
    # Test stats page
    echo -n "  Stats page: " | tee -a "$LOG_FILE"
    ((TOTAL++))
    if curl -s -u "admin:$PATRONI_API_PASSWORD" "http://$PROXY_IP:8404/stats" | grep -q "HAProxy"; then
        echo -e "$OK http://$PROXY_IP:8404/stats" | tee -a "$LOG_FILE"
        ((SUCCESS++))
    else
        echo -e "$KO" | tee -a "$LOG_FILE"
    fi
    
    echo "" | tee -a "$LOG_FILE"
done

echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"

if [ $SUCCESS -eq $TOTAL ]; then
    echo -e "$OK HAPROXY OPÉRATIONNEL ($SUCCESS/$TOTAL tests OK)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Architecture de routage:" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "  Applications → 10.0.0.10 (LB Hetzner)" | tee -a "$LOG_FILE"
    echo "                   ↓" | tee -a "$LOG_FILE"
    echo "    ┌──────────────┴───────────────┐" | tee -a "$LOG_FILE"
    echo "    ↓                              ↓" | tee -a "$LOG_FILE"
    echo "  10.0.0.11 (haproxy-01)    10.0.0.12 (haproxy-02)" | tee -a "$LOG_FILE"
    echo "    ↓                              ↓" | tee -a "$LOG_FILE"
    echo "  Patroni Cluster (10.0.0.120-122)" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Points d'accès UNIQUEMENT via LB Hetzner:" | tee -a "$LOG_FILE"
    echo "  • Écriture: postgresql://user:pass@10.0.0.10:5432/db" | tee -a "$LOG_FILE"
    echo "  • Lecture:  postgresql://user:pass@10.0.0.10:5433/db" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Configuration requise sur LB Hetzner:" | tee -a "$LOG_FILE"
    echo "  • Target 1: 10.0.0.11:5432, 10.0.0.11:5433" | tee -a "$LOG_FILE"
    echo "  • Target 2: 10.0.0.12:5432, 10.0.0.12:5433" | tee -a "$LOG_FILE"
    echo "  • Health check: TCP port 5432" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Stats HAProxy (accès interne uniquement):" | tee -a "$LOG_FILE"
    echo "  • http://10.0.0.11:8404/stats (admin / $PATRONI_API_PASSWORD)" | tee -a "$LOG_FILE"
    echo "  • http://10.0.0.12:8404/stats (admin / $PATRONI_API_PASSWORD)" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Prochaine étape: ./07_pgbouncer_scram.sh" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    tail -n 50 "$LOG_FILE"
    exit 0
else
    echo -e "$KO HAPROXY PARTIELLEMENT OPÉRATIONNEL ($SUCCESS/$TOTAL tests OK)" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    
    tail -n 50 "$LOG_FILE"
    exit 1
fi
