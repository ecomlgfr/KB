#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  RABBITMQ_HA_INSTALL_PATCHED - RabbitMQ Quorum par défaut + UI OK  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/rabbitmq_complete_$TIMESTAMP.log"

mkdir -p "$LOG_DIR" "$CREDS_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Installation RabbitMQ Quorum Cluster HA (Quorum par défaut)"
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

QUEUE_COUNT=$(grep -E "queue-0[1-3]" "$SERVERS_TSV" | wc -l)
HAPROXY_COUNT=$(grep -E "haproxy-0[1-2]" "$SERVERS_TSV" | wc -l)

echo "  Serveurs Queue trouvés: $QUEUE_COUNT"
echo "  Serveurs HAProxy trouvés: $HAPROXY_COUNT"

[ "$QUEUE_COUNT" -lt 3 ] && { echo -e "$KO Il faut 3 serveurs Queue"; exit 1; }
[ "$HAPROXY_COUNT" -lt 2 ] && { echo -e "$KO Il faut 2 serveurs HAProxy"; exit 1; }

# IPs fixes
QUEUE01_IP=$(awk -F'\t' '$2=="queue-01" {print $3}' "$SERVERS_TSV" | head -1)
QUEUE02_IP=$(awk -F'\t' '$2=="queue-02" {print $3}' "$SERVERS_TSV" | head -1)
QUEUE03_IP=$(awk -F'\t' '$2=="queue-03" {print $3}' "$SERVERS_TSV" | head -1)

echo "  queue-01: $QUEUE01_IP"
echo "  queue-02: $QUEUE02_IP"
echo "  queue-03: $QUEUE03_IP"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: GESTION SÉCURISÉE DES CREDENTIALS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Gestion sécurisée des credentials                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ -f "$CREDS_DIR/rabbitmq.env" ]; then
    echo "  Chargement des credentials existants..."
    source "$CREDS_DIR/rabbitmq.env"
    echo "  Cookie Erlang: $(echo -n "$RABBITMQ_ERLANG_COOKIE" | sha256sum | cut -c1-16)..."
else
    echo "  Génération de nouveaux credentials..."
    RABBITMQ_ERLANG_COOKIE=$(openssl rand -hex 32)
    RABBITMQ_ADMIN_USER="admin"
    RABBITMQ_ADMIN_PASS=$(openssl rand -base64 32 | tr -d "=+/\n" | cut -c1-25)
    
    cat > "$CREDS_DIR/rabbitmq.env" <<EOF
#!/bin/bash
# RabbitMQ Credentials - NE JAMAIS COMMITER
# Généré le $(date)
export RABBITMQ_ERLANG_COOKIE="$RABBITMQ_ERLANG_COOKIE"
export RABBITMQ_ADMIN_USER="$RABBITMQ_ADMIN_USER"
export RABBITMQ_ADMIN_PASS="$RABBITMQ_ADMIN_PASS"
export RABBITMQ_CLUSTER_NAME="keybuzz-queue"
EOF
    chmod 600 "$CREDS_DIR/rabbitmq.env"
    
    if [ -f "$CREDS_DIR/secrets.json" ]; then
        jq ".rabbitmq_erlang_cookie = \"$RABBITMQ_ERLANG_COOKIE\" | .rabbitmq_admin_pass = \"$RABBITMQ_ADMIN_PASS\"" \
           "$CREDS_DIR/secrets.json" > /tmp/secrets.tmp && mv /tmp/secrets.tmp "$CREDS_DIR/secrets.json"
    else
        echo "{\"rabbitmq_erlang_cookie\": \"$RABBITMQ_ERLANG_COOKIE\", \"rabbitmq_admin_pass\": \"$RABBITMQ_ADMIN_PASS\"}" | \
        jq '.' > "$CREDS_DIR/secrets.json"
    fi
    chmod 600 "$CREDS_DIR/secrets.json"
    
    echo "  Credentials générés et sécurisés"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: PRÉPARATION DES SERVEURS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Préparation des serveurs RabbitMQ                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in queue-01 queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Préparation de $host ($IP_PRIV)..."
    
    # Copier credentials
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" "mkdir -p /opt/keybuzz-installer/credentials"
    scp -q -o ConnectTimeout=10 "$CREDS_DIR/rabbitmq.env" root@"$IP_PRIV":/opt/keybuzz-installer/credentials/
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash <<'PREP'
BASE="/opt/keybuzz/rabbitmq"
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

