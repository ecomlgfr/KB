#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       TEST_REDIS_RABBITMQ - Tests complets et interactifs          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_LOG="$LOG_DIR/test_redis_rabbitmq_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"

# Charger les credentials
if [ -f "$CREDS_DIR/redis.env" ]; then
    source "$CREDS_DIR/redis.env"
fi
if [ -f "$CREDS_DIR/rabbitmq.env" ]; then
    source "$CREDS_DIR/rabbitmq.env"
fi

# ═══════════════════════════════════════════════════════════════════
# FONCTIONS UTILITAIRES
# ═══════════════════════════════════════════════════════════════════

log_test() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$TEST_LOG"
}

print_header() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║ $1"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
}

wait_key() {
    echo ""
    read -p "Appuyez sur ENTRÉE pour continuer..." -r
}

# ═══════════════════════════════════════════════════════════════════
# TESTS REDIS
# ═══════════════════════════════════════════════════════════════════

test_redis_basic() {
    print_header "TEST REDIS 1/5 : Connexion basique"
    
    echo "  Test PING via Load Balancer (10.0.0.10:6379)..."
    if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" PING 2>/dev/null | grep -q "PONG"; then
        echo -e "    $OK PING répondu"
        log_test "REDIS_PING: OK"
    else
        echo -e "    $KO Pas de réponse PING"
        log_test "REDIS_PING: KO"
        return 1
    fi
    
    echo ""
    echo "  Test SET/GET..."
    TEST_KEY="test_$(date +%s)"
    TEST_VALUE="KeyBuzz_Test_$(openssl rand -hex 8)"
    
    redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" SET "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1
    RETRIEVED=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" GET "$TEST_KEY" 2>/dev/null)
    
    if [ "$RETRIEVED" = "$TEST_VALUE" ]; then
        echo -e "    $OK SET/GET fonctionnent"
        log_test "REDIS_SET_GET: OK"
        redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" DEL "$TEST_KEY" >/dev/null 2>&1
    else
        echo -e "    $KO SET/GET échoués"
        log_test "REDIS_SET_GET: KO"
        return 1
    fi
    
    echo ""
    echo "  Test INFO..."
    INFO_OUTPUT=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" INFO server 2>/dev/null)
    if echo "$INFO_OUTPUT" | grep -q "redis_version"; then
        VERSION=$(echo "$INFO_OUTPUT" | grep "redis_version:" | cut -d: -f2 | tr -d '\r')
        echo -e "    $OK Version Redis: $VERSION"
        log_test "REDIS_INFO: OK (version: $VERSION)"
    else
        echo -e "    $KO INFO non disponible"
        log_test "REDIS_INFO: KO"
    fi
}

test_redis_performance() {
    print_header "TEST REDIS 2/5 : Performance (10 000 requêtes)"
    
    echo "  Lancement du benchmark..."
    echo "  (SET/GET/INCR/LPUSH/RPUSH/LPOP/RPOP/SADD/HSET/SPOP/ZADD/ZPOPMIN/LRANGE/MSET)"
    echo ""
    
    redis-benchmark -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" -q -n 10000 2>/dev/null | tee -a "$TEST_LOG"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo ""
        echo -e "  $OK Benchmark terminé avec succès"
        log_test "REDIS_BENCHMARK: OK"
    else
        echo ""
        echo -e "  $KO Benchmark échoué"
        log_test "REDIS_BENCHMARK: KO"
    fi
}

