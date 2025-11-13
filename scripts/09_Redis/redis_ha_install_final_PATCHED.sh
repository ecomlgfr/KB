#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   REDIS_HA_INSTALL_FINAL_PATCHED - Redis HA avec Watcher Sentinel  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/redis_install_$TIMESTAMP.log"

mkdir -p "$LOG_DIR" "$CREDS_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Installation Redis HA - Architecture complète (IP privée + Watcher)"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS PRÉALABLES
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

REDIS_COUNT=$(grep -E "redis-0[1-3]" "$SERVERS_TSV" | wc -l)
HAPROXY_COUNT=$(grep -E "haproxy-0[1-2]" "$SERVERS_TSV" | wc -l)

echo "  Serveurs Redis trouvés: $REDIS_COUNT"
echo "  Serveurs HAProxy trouvés: $HAPROXY_COUNT"

[ "$REDIS_COUNT" -lt 3 ] && { echo -e "$KO Il faut 3 serveurs Redis"; exit 1; }
[ "$HAPROXY_COUNT" -lt 2 ] && { echo -e "$KO Il faut 2 serveurs HAProxy"; exit 1; }

if ! command -v redis-cli &>/dev/null; then
    echo "  Installation de redis-cli sur install-01..."
    apt-get update -qq && apt-get install -y -qq redis-tools
fi

if ! command -v nc &>/dev/null; then
    echo "  Installation de netcat..."
    apt-get install -y -qq netcat-openbsd
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: GESTION SÉCURISÉE DES CREDENTIALS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Gestion sécurisée des credentials                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ -f "$CREDS_DIR/redis.env" ]; then
    echo "  Chargement des credentials existants..."
    source "$CREDS_DIR/redis.env"
    echo "  Hash du mot de passe: $(echo -n "$REDIS_PASSWORD" | sha256sum | cut -c1-16)..."
else
    echo "  Génération d'un nouveau mot de passe sécurisé..."
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/\n" | cut -c1-32)
    
    cat > "$CREDS_DIR/redis.env" <<EOF
#!/bin/bash
# Redis Credentials - NE JAMAIS COMMITER
# Généré le $(date)
export REDIS_PASSWORD="$REDIS_PASSWORD"
export REDIS_MASTER_NAME="mymaster"
export REDIS_SENTINEL_QUORUM="2"
EOF
    chmod 600 "$CREDS_DIR/redis.env"
    
    if [ -f "$CREDS_DIR/secrets.json" ]; then
        jq ".redis_password = \"$REDIS_PASSWORD\"" "$CREDS_DIR/secrets.json" > /tmp/secrets.tmp && \
        mv /tmp/secrets.tmp "$CREDS_DIR/secrets.json"
    else
        echo "{\"redis_password\": \"$REDIS_PASSWORD\"}" | jq '.' > "$CREDS_DIR/secrets.json"
    fi
    chmod 600 "$CREDS_DIR/secrets.json"
    
    echo "  Mot de passe généré et sécurisé"
    echo "  Hash: $(echo -n "$REDIS_PASSWORD" | sha256sum | cut -c1-16)..."
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: PRÉPARATION DES SERVEURS REDIS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Préparation des serveurs Redis                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "$KO IP de $host non trouvée"; continue; }
    
    echo "  Préparation de $host ($IP_PRIV)..."
    
    # Copier credentials
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" "mkdir -p /opt/keybuzz-installer/credentials"
    scp -q -o ConnectTimeout=10 "$CREDS_DIR/redis.env" root@"$IP_PRIV":/opt/keybuzz-installer/credentials/
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash -s "$IP_PRIV" <<'PREP'
IP_PRIVEE="$1"
BASE="/opt/keybuzz/redis"
mkdir -p "$BASE"/{data,config,logs,status}

# Vérifier/monter volume si disponible
if ! mountpoint -q "$BASE/data"; then
    DEV=""
    for c in /dev/disk/by-id/scsi-* /dev/sd[b-z] /dev/vd[b-z]; do
        [ -e "$c" ] || continue
        real=$(readlink -f "$c" 2>/dev/null || echo "$c")
        mount | grep -q " $real " && continue
        DEV="$real"
        break
    done
    
    if [ -n "$DEV" ]; then
        blkid "$DEV" 2>/dev/null | grep -q ext4 || mkfs.ext4 -F -m0 -O dir_index,has_journal,extent "$DEV" >/dev/null 2>&1
        mount "$DEV" "$BASE/data" 2>/dev/null
        UUID=$(blkid -s UUID -o value "$DEV")
        grep -q " $BASE/data " /etc/fstab || echo "UUID=$UUID $BASE/data ext4 defaults,nofail 0 2" >> /etc/fstab
        [ -d "$BASE/data/lost+found" ] && rm -rf "$BASE/data/lost+found"
    fi