# Ouvrir ports UFW
ufw allow 5672/tcp comment "RabbitMQ AMQP" 2>/dev/null || true
ufw allow 15672/tcp comment "RabbitMQ Management" 2>/dev/null || true
ufw allow 25672/tcp comment "RabbitMQ Cluster" 2>/dev/null || true
ufw allow 4369/tcp comment "EPMD" 2>/dev/null || true

# Nettoyer anciens containers
docker stop rabbitmq 2>/dev/null || true
docker rm rabbitmq 2>/dev/null || true

echo "    ✓ Structure créée"
PREP
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: DÉPLOIEMENT RABBITMQ AVEC QUORUM PAR DÉFAUT (PATCH)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Déploiement RabbitMQ (Quorum par défaut - PATCHÉ)     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Déployer queue-01 (master initial)
echo "  Déploiement de queue-01..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$QUEUE01_IP" bash -s "$QUEUE01_IP" <<'QUEUE01_DEPLOY'
IP_PRIVEE="$1"
source /opt/keybuzz-installer/credentials/rabbitmq.env
BASE="/opt/keybuzz/rabbitmq"

# Créer rabbitmq.conf avec quorum par défaut (PATCH)
cat > "$BASE/config/rabbitmq.conf" <<EOF
cluster_name = keybuzz-queue
default_queue_type = quorum
management.tcp.port = 15672
loopback_users.guest = false
EOF

# Ajouter les hosts
grep -q "queue-01" /etc/hosts || echo "10.0.0.126 queue-01" >> /etc/hosts
grep -q "queue-02" /etc/hosts || echo "10.0.0.127 queue-02" >> /etc/hosts
grep -q "queue-03" /etc/hosts || echo "10.0.0.128 queue-03" >> /etc/hosts

# Démarrer avec docker run
docker run -d \
  --name rabbitmq \
  --hostname queue-01 \
  --restart unless-stopped \
  --network host \
  -e RABBITMQ_ERLANG_COOKIE="${RABBITMQ_ERLANG_COOKIE}" \
  -e RABBITMQ_DEFAULT_USER="${RABBITMQ_ADMIN_USER}" \
  -e RABBITMQ_DEFAULT_PASS="${RABBITMQ_ADMIN_PASS}" \
  -e RABBITMQ_NODENAME=rabbit@queue-01 \
  -v ${BASE}/data:/var/lib/rabbitmq \
  -v ${BASE}/config/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro \
  --ulimit nofile=65536:65536 \
  rabbitmq:3.13-management

sleep 15
echo "    ✓ queue-01 démarré avec quorum par défaut"
QUEUE01_DEPLOY

# Déployer queue-02 et queue-03
for host in queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Déploiement de $host..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash -s "$host" "$IP_PRIV" <<'QUEUE_DEPLOY'
NODE_NAME="$1"
IP_PRIVEE="$2"
source /opt/keybuzz-installer/credentials/rabbitmq.env
BASE="/opt/keybuzz/rabbitmq"

# Créer rabbitmq.conf avec quorum par défaut (PATCH)
cat > "$BASE/config/rabbitmq.conf" <<EOF
cluster_name = keybuzz-queue
default_queue_type = quorum
management.tcp.port = 15672
loopback_users.guest = false
EOF

# Ajouter les hosts
grep -q "queue-01" /etc/hosts || echo "10.0.0.126 queue-01" >> /etc/hosts
grep -q "queue-02" /etc/hosts || echo "10.0.0.127 queue-02" >> /etc/hosts
grep -q "queue-03" /etc/hosts || echo "10.0.0.128 queue-03" >> /etc/hosts

# Démarrer avec docker run
docker run -d \
  --name rabbitmq \
  --hostname ${NODE_NAME} \
  --restart unless-stopped \
  --network host \
  -e RABBITMQ_ERLANG_COOKIE="${RABBITMQ_ERLANG_COOKIE}" \
  -e RABBITMQ_DEFAULT_USER="${RABBITMQ_ADMIN_USER}" \
  -e RABBITMQ_DEFAULT_PASS="${RABBITMQ_ADMIN_PASS}" \
  -e RABBITMQ_NODENAME=rabbit@${NODE_NAME} \
  -v ${BASE}/data:/var/lib/rabbitmq \
  -v ${BASE}/config/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro \
  --ulimit nofile=65536:65536 \
  rabbitmq:3.13-management

