#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   05_HAPROXY_PATRONI - HAProxy avec API Patroni (Load Balancer)   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
mkdir -p "$LOG_DIR"

# Charger credentials
CRED_FILE="/opt/keybuzz-installer/credentials/postgres.env"
if [ -f "$CRED_FILE" ]; then
    source "$CRED_FILE"
else
    echo -e "$KO Fichier credentials manquant: $CRED_FILE"
    exit 1
fi

# IPs depuis servers.tsv
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2_IP=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══ Vérification cluster PostgreSQL/Patroni ═══"
echo ""
echo "  db-master-01  : $DB_MASTER_IP"
echo "  db-slave-01   : $DB_SLAVE1_IP"
echo "  db-slave-02   : $DB_SLAVE2_IP"
echo "  haproxy-01    : $HAPROXY1_IP"
echo "  haproxy-02    : $HAPROXY2_IP"
echo ""

# Vérifier que Patroni API répond
echo -n "  Vérification Patroni API (db-master-01): "
if curl -sf "http://${DB_MASTER_IP}:8008/" >/dev/null 2>&1; then
    ROLE=$(curl -s "http://${DB_MASTER_IP}:8008/" | grep -o '"role":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    echo -e "$OK (role: $ROLE)"
else
    echo -e "$KO API Patroni non accessible"
    echo ""
    echo "  Patroni doit être démarré avant HAProxy."
    echo "  Vérifiez: curl http://${DB_MASTER_IP}:8008/cluster"
    exit 1
fi

echo ""
echo "═══ Installation HAProxy sur les nœuds proxy ═══"
echo ""

for PROXY_NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NODE IP <<< "$PROXY_NODE"
    LOG_FILE="$LOG_DIR/haproxy_${NODE}.log"
    
    echo "→ Configuration $NODE ($IP)" | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash -s "$DB_MASTER_IP" "$DB_SLAVE1_IP" "$DB_SLAVE2_IP" "$IP" <<'HAPROXY_INSTALL' >> "$LOG_FILE" 2>&1
    set -u
    set -o pipefail
    
    DB_MASTER="$1"
    DB_SLAVE1="$2"
    DB_SLAVE2="$3"
    IP_PRIVEE="$4"
    
    BASE="/opt/keybuzz/haproxy"
    mkdir -p "$BASE"/{config,logs,status,data}
    
    # Vérifier et monter le volume
    if ! mountpoint -q "$BASE/data"; then
        echo "  → Montage du volume Hetzner..."
        
        # Trouver un device non monté
        DEV=""
        for candidate in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
            [ -e "$candidate" ] || continue
            real=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
            mount | grep -q " $real " && continue
            DEV="$real"
            break
        done
        
        if [ -z "$DEV" ]; then
            echo "  ✗ Aucun volume disponible"
            exit 1
        fi
        
        echo "  → Device trouvé: $DEV"
        
        # Formater si nécessaire
        if ! blkid "$DEV" 2>/dev/null | grep -q ext4; then
            echo "  → Formatage ext4..."
            mkfs.ext4 -F -m0 -O dir_index,has_journal,extent "$DEV" >/dev/null
        fi
        
        # Monter
        mount "$DEV" "$BASE/data"
        
        # Ajouter au fstab
        UUID=$(blkid -s UUID -o value "$DEV")
        if ! grep -q "$BASE/data" /etc/fstab; then
            echo "UUID=$UUID $BASE/data ext4 defaults,nofail 0 2" >> /etc/fstab
        fi
        
        # Supprimer lost+found
        [ -d "$BASE/data/lost+found" ] && rm -rf "$BASE/data/lost+found"
        
        echo "  ✓ Volume monté sur $BASE/data"
    else
        echo "  ✓ Volume déjà monté"
    fi
    
    # UFW - Ouvrir les ports
    echo "  → Configuration UFW..."
    for port in 5432 5433 6432 8404; do
        ufw allow from any to any port $port proto tcp >/dev/null 2>&1 || true
    done
    
    # Configuration HAProxy avec API Patroni
    echo "  → Création haproxy.cfg..."
    cat > "$BASE/config/haproxy.cfg" <<EOF
global
    daemon
    maxconn 1000
    log stdout format raw local0

defaults
    mode tcp
    timeout connect 10s
    timeout client 30s
    timeout server 30s
    timeout check 5s
    log global
    option tcplog

# Frontend PostgreSQL Write (vers leader uniquement)
frontend postgres_write
    bind ${IP_PRIVEE}:5432
    default_backend postgres_master

# Frontend PostgreSQL Read (vers replicas en round-robin)
frontend postgres_read
    bind ${IP_PRIVEE}:5433
    default_backend postgres_replicas

# Frontend PgBouncer (sera configuré plus tard)
frontend pgbouncer_pool
    bind ${IP_PRIVEE}:6432
    default_backend postgres_master

# Backend Master (API Patroni: /master renvoie 200 si leader)
backend postgres_master
    option httpchk OPTIONS /master
    http-check expect status 200
    default-server inter 2s fastinter 1s rise 2 fall 3 on-marked-down shutdown-sessions
    server db-master-01 ${DB_MASTER}:5432 check port 8008
    server db-slave-01 ${DB_SLAVE1}:5432 check port 8008 backup
    server db-slave-02 ${DB_SLAVE2}:5432 check port 8008 backup

# Backend Replicas (API Patroni: /replica renvoie 200 si replica)
backend postgres_replicas
    balance roundrobin
    option httpchk OPTIONS /replica
    http-check expect status 200
    default-server inter 2s fastinter 1s rise 2 fall 3 on-marked-down shutdown-sessions
    server db-master-01 ${DB_MASTER}:5432 check port 8008
    server db-slave-01 ${DB_SLAVE1}:5432 check port 8008
    server db-slave-02 ${DB_SLAVE2}:5432 check port 8008

# Stats HAProxy
listen stats
    bind ${IP_PRIVEE}:8404
    mode http
    stats enable
    stats uri /
    stats refresh 5s
    stats show-legends
    stats show-node
EOF
    
    echo "  ✓ Configuration créée"
    
    # Arrêter l'ancien conteneur si présent
    docker rm -f haproxy 2>/dev/null || true
    
    # Démarrer HAProxy
    echo "  → Démarrage conteneur HAProxy..."
    docker run -d \
        --name haproxy \
        --hostname haproxy \
        --network host \
        --restart unless-stopped \
        -v "$BASE/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
        -v "$BASE/logs:/var/log/haproxy" \
        haproxy:2.9-alpine >/dev/null 2>&1
    
    sleep 3
    
    # Vérification
    if docker ps | grep -q "haproxy"; then
        echo "  ✓ Conteneur démarré"
    else
        echo "  ✗ Échec démarrage"
        docker logs haproxy 2>&1 | tail -10
        exit 1
    fi
    
    # Vérifier les ports
    echo "  → Vérification ports..."
    for port in 5432 5433 6432 8404; do
        if ss -tln | grep -q ":${port} "; then
            echo "    ✓ Port $port: En écoute"
        else
            echo "    ✗ Port $port: NON en écoute"
        fi
    done
    
    # État final
    echo "OK" > "$BASE/status/STATE"
HAPROXY_INSTALL
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Installation réussie"
    else
        echo -e "  $KO Échec installation"
        echo ""
        echo "  Logs disponibles: tail -f $LOG_FILE"
        exit 1
    fi
    
    echo ""
    sleep 2
done

echo ""
echo "═══ Tests de connectivité ═══"
echo ""

# Attendre que HAProxy soit prêt
sleep 5

# Test via haproxy-01
echo "Tests via haproxy-01 ($HAPROXY1_IP):"

# Test Write (port 5432)
echo -n "  • PostgreSQL Write (5432): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 5432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test Read (port 5433)
echo -n "  • PostgreSQL Read (5433): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 5433 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test Stats
echo -n "  • HAProxy Stats (8404): "
if curl -sf "http://${HAPROXY1_IP}:8404/" | grep -q "Statistics" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Installation HAProxy terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Architecture Load Balancing:"
echo ""
echo "   Applications"
echo "        ↓"
echo "   10.0.0.10 (Load Balancer Hetzner)"
echo "        ↓"
echo "   ├─→ haproxy-01 ($HAPROXY1_IP)"
echo "   └─→ haproxy-02 ($HAPROXY2_IP)"
echo "        ↓"
echo "   ├─→ db-master-01 ($DB_MASTER_IP) - Leader"
echo "   ├─→ db-slave-01 ($DB_SLAVE1_IP) - Replica"
echo "   └─→ db-slave-02 ($DB_SLAVE2_IP) - Replica"
echo ""
echo "🔌 Ports disponibles:"
echo "   • 5432 : PostgreSQL Write (Leader automatique via Patroni API)"
echo "   • 5433 : PostgreSQL Read (Replicas en round-robin)"
echo "   • 6432 : PgBouncer (à configurer ensuite)"
echo "   • 8404 : HAProxy Stats"
echo ""
echo "📈 Stats HAProxy:"
echo "   http://${HAPROXY1_IP}:8404/"
echo "   http://${HAPROXY2_IP}:8404/"
echo ""
echo "✅ HAProxy utilise l'API Patroni pour détecter automatiquement:"
echo "   • /master  : Retourne 200 si le nœud est leader"
echo "   • /replica : Retourne 200 si le nœud est replica"
echo ""
echo "⚡ Test depuis une application:"
echo "   PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 5432 -U postgres -d postgres -c 'SELECT 1'"
echo ""
echo "📋 Prochaine étape: PgBouncer avec SCRAM-SHA-256"
echo "   bash 06_pgbouncer_scram_final.sh"
echo ""

# Logs finaux
echo "═══ Logs HAProxy (50 dernières lignes) ═══"
echo ""
tail -n 50 "$LOG_DIR/haproxy_haproxy-01.log" 2>/dev/null || echo "Aucun log disponible"