fi

# Nettoyer anciens containers
docker stop redis sentinel 2>/dev/null || true
docker rm redis sentinel 2>/dev/null || true

echo "    ✓ Structure créée"
PREP
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: DÉPLOIEMENT REDIS + SENTINEL
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Déploiement Redis + Sentinel                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Déployer le premier Redis (master initial)
FIRST_HOST="redis-01"
FIRST_IP=$(awk -F'\t' -v h="$FIRST_HOST" '$2==h {print $3}' "$SERVERS_TSV")

echo "  Déploiement de $FIRST_HOST comme master initial..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$FIRST_IP" bash -s "$FIRST_IP" <<'FIRST_REDIS'
IP_PRIVEE="$1"
source /opt/keybuzz-installer/credentials/redis.env
BASE="/opt/keybuzz/redis"

# Redis Master
docker run -d --name redis --restart unless-stopped \
  --network host \
  -v "$BASE/data":/data \
  redis:7-alpine redis-server \
    --bind "$IP_PRIVEE" \
    --port 6379 \
    --requirepass "$REDIS_PASSWORD" \
    --masterauth "$REDIS_PASSWORD" \
    --appendonly yes \
    --save 900 1 \
    --save 300 10 \
    --maxmemory-policy allkeys-lru

sleep 3

# Sentinel
docker run -d --name sentinel --restart unless-stopped \
  --network host \
  redis:7-alpine redis-sentinel - <<EOF
port 26379
bind $IP_PRIVEE
sentinel monitor mymaster $IP_PRIVEE 6379 2
sentinel auth-pass mymaster $REDIS_PASSWORD
sentinel down-after-milliseconds mymaster 5000
sentinel parallel-syncs mymaster 1
sentinel failover-timeout mymaster 10000
EOF

sleep 2
echo "    ✓ Redis Master + Sentinel démarrés"
FIRST_REDIS

sleep 10

# Déployer les réplicas
for host in redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Déploiement de $host comme replica..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash -s "$FIRST_IP" "$IP_PRIV" <<'REPLICA_REDIS'
MASTER_IP="$1"
IP_PRIVEE="$2"
source /opt/keybuzz-installer/credentials/redis.env
BASE="/opt/keybuzz/redis"

# Redis Replica
docker run -d --name redis --restart unless-stopped \
  --network host \
  -v "$BASE/data":/data \
  redis:7-alpine redis-server \
    --bind "$IP_PRIVEE" \
    --port 6379 \
    --requirepass "$REDIS_PASSWORD" \
    --masterauth "$REDIS_PASSWORD" \
    --replicaof "$MASTER_IP" 6379 \
    --appendonly yes \
    --maxmemory-policy allkeys-lru

sleep 3

# Sentinel
docker run -d --name sentinel --restart unless-stopped \
  --network host \
  redis:7-alpine redis-sentinel - <<EOF
port 26379
bind $IP_PRIVEE
sentinel monitor mymaster $MASTER_IP 6379 2
sentinel auth-pass mymaster $REDIS_PASSWORD
sentinel down-after-milliseconds mymaster 5000
sentinel parallel-syncs mymaster 1
sentinel failover-timeout mymaster 10000
EOF

sleep 2
echo "    ✓ Redis Replica + Sentinel démarrés"
REPLICA_REDIS
done