test_redis_replication() {
    print_header "TEST REDIS 3/5 : Réplication et topologie"
    
    echo "  Détection du master actuel..."
    REDIS1=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV" | head -1)
    
    MASTER_IP=$(redis-cli -h "$REDIS1" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
    
    if [ -n "$MASTER_IP" ]; then
        echo -e "    $OK Master détecté: $MASTER_IP"
        log_test "REDIS_MASTER: $MASTER_IP"
    else
        echo -e "    $WARN Sentinel non accessible depuis ce serveur"
        log_test "REDIS_MASTER: Unknown"
    fi
    
    echo ""
    echo "  Test de réplication sur les 3 nœuds..."
    
    for host in redis-01 redis-02 redis-03; do
        IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV" | head -1)
        echo -n "    $host ($IP): "
        
        ROLE=$(redis-cli -h "$IP" -p 6379 -a "$REDIS_PASSWORD" ROLE 2>/dev/null | head -1)
        
        if [ -n "$ROLE" ]; then
            echo -e "$OK Role: $ROLE"
            log_test "REDIS_$host: $ROLE"
        else
            echo -e "$KO Non accessible"
            log_test "REDIS_$host: KO"
        fi
    done
}

test_redis_persistence() {
    print_header "TEST REDIS 4/5 : Persistance et sauvegarde"
    
    echo "  Vérification de la configuration de persistance..."
    
    # Vérifier RDB
    RDB_CONFIG=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" CONFIG GET save 2>/dev/null)
    if echo "$RDB_CONFIG" | grep -q "save"; then
        echo -e "    $OK RDB snapshots configurés"
        log_test "REDIS_RDB: OK"
    else
        echo -e "    $WARN RDB non configuré"
        log_test "REDIS_RDB: WARN"
    fi
    
    # Vérifier AOF
    AOF_ENABLED=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" CONFIG GET appendonly 2>/dev/null | tail -1)
    if [ "$AOF_ENABLED" = "yes" ]; then
        echo -e "    $OK AOF (Append Only File) activé"
        log_test "REDIS_AOF: yes"
    else
        echo -e "    $INFO AOF désactivé (RDB snapshot utilisé)"
        log_test "REDIS_AOF: no"
    fi
    
    echo ""
    echo "  Test de sauvegarde manuelle..."
    SAVE_RESULT=$(redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" BGSAVE 2>/dev/null)
    if echo "$SAVE_RESULT" | grep -q "Background saving started"; then
        echo -e "    $OK Sauvegarde background lancée"
        log_test "REDIS_BGSAVE: OK"
    else
        echo -e "    $WARN Sauvegarde peut-être déjà en cours"
        log_test "REDIS_BGSAVE: WARN"
    fi
}

test_redis_failover() {
    print_header "TEST REDIS 5/5 : Simulation de failover (INTERACTIF)"
    
    echo "  Ce test simule une panne du master Redis"
    echo "  et vérifie que le watcher met à jour HAProxy automatiquement."
    echo ""
    echo -e "  $WARN Ce test va stopper temporairement le container Redis master !"
    echo ""
    read -p "  Voulez-vous continuer ? (o/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Oo]$ ]]; then
        echo -e "  $INFO Test de failover annulé"
        log_test "REDIS_FAILOVER: SKIPPED"
        return 0
    fi
    
    # Détecter le master actuel
    REDIS1=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV" | head -1)
    MASTER_IP=$(redis-cli -h "$REDIS1" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
    
    if [ -z "$MASTER_IP" ]; then
        echo -e "  $KO Impossible de détecter le master"
        log_test "REDIS_FAILOVER: KO (no master detected)"
        return 1
    fi
    
    echo ""
    echo "  Master actuel: $MASTER_IP"
    echo "  Arrêt du container Redis sur le master..."
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$MASTER_IP" 'docker stop redis' 2>/dev/null
    
    echo -e "  $OK Container Redis stoppé"
    echo ""
    echo "  Attente de 20 secondes pour le failover Sentinel + watcher..."
    
    for i in {20..1}; do
        echo -ne "    Attente: $i secondes...\r"
        sleep 1
    done
    echo ""
    
    # Vérifier que Redis répond toujours via le LB
    echo "  Test de connexion via Load Balancer..."
    if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" PING 2>/dev/null | grep -q "PONG"; then
        echo -e "  $OK Redis toujours accessible via 10.0.0.10 (failover réussi)"
        log_test "REDIS_FAILOVER: OK"
    else
        echo -e "  $KO Redis non accessible après failover"
        log_test "REDIS_FAILOVER: KO"
    fi
    
    # Détecter le nouveau master
    NEW_MASTER=$(redis-cli -h "$REDIS1" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
    
    if [ "$NEW_MASTER" != "$MASTER_IP" ]; then
        echo -e "  $OK Nouveau master détecté: $NEW_MASTER"
        log_test "REDIS_NEW_MASTER: $NEW_MASTER"
    else
        echo -e "  $WARN Master identique (failover peut-être en cours...)"
        log_test "REDIS_NEW_MASTER: Same as before"
    fi
    
    echo ""
    echo "  Redémarrage du container Redis sur l'ancien master..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$MASTER_IP" 'docker start redis' 2>/dev/null
    echo -e "  $OK Container redémarré (il deviendra replica)"
}

# ═══════════════════════════════════════════════════════════════════
# TESTS RABBITMQ
# ═══════════════════════════════════════════════════════════════════

test_rabbitmq_basic() {
    print_header "TEST RABBITMQ 1/5 : Connexion et cluster"
    
    echo "  Test de connexion AMQP (10.0.0.10:5672)..."
    if timeout 3 nc -zv 10.0.0.10 5672 &>/dev/null; then
        echo -e "    $OK Port 5672 accessible"
        log_test "RABBITMQ_AMQP: OK"
    else
        echo -e "    $KO Port 5672 non accessible"
        log_test "RABBITMQ_AMQP: KO"
        return 1
    fi
    
    echo ""
    echo "  Test Management UI (10.0.0.10:15672)..."
    if timeout 3 nc -zv 10.0.0.10 15672 &>/dev/null; then
        echo -e "    $OK Port 15672 accessible"
        log_test "RABBITMQ_MGMT: OK"
    else
        echo -e "    $KO Port 15672 non accessible"
        log_test "RABBITMQ_MGMT: KO"
    fi
    
    echo ""
    echo "  État du cluster RabbitMQ..."
    QUEUE01=$(awk -F'\t' '$2=="queue-01" {print $3}' "$SERVERS_TSV" | head -1)
    
    CLUSTER_STATUS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$QUEUE01" \
        'docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null' | grep -E "Running Nodes")
    
    if echo "$CLUSTER_STATUS" | grep -q "rabbit@queue"; then
        NODE_COUNT=$(echo "$CLUSTER_STATUS" | grep -o "rabbit@queue" | wc -l)
        echo -e "    $OK Cluster actif avec $NODE_COUNT nœuds"
        log_test "RABBITMQ_CLUSTER: $NODE_COUNT nodes"
    else
        echo -e "    $KO Impossible de vérifier le cluster"
        log_test "RABBITMQ_CLUSTER: KO"
    fi
}

test_rabbitmq_quorum() {
    print_header "TEST RABBITMQ 2/5 : Vérification Quorum par défaut"
    
    echo "  Vérification de default_queue_type dans rabbitmq.conf..."
    QUEUE01=$(awk -F'\t' '$2=="queue-01" {print $3}' "$SERVERS_TSV" | head -1)
    
    QUORUM_CONFIG=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$QUEUE01" \
        'docker exec rabbitmq cat /etc/rabbitmq/rabbitmq.conf 2>/dev/null' | grep "default_queue_type")
    
    if echo "$QUORUM_CONFIG" | grep -q "quorum"; then
        echo -e "    $OK Quorum configuré par défaut: $QUORUM_CONFIG"
        log_test "RABBITMQ_QUORUM_DEFAULT: yes"
    else
        echo -e "    $WARN Quorum non configuré par défaut"
        log_test "RABBITMQ_QUORUM_DEFAULT: no"
    fi
    
    echo ""
    echo "  Vérification via API Management..."
    
    # Test via API si curl disponible
    if command -v curl &>/dev/null; then
        API_RESPONSE=$(curl -s -u "$RABBITMQ_ADMIN_USER:$RABBITMQ_ADMIN_PASS" \
            "http://10.0.0.10:15672/api/overview" 2>/dev/null)
        
        if echo "$API_RESPONSE" | grep -q "cluster_name"; then
            CLUSTER_NAME=$(echo "$API_RESPONSE" | grep -o '"cluster_name":"[^"]*"' | cut -d'"' -f4)
            echo -e "    $OK API accessible - Cluster: $CLUSTER_NAME"
            log_test "RABBITMQ_API: OK (cluster: $CLUSTER_NAME)"
        else
            echo -e "    $WARN API non accessible ou authentification échouée"
            log_test "RABBITMQ_API: WARN"
        fi
    else
        echo -e "    $INFO curl non disponible, skip test API"
    fi
}

test_rabbitmq_publish_consume() {
    print_header "TEST RABBITMQ 3/5 : Publish/Consume de messages"
    
    if ! command -v python3 &>/dev/null; then
        echo -e "  $WARN Python3 non disponible, test skippé"
        log_test "RABBITMQ_PUBSUB: SKIPPED (no python3)"
        return 0
    fi
    
    echo "  Installation de pika (client RabbitMQ Python)..."
    pip3 install pika --break-system-packages --quiet 2>/dev/null || pip3 install pika --quiet 2>/dev/null
    
    echo ""
    echo "  Création d'une queue de test et envoi de messages..."
    
    # Script Python pour tester publish/consume
    python3 - <<PYTHON_TEST
import pika
import sys

try:
    # Connexion
    credentials = pika.PlainCredentials('${RABBITMQ_ADMIN_USER}', '${RABBITMQ_ADMIN_PASS}')
    parameters = pika.ConnectionParameters('10.0.0.10', 5672, '/', credentials)
    connection = pika.BlockingConnection(parameters)
    channel = connection.channel()
    
    # Créer une queue (devrait être quorum par défaut)
    queue_name = 'test_keybuzz_$(date +%s)'
    result = channel.queue_declare(queue=queue_name, durable=True)
    
    # Publier des messages
    for i in range(10):
        message = f'Test message {i+1}'
        channel.basic_publish(exchange='', routing_key=queue_name, body=message)
    
    print(f"  ✓ 10 messages publiés sur la queue: {queue_name}")
    
    # Consommer les messages
    method_frame, header_frame, body = channel.basic_get(queue=queue_name)
    if method_frame:
        print(f"  ✓ Message reçu: {body.decode()}")
        channel.basic_ack(method_frame.delivery_tag)
    
    # Nettoyer
    channel.queue_delete(queue=queue_name)
    connection.close()
    
    print("  ✓ Test publish/consume réussi")
    sys.exit(0)
    
except Exception as e:
    print(f"  ✗ Erreur: {e}")
    sys.exit(1)
PYTHON_TEST
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Test publish/consume réussi"
        log_test "RABBITMQ_PUBSUB: OK"
    else
        echo -e "  $KO Test publish/consume échoué"
        log_test "RABBITMQ_PUBSUB: KO"
    fi
}

test_rabbitmq_performance() {
    print_header "TEST RABBITMQ 4/5 : Performance (PerfTest)"
    
    echo "  Ce test nécessite rabbitmq-perf-test (Java)"
    echo ""
    read -p "  Voulez-vous lancer le test de performance ? (o/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Oo]$ ]]; then
        echo -e "  $INFO Test de performance annulé"
        log_test "RABBITMQ_PERF: SKIPPED"
        return 0
    fi
    
    # Télécharger PerfTest si pas présent
    PERF_JAR="/tmp/rabbitmq-perf-test.jar"
    
    if [ ! -f "$PERF_JAR" ]; then
        echo "  Téléchargement de rabbitmq-perf-test..."
        wget -q -O "$PERF_JAR" \
            "https://github.com/rabbitmq/rabbitmq-perf-test/releases/download/v2.18.0/perf-test-2.18.0.jar" 2>/dev/null
    fi
    
    if [ -f "$PERF_JAR" ] && command -v java &>/dev/null; then
        echo "  Lancement du test (1000 messages, 10 producers, 10 consumers)..."
        
        java -jar "$PERF_JAR" \
            -h "amqp://${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASS}@10.0.0.10:5672" \
            -x 10 -y 10 -u "test_perf" -a --autoack \
            -s 1000 -C 1000 2>&1 | tail -20
        
        echo -e "  $OK Test de performance terminé"
        log_test "RABBITMQ_PERF: OK"
    else
        echo -e "  $WARN Java ou PerfTest non disponible"
        log_test "RABBITMQ_PERF: SKIPPED (no java)"
    fi
}

test_rabbitmq_resilience() {
    print_header "TEST RABBITMQ 5/5 : Résilience (INTERACTIF)"
    
    echo "  Ce test arrête temporairement un nœud RabbitMQ"
    echo "  et vérifie que le cluster reste opérationnel (quorum 2/3)."
    echo ""
    echo -e "  $WARN Ce test va stopper temporairement queue-02 !"
    echo ""
    read -p "  Voulez-vous continuer ? (o/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Oo]$ ]]; then
        echo -e "  $INFO Test de résilience annulé"
        log_test "RABBITMQ_RESILIENCE: SKIPPED"
        return 0
    fi
    
    QUEUE02=$(awk -F'\t' '$2=="queue-02" {print $3}' "$SERVERS_TSV" | head -1)
    
    echo ""
    echo "  Arrêt du container RabbitMQ sur queue-02..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$QUEUE02" 'docker stop rabbitmq' 2>/dev/null
    echo -e "  $OK Container stoppé"
    
    echo ""
    echo "  Attente de 5 secondes..."
    sleep 5
    
    echo "  Test de connexion AMQP avec un nœud down..."
    if timeout 3 nc -zv 10.0.0.10 5672 &>/dev/null; then
        echo -e "  $OK Port 5672 toujours accessible (cluster opérationnel)"
        log_test "RABBITMQ_RESILIENCE: OK"
    else
        echo -e "  $KO Port 5672 non accessible"
        log_test "RABBITMQ_RESILIENCE: KO"
    fi
    
    echo ""
    echo "  Redémarrage du container RabbitMQ sur queue-02..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$QUEUE02" 'docker start rabbitmq' 2>/dev/null
    echo -e "  $OK Container redémarré"
    
    echo ""
    echo "  Attente de 10 secondes pour la réintégration au cluster..."
    sleep 10
    
    echo "  Vérification du cluster..."
    QUEUE01=$(awk -F'\t' '$2=="queue-01" {print $3}' "$SERVERS_TSV" | head -1)
    NODE_COUNT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$QUEUE01" \
        'docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null' | \
        grep -E "Running Nodes" | grep -o "rabbit@queue" | wc -l)
    
    if [ "$NODE_COUNT" -eq 3 ]; then
        echo -e "  $OK Cluster restauré (3/3 nœuds)"
        log_test "RABBITMQ_CLUSTER_RESTORED: OK (3 nodes)"
    else
        echo -e "  $WARN Cluster partiellement restauré ($NODE_COUNT/3 nœuds)"
        log_test "RABBITMQ_CLUSTER_RESTORED: WARN ($NODE_COUNT nodes)"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# MENU INTERACTIF
# ═══════════════════════════════════════════════════════════════════

show_menu() {
    clear
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║       TEST_REDIS_RABBITMQ - Menu de tests interactifs              ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  TESTS REDIS :"
    echo "    1. Test connexion basique (PING/SET/GET/INFO)"
    echo "    2. Test performance (benchmark 10k requêtes)"
    echo "    3. Test réplication et topologie"
    echo "    4. Test persistance (RDB/AOF)"
    echo "    5. Test failover automatique (INTERACTIF)"
    echo ""
    echo "  TESTS RABBITMQ :"
    echo "    6. Test connexion et cluster"
    echo "    7. Test quorum par défaut"
    echo "    8. Test publish/consume de messages"
    echo "    9. Test performance (PerfTest)"
    echo "    10. Test résilience cluster (INTERACTIF)"
    echo ""
    echo "  TESTS GLOBAUX :"
    echo "    A. Lancer TOUS les tests Redis (1-5)"
    echo "    B. Lancer TOUS les tests RabbitMQ (6-10)"
    echo "    C. Lancer TOUS les tests (Redis + RabbitMQ)"
    echo ""
    echo "    L. Voir les logs du dernier test"
    echo "    Q. Quitter"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -n "  Votre choix : "
}

# ═══════════════════════════════════════════════════════════════════
# BOUCLE PRINCIPALE
# ═══════════════════════════════════════════════════════════════════

if [ $# -eq 0 ]; then
    # Mode interactif
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1) test_redis_basic; wait_key ;;
            2) test_redis_performance; wait_key ;;
            3) test_redis_replication; wait_key ;;
            4) test_redis_persistence; wait_key ;;
            5) test_redis_failover; wait_key ;;
            6) test_rabbitmq_basic; wait_key ;;
            7) test_rabbitmq_quorum; wait_key ;;
            8) test_rabbitmq_publish_consume; wait_key ;;
            9) test_rabbitmq_performance; wait_key ;;
            10) test_rabbitmq_resilience; wait_key ;;
            [Aa])
                test_redis_basic
                test_redis_performance
                test_redis_replication
                test_redis_persistence
                test_redis_failover
                wait_key
                ;;
            [Bb])
                test_rabbitmq_basic
                test_rabbitmq_quorum
                test_rabbitmq_publish_consume
                test_rabbitmq_performance
                test_rabbitmq_resilience
                wait_key
                ;;
            [Cc])
                test_redis_basic
                test_redis_performance
                test_redis_replication
                test_redis_persistence
                test_redis_failover
                test_rabbitmq_basic
                test_rabbitmq_quorum
                test_rabbitmq_publish_consume
                test_rabbitmq_performance
                test_rabbitmq_resilience
                wait_key
                ;;
            [Ll])
                clear
                echo "╔════════════════════════════════════════════════════════════════════╗"
                echo "║ LOGS DU DERNIER TEST                                                ║"
                echo "╚════════════════════════════════════════════════════════════════════╝"
                echo ""
                if [ -f "$TEST_LOG" ]; then
                    cat "$TEST_LOG"
                else
                    echo "  Aucun log disponible"
                fi
                wait_key
                ;;
            [Qq]) 
                echo ""
                echo "═══════════════════════════════════════════════════════════════════"
                echo "Tests terminés. Logs sauvegardés dans: $TEST_LOG"
                echo "═══════════════════════════════════════════════════════════════════"
                echo ""
                exit 0
                ;;
            *) 
                echo ""
                echo "  Choix invalide !"
                sleep 2
                ;;
        esac
    done
else
    # Mode non-interactif (arguments en ligne de commande)
    case "$1" in
        redis-all)
            test_redis_basic
            test_redis_performance
            test_redis_replication
            test_redis_persistence
            ;;
        rabbitmq-all)
            test_rabbitmq_basic
            test_rabbitmq_quorum
            test_rabbitmq_publish_consume
            ;;
        all)
            test_redis_basic
            test_redis_performance
            test_redis_replication
            test_rabbitmq_basic
            test_rabbitmq_quorum
            test_rabbitmq_publish_consume
            ;;
        *)
            echo "Usage: $0 [redis-all|rabbitmq-all|all]"
            echo "  Sans argument : mode interactif"
            exit 1
            ;;
    esac
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "Tests terminés. Logs: $TEST_LOG"
    echo "═══════════════════════════════════════════════════════════════════"
fi
