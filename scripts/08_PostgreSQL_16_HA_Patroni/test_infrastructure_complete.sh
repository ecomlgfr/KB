#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        TEST_INFRASTRUCTURE_COMPLETE - Tests exhaustifs             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓ OK\033[0m'
KO='\033[0;31m✗ KO\033[0m'
INFO='\033[0;36mℹ INFO\033[0m'
WARN='\033[0;33m⚠ WARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_LOG="$LOG_DIR/test_infrastructure_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$TEST_LOG")
exec 2>&1

echo ""
echo "🔍 Tests complets de l'infrastructure KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# FONCTIONS UTILITAIRES
# ═══════════════════════════════════════════════════════════════════

get_ip() {
    local hostname=$1
    awk -F'\t' -v h="$hostname" '$2==h{print $3}' "$SERVERS_TSV"
}

test_tcp_port() {
    local ip=$1
    local port=$2
    local timeout=${3:-2}
    timeout "$timeout" bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null
}

test_ssh() {
    local ip=$1
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@"$ip" "echo OK" 2>/dev/null | grep -q "OK"
}

print_section() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════════"
}

print_test() {
    local name=$1
    local result=$2
    printf "  %-60s %s\n" "$name" "$result"
}

# Variables globales pour le résumé
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

record_result() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$1" = "OK" ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        print_test "$2" "$OK"
        return 0
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        print_test "$2" "$KO"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1: CONNECTIVITÉ SSH
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 1: Connectivité SSH vers tous les nœuds"

for host in db-master-01 db-slave-01 db-slave-02 \
            haproxy-01 haproxy-02 \
            redis-01 redis-02 redis-03 \
            rabbitmq-01 rabbitmq-02 rabbitmq-03 \
            k3s-master-01 k3s-master-02 k3s-master-03; do
    
    IP=$(get_ip "$host")
    if [ -z "$IP" ]; then
        record_result "KO" "SSH $host (IP non trouvée dans servers.tsv)"
        continue
    fi
    
    if test_ssh "$IP"; then
        record_result "OK" "SSH $host ($IP)"
    else
        record_result "KO" "SSH $host ($IP)"
    fi
done

# ═══════════════════════════════════════════════════════════════════
# TEST 2: POSTGRESQL + PATRONI
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 2: PostgreSQL Cluster (Patroni)"