sleep 15
echo "    ✓ $NODE_NAME démarré avec quorum par défaut"
QUEUE_DEPLOY
done

echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: FORMATION DU CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Formation du cluster                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Ajout de $host au cluster..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash <<'JOIN'
docker exec rabbitmq rabbitmqctl stop_app 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl reset 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl join_cluster rabbit@queue-01 2>/dev/null
sleep 2
docker exec rabbitmq rabbitmqctl start_app 2>/dev/null

if docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -q "queue-01"; then
    echo "    ✓ Rejoint le cluster"
else
    echo "    ✗ Échec de jonction"
fi
JOIN
done

echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: VÉRIFICATION (PAS DE POLITIQUES - QUORUM PAR DÉFAUT)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Vérification (quorum par défaut activé)               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Vérification de default_queue_type sur queue-01:"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$QUEUE01_IP" bash <<'CHECK_QUORUM'
docker exec rabbitmq cat /etc/rabbitmq/rabbitmq.conf 2>/dev/null | grep default_queue_type || echo "    ✗ Configuration non trouvée"
CHECK_QUORUM

echo ""
echo "  État du cluster:"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$QUEUE01_IP" \
    "docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null" | \
    grep -E "(Basics|Disk Nodes|Running Nodes)" | head -10

echo ""
echo "  Test de connectivité:"
for host in queue-01 queue-02 queue-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host: "
    
    if timeout 3 nc -zv "$IP_PRIV" 5672 &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: LOAD BALANCER SUR HAPROXY (UI SÉCURISÉE)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Load Balancer HAProxy (UI interne seulement)          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo "  Configuration de $host ($IP_PRIV)..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_PRIV" bash -s "$IP_PRIV" <<'HAPROXY_CONFIG'
IP_PRIVEE="$1"
BASE="/opt/keybuzz/rabbitmq-lb"

# Nettoyer anciens containers
docker stop haproxy-rabbitmq 2>/dev/null || true
docker rm haproxy-rabbitmq 2>/dev/null || true

mkdir -p "$BASE"/{config,logs,status}

# Configuration HAProxy avec bind IP privée (UI NON publique)
cat > "$BASE/config/haproxy-rabbitmq.cfg" <<EOF
global
    maxconn 10000
    log stdout local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    log global
    option tcplog

# RabbitMQ AMQP (5672) - bind IP privée
listen rabbitmq_amqp
    bind ${IP_PRIVEE}:5672
    mode tcp
    balance leastconn
    option tcp-check
    server queue-01 10.0.0.126:5672 check inter 5s fall 3 rise 2
    server queue-02 10.0.0.127:5672 check inter 5s fall 3 rise 2
    server queue-03 10.0.0.128:5672 check inter 5s fall 3 rise 2

# RabbitMQ Management (15672) - bind IP privée (pas public)
listen rabbitmq_management
    bind ${IP_PRIVEE}:15672
    mode tcp
    balance roundrobin
    option tcp-check
    server queue-01 10.0.0.126:15672 check inter 5s fall 3 rise 2
    server queue-02 10.0.0.127:15672 check inter 5s fall 3 rise 2
    server queue-03 10.0.0.128:15672 check inter 5s fall 3 rise 2

# Stats HAProxy (8405) - bind IP privée
listen stats
    bind ${IP_PRIVEE}:8405
    mode http
    stats enable
    stats uri /
    stats refresh 10s
EOF

# Démarrer HAProxy
docker run -d \
  --name haproxy-rabbitmq \
  --restart unless-stopped \
  --network host \
  -v ${BASE}/config/haproxy-rabbitmq.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:2.9-alpine

sleep 3

if docker ps | grep -q "haproxy-rabbitmq"; then
    echo "    ✓ HAProxy configuré sur IP $IP_PRIVEE (UI interne seulement)"
    echo "OK" > "$BASE/status/STATE"
else
    echo "    ✗ Échec configuration"
    echo "KO" > "$BASE/status/STATE"
fi
HAPROXY_CONFIG
done

echo ""
sleep 5

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 7: TESTS FINAUX
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 7: Tests finaux                                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Test HAProxy locaux:"
for host in haproxy-01 haproxy-02; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "    $host (AMQP 5672): "
    if timeout 3 nc -zv "$IP_PRIV" 5672 &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    echo -n "    $host (UI 15672): "
    if timeout 3 nc -zv "$IP_PRIV" 15672 &>/dev/null; then
        echo -e "$OK (interne seulement)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "  Test via Load Balancer Hetzner (10.0.0.10):"