echo ""
sleep 15

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: VÉRIFICATION CLUSTER REDIS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Vérification du cluster Redis                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Déterminer le master actuel via Sentinel
MASTER_IP=$(timeout 3 redis-cli -h "$FIRST_IP" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
[ -z "$MASTER_IP" ] && MASTER_IP="$FIRST_IP"

echo "  Master actuel détecté: $MASTER_IP"
echo ""

echo "  Test de connexion Redis:"
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host: "
    
    if timeout 3 bash -c "echo -e 'AUTH $REDIS_PASSWORD\nPING\nQUIT' | nc -w 2 '$IP_PRIV' 6379 2>/dev/null | grep -q '+PONG'"; then
        ROLE=$(timeout 3 redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        echo -e "$OK (role: ${ROLE:-unknown})"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "  Test des Sentinels:"
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host: "
    
    MASTER=$(timeout 2 redis-cli -h "$IP_PRIV" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
    if [ -n "$MASTER" ]; then
        echo -e "$OK (voit master: $MASTER)"
    else
        echo -e "$KO"
    fi
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: LOAD BALANCER AVEC WATCHER SENTINEL (PATCH)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Load Balancer avec Watcher Sentinel (PATCHÉ)          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# IPs des Sentinels
SENT1=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV" | head -1)
SENT2=$(awk -F'\t' '$2=="redis-02" {print $3}' "$SERVERS_TSV" | head -1)
SENT3=$(awk -F'\t' '$2=="redis-03" {print $3}' "$SERVERS_TSV" | head -1)

for host in haproxy-01 haproxy-02; do
    IP_PROXY=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PROXY" ] && { echo -e "$KO IP de $host non trouvée"; continue; }
    
    echo "  Configuration $host ($IP_PROXY) avec watcher..."
    
    # Copier credentials
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PROXY" "mkdir -p /opt/keybuzz-installer/credentials"
    scp -q -o ConnectTimeout=10 "$CREDS_DIR/redis.env" root@"$IP_PROXY":/opt/keybuzz-installer/credentials/
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PROXY" bash -s "$MASTER_IP" "$SENT1" "$SENT2" "$SENT3" "$IP_PROXY" <<'HAPROXY_WATCHER'
MASTER_IP="$1"
SENT1="$2"
SENT2="$3"
SENT3="$4"
IP_PRIVEE="$5"

source /opt/keybuzz-installer/credentials/redis.env
BASE="/opt/keybuzz/redis-lb"

# Nettoyer anciens containers
docker stop haproxy-redis redis-sentinel-watcher 2>/dev/null || true
docker rm haproxy-redis redis-sentinel-watcher 2>/dev/null || true

mkdir -p "$BASE"/{config,bin,logs,status}

# Configuration HAProxy (BIND IP PRIVÉE)
cat > "$BASE/config/haproxy-redis.cfg" <<EOF
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global

listen redis_master
    bind ${IP_PRIVEE}:6379
    mode tcp
    balance first
    option tcp-check
    tcp-check send AUTH\ ${REDIS_PASSWORD}\r\n
    tcp-check expect string +OK
    tcp-check send PING\r\n
    tcp-check expect string +PONG
    tcp-check send QUIT\r\n
    tcp-check expect string +OK
    server redis-master ${MASTER_IP}:6379 check inter 2s fall 3 rise 2
EOF

echo "$MASTER_IP" > "$BASE/status/current_master"

# Script watcher Sentinel
cat > "$BASE/bin/watcher.sh" <<'WATCH'
#!/bin/bash
set -u
set -o pipefail
BASE="/opt/keybuzz/redis-lb"
CFG="$BASE/config/haproxy-redis.cfg"
CUR="$BASE/status/current_master"
SENT1="SENTINEL1"
SENT2="SENTINEL2"
SENT3="SENTINEL3"
NAME="mymaster"

mkdir -p "$BASE/status"

while true; do
  NEW=$(redis-cli -h "$SENT1" -p 26379 SENTINEL get-master-addr-by-name "$NAME" 2>/dev/null | sed -n '1p')
  [ -z "$NEW" ] && NEW=$(redis-cli -h "$SENT2" -p 26379 SENTINEL get-master-addr-by-name "$NAME" 2>/dev/null | sed -n '1p')
  [ -z "$NEW" ] && NEW=$(redis-cli -h "$SENT3" -p 26379 SENTINEL get-master-addr-by-name "$NAME" 2>/dev/null | sed -n '1p')
  
  if [ -n "$NEW" ] && [ "$NEW" != "$(cat "$CUR" 2>/dev/null || true)" ]; then
    sed -i "s#^\s*server redis-master .*#    server redis-master ${NEW}:6379 check inter 2s fall 3 rise 2#" "$CFG"
    echo "$NEW" > "$CUR"
    docker kill -s HUP haproxy-redis >/dev/null 2>&1 || docker restart haproxy-redis >/dev/null 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Master changé: $NEW" >> "$BASE/logs/watcher.log"
  fi
  sleep 5
done
WATCH

# Remplacer les IPs Sentinel dans le watcher
sed -i "s#SENTINEL1#$SENT1#g" "$BASE/bin/watcher.sh"
sed -i "s#SENTINEL2#$SENT2#g" "$BASE/bin/watcher.sh"
sed -i "s#SENTINEL3#$SENT3#g" "$BASE/bin/watcher.sh"
chmod +x "$BASE/bin/watcher.sh"

# Démarrer HAProxy
docker run -d \
  --name haproxy-redis \
  --restart unless-stopped \
  --network host \
  -v ${BASE}/config/haproxy-redis.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.9-alpine

sleep 2

# Démarrer le watcher Sentinel
docker run -d --name redis-sentinel-watcher \
  --restart unless-stopped \
  -v /opt/keybuzz/redis-lb:/opt/keybuzz/redis-lb \
  --network host \
  alpine:3.20 sh -c "apk add --no-cache redis bash >/dev/null 2>&1 && bash /opt/keybuzz/redis-lb/bin/watcher.sh"

sleep 2

if docker ps | grep -q "haproxy-redis" && docker ps | grep -q "redis-sentinel-watcher"; then
    echo "    ✓ HAProxy + Watcher configurés sur IP $IP_PRIVEE:6379"
    echo "OK" > "$BASE/status/STATE"
else
    echo "    ✗ Échec configuration"
    echo "KO" > "$BASE/status/STATE"
fi
HAPROXY_WATCHER
done

echo ""
sleep 5

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: TESTS FINAUX AVEC FAILOVER
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Tests finaux + Failover                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Test HAProxy locaux:"
for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host: "
    
    if timeout 3 redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "  Test via Load Balancer Hetzner (10.0.0.10:6379):"
echo -n "    PING: "
if timeout 3 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "    SET/GET: "
if timeout 3 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET test_key "test_value" 2>/dev/null | grep -q "OK"; then
    VAL=$(timeout 3 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning GET test_key 2>/dev/null)
    if [ "$VAL" = "test_value" ]; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
else
    echo -e "$KO"
fi

echo ""
echo "  Test de failover automatique (simulation):"
echo "    1. Détection du master actuel..."
CURRENT_MASTER=$(timeout 3 redis-cli -h "$FIRST_IP" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
echo "       Master: $CURRENT_MASTER"

echo "    2. Pour tester le failover manuellement:"
echo "       ssh root@$CURRENT_MASTER 'docker stop redis'"
echo "       Attendre 10-15s puis vérifier que le watcher a mis à jour HAProxy"
echo "       Vérifier: redis-cli -h 10.0.0.10 -p 6379 -a \"\$REDIS_PASSWORD\" PING"

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

cat > "$CREDS_DIR/redis-summary.txt" <<EOF
════════════════════════════════════════════════════════════════════
REDIS HA - INSTALLATION COMPLÈTE (PATCHÉ)
════════════════════════════════════════════════════════════════════
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')

ARCHITECTURE:
  • 3 nœuds Redis: redis-01/02/03
  • 3 Sentinels (ports 26379)
  • 2 HAProxy avec watcher automatique: haproxy-01/02
  • VIP Hetzner Load Balancer: 10.0.0.10

CREDENTIALS:
  Fichier: $CREDS_DIR/redis.env (mode 600)
  Password: [voir fichier redis.env]

CONNEXION APPLICATIONS:
  Host: 10.0.0.10
  Port: 6379
  Password: \${REDIS_PASSWORD}
  
HAUTE DISPONIBILITÉ:
  • Bind strict sur IP privée (pas 0.0.0.0)
  • Watcher Sentinel actif (vérifie toutes les 5s)
  • Failover automatique < 30s
  • Bascule HAProxy transparente

WATCHER SENTINEL:
  Logs: /opt/keybuzz/redis-lb/logs/watcher.log (sur haproxy-01/02)
  État: /opt/keybuzz/redis-lb/status/current_master

TESTS:
  redis-cli -h 10.0.0.10 -p 6379 -a "\$REDIS_PASSWORD" PING
  redis-cli -h 10.0.0.10 -p 6379 -a "\$REDIS_PASSWORD" SET key value
  redis-cli -h 10.0.0.10 -p 6379 -a "\$REDIS_PASSWORD" GET key

FAILOVER MANUEL (test):
  1. Identifier master: redis-cli -h <sentinel> -p 26379 SENTINEL get-master-addr-by-name mymaster
  2. Stopper: ssh root@<master_ip> 'docker stop redis'
  3. Vérifier bascule: redis-cli -h 10.0.0.10 -p 6379 -a "\$REDIS_PASSWORD" PING
  4. Le watcher met à jour HAProxy automatiquement
EOF

chmod 600 "$CREDS_DIR/redis-summary.txt"

echo "═══════════════════════════════════════════════════════════════════"
if timeout 3 redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING &>/dev/null; then
    echo -e "$OK REDIS HA INSTALLATION COMPLÈTE ET OPÉRATIONNELLE"
    echo ""
    echo "Endpoint: 10.0.0.10:6379"
    echo "Password: [voir $CREDS_DIR/redis.env]"
    echo "Watcher Sentinel: ACTIF (vérifie toutes les 5s)"
    echo "Bind: IP privée uniquement (sécurisé)"
    echo ""
    echo "Résumé complet: $CREDS_DIR/redis-summary.txt"
    echo "Logs: tail -n 50 $MAIN_LOG"
else
    echo -e "$KO Installation incomplète"
    echo "Vérifier les logs: $MAIN_LOG"
fi
echo "═══════════════════════════════════════════════════════════════════"

tail -n 50 "$MAIN_LOG"