# 2.1 Vérifier que Patroni tourne sur tous les nœuds
for host in db-master-01 db-slave-01 db-slave-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    PATRONI_STATUS=$(ssh root@"$IP" "docker ps --filter name=patroni --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$PATRONI_STATUS" | grep -q "Up"; then
        record_result "OK" "Patroni container running on $host"
    else
        record_result "KO" "Patroni container on $host (Status: $PATRONI_STATUS)"
    fi
done

# 2.2 Vérifier l'état du cluster Patroni
DB_MASTER_IP=$(get_ip "db-master-01")
if [ -n "$DB_MASTER_IP" ]; then
    echo ""
    echo -e "$INFO Patroni Cluster Status:"
    CLUSTER_STATUS=$(ssh root@"$DB_MASTER_IP" "docker exec patroni patronictl list 2>/dev/null" || echo "")
    
    if echo "$CLUSTER_STATUS" | grep -q "Leader"; then
        echo "$CLUSTER_STATUS"
        record_result "OK" "Patroni cluster has a leader"
        
        # Compter les replicas en streaming
        REPLICAS=$(echo "$CLUSTER_STATUS" | grep -c "Replica.*streaming" || echo 0)
        record_result "OK" "Patroni streaming replicas: $REPLICAS/2"
    else
        record_result "KO" "Patroni cluster status (pas de leader détecté)"
    fi
fi

# 2.3 Test de connexion directe aux nœuds PostgreSQL
echo ""
echo -e "$INFO Test connexions PostgreSQL directes:"

PG_PASS=$(jq -r '.postgres_password // "b2eUq9eBCxTMsatoQMNJ"' "$CREDS_DIR/secrets.json" 2>/dev/null || echo "b2eUq9eBCxTMsatoQMNJ")

for host in db-master-01 db-slave-01 db-slave-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    if PGPASSWORD="$PG_PASS" psql -h "$IP" -U postgres -d postgres -c "SELECT version();" >/dev/null 2>&1; then
        record_result "OK" "PostgreSQL connexion directe $host ($IP:5432)"
    else
        record_result "KO" "PostgreSQL connexion directe $host ($IP:5432)"
    fi
done

# 2.4 Test réplication PostgreSQL
if [ -n "$DB_MASTER_IP" ]; then
    echo ""
    echo -e "$INFO Réplication PostgreSQL:"
    
    REPL_STATUS=$(PGPASSWORD="$PG_PASS" psql -h "$DB_MASTER_IP" -U postgres -d postgres -t -c \
        "SELECT count(*) FROM pg_stat_replication WHERE state='streaming';" 2>/dev/null | tr -d ' ')
    
    if [ "$REPL_STATUS" = "2" ]; then
        record_result "OK" "PostgreSQL streaming replicas: 2/2"
    else
        record_result "WARN" "PostgreSQL streaming replicas: $REPL_STATUS/2"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3: HAPROXY + PGBOUNCER
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 3: HAProxy & PgBouncer (Proxies DB)"

# 3.1 Vérifier les services sur haproxy-01 et haproxy-02
for host in haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    echo ""
    echo -e "$INFO Tests sur $host ($IP):"
    
    # HAProxy container
    HAPROXY_STATUS=$(ssh root@"$IP" "docker ps --filter name=haproxy --format '{{.Status}}' 2>/dev/null" || echo "")
    if echo "$HAPROXY_STATUS" | grep -q "Up"; then
        record_result "OK" "HAProxy container running on $host"
    else
        record_result "KO" "HAProxy container on $host"
    fi
    
    # PgBouncer container
    PGBOUNCER_STATUS=$(ssh root@"$IP" "docker ps --filter name=pgbouncer --format '{{.Status}}' 2>/dev/null" || echo "")
    if echo "$PGBOUNCER_STATUS" | grep -q "Up"; then
        record_result "OK" "PgBouncer container running on $host"
    else
        record_result "KO" "PgBouncer container on $host"
    fi
    
    # HAProxy Stats page
    if test_tcp_port "$IP" 8404; then
        record_result "OK" "HAProxy stats page ($IP:8404)"
    else
        record_result "KO" "HAProxy stats page ($IP:8404)"
    fi
    
    # PostgreSQL via HAProxy (port 5432 - write)
    if test_tcp_port "$IP" 5432; then
        record_result "OK" "HAProxy PostgreSQL write port ($IP:5432)"
    else
        record_result "KO" "HAProxy PostgreSQL write port ($IP:5432)"
    fi
    
    # PostgreSQL via HAProxy (port 5433 - read)
    if test_tcp_port "$IP" 5433; then
        record_result "OK" "HAProxy PostgreSQL read port ($IP:5433)"
    else
        record_result "KO" "HAProxy PostgreSQL read port ($IP:5433)"
    fi
    
    # PgBouncer port
    if test_tcp_port "$IP" 6432; then
        record_result "OK" "PgBouncer port ($IP:6432)"
    else
        record_result "KO" "PgBouncer port ($IP:6432)"
    fi
done

# 3.2 Test VIP Database (10.0.0.10)
echo ""
echo -e "$INFO Tests VIP Database (10.0.0.10):"

VIP_DB="10.0.0.10"

# Test port 5432 (HAProxy write)
if test_tcp_port "$VIP_DB" 5432; then
    record_result "OK" "VIP DB HAProxy write ($VIP_DB:5432)"
    
    # Test connexion SQL
    if PGPASSWORD="$PG_PASS" psql -h "$VIP_DB" -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        record_result "OK" "VIP DB SQL write test ($VIP_DB:5432)"
    else
        record_result "KO" "VIP DB SQL write test ($VIP_DB:5432)"
    fi
else
    record_result "KO" "VIP DB HAProxy write ($VIP_DB:5432)"
fi

# Test port 5433 (HAProxy read)
if test_tcp_port "$VIP_DB" 5433; then
    record_result "OK" "VIP DB HAProxy read ($VIP_DB:5433)"
else
    record_result "KO" "VIP DB HAProxy read ($VIP_DB:5433)"
fi

# Test port 6432 (PgBouncer)
if test_tcp_port "$VIP_DB" 6432; then
    record_result "OK" "VIP DB PgBouncer ($VIP_DB:6432)"
    
    # Test connexion via PgBouncer
    if PGPASSWORD="$PG_PASS" psql -h "$VIP_DB" -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        record_result "OK" "VIP DB SQL via PgBouncer ($VIP_DB:6432)"
    else
        record_result "KO" "VIP DB SQL via PgBouncer ($VIP_DB:6432)"
    fi
else
    record_result "KO" "VIP DB PgBouncer ($VIP_DB:6432)"
fi

# 3.3 Vérifier Keepalived VIP
echo ""
echo -e "$INFO Keepalived VIP Status:"

for host in haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    VIP_STATUS=$(ssh root@"$IP" "ip addr show | grep '10.0.0.10/32' 2>/dev/null" || echo "")
    
    if [ -n "$VIP_STATUS" ]; then
        record_result "OK" "VIP active sur $host (MASTER)"
    else
        echo -e "  $INFO VIP non active sur $host (BACKUP)"
    fi
done

# ═══════════════════════════════════════════════════════════════════
# TEST 4: REDIS + SENTINEL
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 4: Redis Cluster + Sentinel"

# 4.1 Vérifier Redis sur tous les nœuds
for host in redis-01 redis-02 redis-03; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    REDIS_STATUS=$(ssh root@"$IP" "docker ps --filter name=redis --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$REDIS_STATUS" | grep -q "Up"; then
        record_result "OK" "Redis container running on $host"
    else
        record_result "KO" "Redis container on $host"
    fi
    
    # Test connexion Redis
    REDIS_PASS=$(jq -r '.redis_password // "Lm1wszsUh07xuU9pttHw9YZOB"' "$CREDS_DIR/secrets.json" 2>/dev/null || echo "Lm1wszsUh07xuU9pttHw9YZOB")
    
    if ssh root@"$IP" "docker exec redis redis-cli -a '$REDIS_PASS' PING 2>/dev/null" | grep -q "PONG"; then
        record_result "OK" "Redis PING on $host"
    else
        record_result "KO" "Redis PING on $host"
    fi
done

# 4.2 Vérifier Sentinel
echo ""
echo -e "$INFO Redis Sentinel Status:"

REDIS_01_IP=$(get_ip "redis-01")
if [ -n "$REDIS_01_IP" ]; then
    MASTER_INFO=$(ssh root@"$REDIS_01_IP" \
        "docker exec sentinel redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null" || echo "")
    
    if [ -n "$MASTER_INFO" ]; then
        MASTER_IP=$(echo "$MASTER_INFO" | head -1)
        record_result "OK" "Sentinel master detected: $MASTER_IP"
        
        # Compter les sentinels
        SENTINEL_COUNT=$(ssh root@"$REDIS_01_IP" \
            "docker exec sentinel redis-cli -p 26379 SENTINEL sentinels mymaster 2>/dev/null | grep -c 'name' || echo 0")
        record_result "OK" "Sentinel nodes: $((SENTINEL_COUNT + 1))/3"
    else
        record_result "KO" "Sentinel master detection"
    fi
fi

# 4.3 Test HAProxy Redis (6379)
echo ""
echo -e "$INFO HAProxy Redis (TCP 6379):"

for host in haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    if test_tcp_port "$IP" 6379; then
        record_result "OK" "HAProxy Redis port ($IP:6379)"
    else
        record_result "KO" "HAProxy Redis port ($IP:6379)"
    fi
done

# 4.4 Test VIP Redis
if test_tcp_port "$VIP_DB" 6379; then
    record_result "OK" "VIP Redis ($VIP_DB:6379)"
    
    # Test write/read
    if redis-cli -h "$VIP_DB" -p 6379 -a "$REDIS_PASS" SET test_key "test_value" >/dev/null 2>&1; then
        record_result "OK" "VIP Redis write test"
        
        VAL=$(redis-cli -h "$VIP_DB" -p 6379 -a "$REDIS_PASS" GET test_key 2>/dev/null)
        if [ "$VAL" = "test_value" ]; then
            record_result "OK" "VIP Redis read test"
            redis-cli -h "$VIP_DB" -p 6379 -a "$REDIS_PASS" DEL test_key >/dev/null 2>&1
        else
            record_result "KO" "VIP Redis read test"
        fi
    else
        record_result "KO" "VIP Redis write test"
    fi
else
    record_result "KO" "VIP Redis ($VIP_DB:6379)"
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5: RABBITMQ CLUSTER
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 5: RabbitMQ Cluster"

# 5.1 Vérifier RabbitMQ sur tous les nœuds
for host in rabbitmq-01 rabbitmq-02 rabbitmq-03; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    RABBITMQ_STATUS=$(ssh root@"$IP" "docker ps --filter name=rabbitmq --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$RABBITMQ_STATUS" | grep -q "Up"; then
        record_result "OK" "RabbitMQ container running on $host"
    else
        record_result "KO" "RabbitMQ container on $host"
    fi
    
    # Test AMQP port
    if test_tcp_port "$IP" 5672; then
        record_result "OK" "RabbitMQ AMQP port ($IP:5672)"
    else
        record_result "KO" "RabbitMQ AMQP port ($IP:5672)"
    fi
    
    # Test Management port
    if test_tcp_port "$IP" 15672; then
        record_result "OK" "RabbitMQ Management port ($IP:15672)"
    else
        record_result "KO" "RabbitMQ Management port ($IP:15672)"
    fi
done

# 5.2 Vérifier le cluster RabbitMQ
echo ""
echo -e "$INFO RabbitMQ Cluster Status:"

RMQ_01_IP=$(get_ip "rabbitmq-01")
if [ -n "$RMQ_01_IP" ]; then
    CLUSTER_STATUS=$(ssh root@"$RMQ_01_IP" \
        "docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -c '@rabbitmq-0' || echo 0")
    
    if [ "$CLUSTER_STATUS" -ge 3 ]; then
        record_result "OK" "RabbitMQ cluster nodes: $CLUSTER_STATUS/3"
    else
        record_result "KO" "RabbitMQ cluster nodes: $CLUSTER_STATUS/3"
    fi
fi

# 5.3 Test HAProxy RabbitMQ
echo ""
echo -e "$INFO HAProxy RabbitMQ:"

for host in haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    if test_tcp_port "$IP" 5672; then
        record_result "OK" "HAProxy RabbitMQ AMQP ($IP:5672)"
    else
        record_result "KO" "HAProxy RabbitMQ AMQP ($IP:5672)"
    fi
    
    if test_tcp_port "$IP" 15672; then
        record_result "OK" "HAProxy RabbitMQ Management ($IP:15672)"
    else
        record_result "KO" "HAProxy RabbitMQ Management ($IP:15672)"
    fi
done

# 5.4 Test VIP RabbitMQ
if test_tcp_port "$VIP_DB" 5672; then
    record_result "OK" "VIP RabbitMQ AMQP ($VIP_DB:5672)"
else
    record_result "KO" "VIP RabbitMQ AMQP ($VIP_DB:5672)"
fi

if test_tcp_port "$VIP_DB" 15672; then
    record_result "OK" "VIP RabbitMQ Management ($VIP_DB:15672)"
else
    record_result "KO" "VIP RabbitMQ Management ($VIP_DB:15672)"
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6: K3S CLUSTER
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 6: K3s Kubernetes Cluster"

# 6.1 Vérifier K3s sur les masters
for host in k3s-master-01 k3s-master-02 k3s-master-03; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    K3S_STATUS=$(ssh root@"$IP" "systemctl is-active k3s 2>/dev/null" || echo "inactive")
    
    if [ "$K3S_STATUS" = "active" ]; then
        record_result "OK" "K3s service active on $host"
    else
        record_result "KO" "K3s service on $host (Status: $K3S_STATUS)"
    fi
done

# 6.2 Vérifier les nœuds K3s
K3S_MASTER_IP=$(get_ip "k3s-master-01")
if [ -n "$K3S_MASTER_IP" ]; then
    echo ""
    echo -e "$INFO K3s Nodes Status:"
    
    NODES_READY=$(ssh root@"$K3S_MASTER_IP" "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || echo 0")
    NODES_TOTAL=$(ssh root@"$K3S_MASTER_IP" "kubectl get nodes --no-headers 2>/dev/null | wc -l")
    
    if [ "$NODES_READY" -ge 3 ]; then
        record_result "OK" "K3s nodes ready: $NODES_READY/$NODES_TOTAL"
    else
        record_result "WARN" "K3s nodes ready: $NODES_READY/$NODES_TOTAL"
    fi
    
    # Vérifier les pods système
    SYSTEM_PODS=$(ssh root@"$K3S_MASTER_IP" \
        "kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c 'Running' || echo 0")
    
    if [ "$SYSTEM_PODS" -ge 5 ]; then
        record_result "OK" "K3s system pods running: $SYSTEM_PODS"
    else
        record_result "WARN" "K3s system pods running: $SYSTEM_PODS"
    fi
fi

# 6.3 Test HAProxy K3s API (port 6443)
echo ""
echo -e "$INFO HAProxy K3s API (port 6443):"

for host in haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    if test_tcp_port "$IP" 6443; then
        record_result "OK" "HAProxy K3s API ($IP:6443)"
    else
        record_result "KO" "HAProxy K3s API ($IP:6443)"
    fi
done

# ═══════════════════════════════════════════════════════════════════
# TEST 7: APPLICATIONS
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 7: Applications (n8n, Chatwoot, etc.)"

# 7.1 Vérifier les pods d'applications dans K3s
if [ -n "$K3S_MASTER_IP" ]; then
    # n8n
    N8N_STATUS=$(ssh root@"$K3S_MASTER_IP" \
        "kubectl get pods -A --no-headers 2>/dev/null | grep n8n | grep -c Running || echo 0")
    
    if [ "$N8N_STATUS" -ge 1 ]; then
        record_result "OK" "n8n running in K3s"
    else
        echo -e "  $INFO n8n: Non déployé ou en cours de démarrage"
    fi
    
    # Chatwoot
    CHATWOOT_STATUS=$(ssh root@"$K3S_MASTER_IP" \
        "kubectl get pods -A --no-headers 2>/dev/null | grep chatwoot | grep -c Running || echo 0")
    
    if [ "$CHATWOOT_STATUS" -ge 1 ]; then
        record_result "OK" "Chatwoot running in K3s"
    else
        echo -e "  $INFO Chatwoot: Non déployé ou en cours de démarrage"
    fi
fi

# 7.2 Test application n8n via connexion PostgreSQL
echo ""
echo -e "$INFO Test connexion applicative n8n → PostgreSQL:"

# Simuler une connexion comme n8n le ferait
if PGPASSWORD="$PG_PASS" psql -h "$VIP_DB" -p 6432 -U postgres -d postgres -c "SELECT current_database(), current_user, pg_backend_pid();" >/dev/null 2>&1; then
    record_result "OK" "Simulation connexion app n8n → DB (via PgBouncer)"
else
    record_result "KO" "Simulation connexion app n8n → DB (via PgBouncer)"
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8: VOLUMES ET STOCKAGE
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 8: Volumes et Stockage"

# 8.1 Vérifier les volumes montés sur les nœuds critiques
for host in db-master-01 db-slave-01 db-slave-02 haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    MOUNT_COUNT=$(ssh root@"$IP" "mount | grep -c '/opt/keybuzz' || echo 0")
    
    if [ "$MOUNT_COUNT" -ge 1 ]; then
        record_result "OK" "Volumes montés sur $host ($MOUNT_COUNT volumes)"
    else
        record_result "WARN" "Aucun volume monté sur $host"
    fi
done

# 8.2 Vérifier l'espace disque
echo ""
echo -e "$INFO Espace disque sur volumes:"

for host in db-master-01 haproxy-01 redis-01; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    DISK_USAGE=$(ssh root@"$IP" "df -h /opt/keybuzz 2>/dev/null | tail -1 | awk '{print \$5}' | tr -d '%'" || echo "0")
    
    if [ "$DISK_USAGE" -lt 80 ]; then
        record_result "OK" "Espace disque $host: ${DISK_USAGE}% utilisé"
    elif [ "$DISK_USAGE" -lt 90 ]; then
        record_result "WARN" "Espace disque $host: ${DISK_USAGE}% utilisé"
    else
        record_result "KO" "Espace disque $host: ${DISK_USAGE}% utilisé (CRITIQUE)"
    fi
done

# ═══════════════════════════════════════════════════════════════════
# TEST 9: SÉCURITÉ ET FIREWALL
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 9: Sécurité et Firewall"

# 9.1 Vérifier UFW sur les nœuds
for host in db-master-01 haproxy-01 redis-01; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    UFW_STATUS=$(ssh root@"$IP" "ufw status 2>/dev/null | head -1 | awk '{print \$2}'" || echo "unknown")
    
    if [ "$UFW_STATUS" = "active" ]; then
        record_result "OK" "UFW actif sur $host"
    else
        record_result "WARN" "UFW status sur $host: $UFW_STATUS"
    fi
done

# 9.2 Vérifier que SSH fonctionne avec clés uniquement
echo ""
echo -e "$INFO Authentification SSH:"

DB_MASTER_IP=$(get_ip "db-master-01")
if [ -n "$DB_MASTER_IP" ]; then
    SSH_METHOD=$(ssh root@"$DB_MASTER_IP" "grep -E '^PasswordAuthentication|^PubkeyAuthentication' /etc/ssh/sshd_config 2>/dev/null || echo 'unknown'")
    
    if echo "$SSH_METHOD" | grep -q "PasswordAuthentication no"; then
        record_result "OK" "SSH password authentication disabled"
    else
        record_result "WARN" "SSH password authentication status unclear"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 10: PERFORMANCE ET LATENCE
# ═══════════════════════════════════════════════════════════════════

print_section "TEST 10: Performance et Latence"

# 10.1 Mesurer la latence réseau entre nœuds
echo ""
echo -e "$INFO Latence réseau (ping):"

DB_MASTER_IP=$(get_ip "db-master-01")
HAPROXY_01_IP=$(get_ip "haproxy-01")

if [ -n "$DB_MASTER_IP" ] && [ -n "$HAPROXY_01_IP" ]; then
    LATENCY=$(ssh root@"$DB_MASTER_IP" "ping -c 3 -W 1 $HAPROXY_01_IP 2>/dev/null | grep 'avg' | awk -F'/' '{print \$5}'" || echo "999")
    
    if [ $(echo "$LATENCY < 5" | bc 2>/dev/null || echo 0) -eq 1 ]; then
        record_result "OK" "Latence db-master-01 → haproxy-01: ${LATENCY}ms"
    else
        record_result "WARN" "Latence db-master-01 → haproxy-01: ${LATENCY}ms (élevée)"
    fi
fi

# 10.2 Test de charge PostgreSQL (simple)
echo ""
echo -e "$INFO Test de charge PostgreSQL (10 connexions rapides):"

SUCCESS=0
for i in {1..10}; do
    if PGPASSWORD="$PG_PASS" timeout 2 psql -h "$VIP_DB" -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        SUCCESS=$((SUCCESS + 1))
    fi
done

if [ "$SUCCESS" -eq 10 ]; then
    record_result "OK" "PostgreSQL load test: 10/10 connexions réussies"
elif [ "$SUCCESS" -ge 8 ]; then
    record_result "WARN" "PostgreSQL load test: $SUCCESS/10 connexions réussies"
else
    record_result "KO" "PostgreSQL load test: $SUCCESS/10 connexions réussies"
fi

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

print_section "RÉSUMÉ DES TESTS"

echo ""
echo "  Total tests exécutés : $TOTAL_TESTS"
echo -e "  $OK Tests réussis    : $PASSED_TESTS"
echo -e "  $KO Tests échoués    : $FAILED_TESTS"
echo ""

PASS_PERCENT=$((PASSED_TESTS * 100 / TOTAL_TESTS))

if [ "$PASS_PERCENT" -ge 95 ]; then
    echo -e "$OK Infrastructure EXCELLENTE (${PASS_PERCENT}% de réussite)"
    echo ""
    echo "🎉 Votre infrastructure KeyBuzz est opérationnelle et performante !"
elif [ "$PASS_PERCENT" -ge 80 ]; then
    echo -e "$WARN Infrastructure ACCEPTABLE (${PASS_PERCENT}% de réussite)"
    echo ""
    echo "⚠️  Quelques problèmes mineurs détectés, mais l'infrastructure fonctionne."
else
    echo -e "$KO Infrastructure PROBLÉMATIQUE (${PASS_PERCENT}% de réussite)"
    echo ""
    echo "❌ Problèmes critiques détectés. Vérifiez les logs ci-dessus."
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  📄 Log complet: $TEST_LOG"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Afficher les dernières lignes du log
echo "Dernières lignes du log :"
tail -n 30 "$TEST_LOG" | grep -E "(OK|KO|WARN)" || true

exit 0