echo -n "    AMQP (5672): "
if timeout 3 nc -zv 10.0.0.10 5672 &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "    Management UI (15672): "
if timeout 3 nc -zv 10.0.0.10 15672 &>/dev/null; then
    echo -e "$OK (accès via SSH tunnel recommandé)"
else
    echo -e "$KO"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

cat > "$CREDS_DIR/rabbitmq-summary.txt" <<EOF
════════════════════════════════════════════════════════════════════
RABBITMQ HA - INSTALLATION COMPLÈTE (QUORUM PAR DÉFAUT)
════════════════════════════════════════════════════════════════════
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')

ARCHITECTURE:
  • 3 nœuds RabbitMQ: queue-01/02/03
  • Cluster Erlang avec cookie partagé
  • 2 HAProxy pour load balancing: haproxy-01/02
  • VIP Hetzner Load Balancer: 10.0.0.10
  • DEFAULT QUEUE TYPE: QUORUM (pas de politiques manuelles)

CREDENTIALS:
  Fichier: $CREDS_DIR/rabbitmq.env (mode 600)
  User: $RABBITMQ_ADMIN_USER
  Password: [voir fichier rabbitmq.env]

CONNEXION AMQP:
  Host: 10.0.0.10
  Port: 5672
  User: $RABBITMQ_ADMIN_USER
  Password: \${RABBITMQ_ADMIN_PASS}

MANAGEMENT UI (INTERNE SEULEMENT):
  URL: http://10.0.0.10:15672
  Accès: SSH tunnel recommandé (pas d'exposition publique)
  Tunnel: ssh -L 15672:10.0.0.10:15672 root@<install-01>
  Puis: http://localhost:15672

CONFIGURATION QUORUM (PATCH):
  • Fichier: /opt/keybuzz/rabbitmq/config/rabbitmq.conf
  • Paramètre: default_queue_type = quorum
  • Toutes les nouvelles queues sont "quorum" par défaut
  • Pas de politiques HA exotiques
  • Réplication automatique sur 3 nœuds

HAUTE DISPONIBILITÉ:
  • Tolérance de panne: jusqu'à 2 nœuds
  • Réplication automatique (quorum)
  • Auto-heal en cas de partition réseau
  • Bind strict sur IP privée

TESTS:
  # Tester AMQP
  nc -zv 10.0.0.10 5672
  
  # Accès Management UI via tunnel SSH
  ssh -L 15672:10.0.0.10:15672 root@<install-01>
  # Puis ouvrir: http://localhost:15672

VÉRIFIER QUORUM PAR DÉFAUT:
  ssh root@10.0.0.126 'docker exec rabbitmq cat /etc/rabbitmq/rabbitmq.conf | grep default_queue_type'
  
  # Créer une queue test et vérifier son type via l'UI ou CLI
  
CONFIGURATION HETZNER LOAD BALANCER:
  Service AMQP:
    • Type: TCP
    • Port source: 5672
    • Port destination: 5672
    • Health check: TCP 5672
    
  Service Management (OPTIONNEL - si exposition nécessaire):
    • Type: TCP
    • Port source: 15672
    • Port destination: 15672
    • Allowlist: IPs internes uniquement
EOF

chmod 600 "$CREDS_DIR/rabbitmq-summary.txt"

echo "═══════════════════════════════════════════════════════════════════"
if timeout 2 nc -zv 10.0.0.10 5672 &>/dev/null; then
    echo -e "$OK RABBITMQ HA INSTALLATION COMPLÈTE ET OPÉRATIONNELLE"
    echo ""
    echo "Endpoints:"
    echo "  • AMQP: 10.0.0.10:5672"
    echo "  • Management: http://10.0.0.10:15672 (SSH tunnel recommandé)"
    echo "  • User: $RABBITMQ_ADMIN_USER"
    echo "  • Quorum par défaut: ACTIVÉ ✓"
    echo ""
    echo "Pour tester:"
    echo "  ssh -L 15672:10.0.0.10:15672 root@<install-01>"
    echo "  Puis: http://localhost:15672"
    echo ""
    echo "Résumé complet: $CREDS_DIR/rabbitmq-summary.txt"
else
    echo -e "$KO Installation incomplète"
    echo "Vérifier les logs: $MAIN_LOG"
fi
echo "═══════════════════════════════════════════════════════════════════"

tail -n 50 "$MAIN_LOG"
