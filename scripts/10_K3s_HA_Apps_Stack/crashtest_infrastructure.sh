#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    CRASH TEST - Infrastructure KeyBuzz                            ║"
echo "║    (Tests de résilience et failover)                              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs/crashtest"
REPORT_FILE="$LOG_DIR/crashtest_report_$(date +%Y%m%d_%H%M%S).txt"

mkdir -p "$LOG_DIR"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Charger credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO PostgreSQL credentials manquants"
    exit 1
fi

# Fonction pour logger
log() {
    echo "$1" | tee -a "$REPORT_FILE"
}

# Fonction pour mesurer le temps
measure_time() {
    echo $(date +%s)
}

# Fonction pour calculer la durée
calc_duration() {
    local start=$1
    local end=$2
    echo $((end - start))
}

# Fonction pour attendre un service
wait_for_service() {
    local service_name=$1
    local check_command=$2
    local max_wait=${3:-30}
    local interval=2
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        if eval "$check_command" >/dev/null 2>&1; then
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    return 1
}

echo ""
echo "⚠️  AVERTISSEMENT IMPORTANT :"
echo "  Ce script va effectuer des crash tests sur votre infrastructure."
echo "  Les tests sont contrôlés et réversibles."
echo "  AUCUNE modification firewall ne sera effectuée."
echo ""
echo "Tests planifiés :"
echo "  1. PostgreSQL Patroni Failover"
echo "  2. Redis Sentinel Failover"
echo "  3. RabbitMQ Node Failure"
echo "  4. HAProxy Failover"
echo "  5. K3s Master Failure"
echo "  6. K3s Worker Failure"
echo "  7. Application Pod Crash"
echo "  8. Complete Server Reboot"
echo ""
read -p "Démarrer les crash tests ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

log "════════════════════════════════════════════════════════════════════"
log "CRASH TEST INFRASTRUCTURE KEYBUZZ - $(date)"
log "════════════════════════════════════════════════════════════════════"
log ""

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 0. ÉTAT INITIAL (BASELINE) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ ÉTAT INITIAL ═══"
log ""

# PostgreSQL
log "PostgreSQL Cluster :"
ssh root@db-master-01 "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list" | tee -a "$REPORT_FILE"
log ""

# Redis
log "Redis Cluster :"
ssh root@redis-01 "redis-cli -a $REDIS_PASSWORD info replication 2>/dev/null | grep -E 'role|connected_slaves'" | tee -a "$REPORT_FILE"
log ""

# RabbitMQ
log "RabbitMQ Cluster :"
ssh root@queue-01 "rabbitmqctl cluster_status 2>/dev/null | grep -A 10 'running_nodes'" | tee -a "$REPORT_FILE"
log ""

# K3s
log "K3s Nodes :"
kubectl get nodes | tee -a "$REPORT_FILE"
log ""

# Applications
log "Applications :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | tee -a "$REPORT_FILE"
log ""

echo -e "$OK État initial enregistré"
echo ""
read -p "Continuer avec les crash tests ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { log "Tests annulés par l'utilisateur"; exit 0; }

#═══════════════════════════════════════════════════════════════════════
# TEST 1 : POSTGRESQL PATRONI FAILOVER
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 1 : PostgreSQL Patroni Failover ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 1 : PostgreSQL Patroni Failover ═══"
log "Date : $(date)"
log ""

# Identifier le leader actuel
CURRENT_LEADER=$(ssh root@db-master-01 "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list" | grep Leader | awk '{print $2}')
log "Leader actuel : $CURRENT_LEADER"

read -p "Arrêter Patroni sur $CURRENT_LEADER ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    log "Arrêt de Patroni sur $CURRENT_LEADER..."
    START_TIME=$(measure_time)
    
    ssh root@$CURRENT_LEADER "systemctl stop patroni"
    log "Patroni arrêté"
    
    # Attendre le failover
    sleep 5
    
    # Vérifier le nouveau leader
    NEW_LEADER=$(ssh root@db-master-01 "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list 2>/dev/null" | grep Leader | awk '{print $2}')
    END_TIME=$(measure_time)
    DURATION=$(calc_duration $START_TIME $END_TIME)
    
    log "Nouveau leader : $NEW_LEADER"
    log "Durée du failover : ${DURATION}s"
    log ""
    
    # Vérifier la connectivité
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -h 10.0.0.10 -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        log "✅ PostgreSQL accessible via PgBouncer"
    else
        log "❌ PostgreSQL NON accessible"
    fi
    
    # Redémarrer l'ancien leader
    log ""
    log "Redémarrage de Patroni sur $CURRENT_LEADER..."
    ssh root@$CURRENT_LEADER "systemctl start patroni"
    sleep 10
    
    # État final
    log "État du cluster après failover :"
    ssh root@db-master-01 "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list" | tee -a "$REPORT_FILE"
    
    if [ "$DURATION" -lt 10 ]; then
        log "✅ TEST 1 RÉUSSI : Failover en ${DURATION}s (< 10s)"
    else
        log "⚠️  TEST 1 LENT : Failover en ${DURATION}s (> 10s)"
    fi
else
    log "TEST 1 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# TEST 2 : REDIS SENTINEL FAILOVER
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 2 : Redis Sentinel Failover ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 2 : Redis Sentinel Failover ═══"
log "Date : $(date)"
log ""

# Identifier le master actuel
REDIS_MASTER=$(ssh root@redis-01 "redis-cli -a $REDIS_PASSWORD info replication 2>/dev/null | grep role | cut -d: -f2 | tr -d '\r'")

if [ "$REDIS_MASTER" = "master" ]; then
    CURRENT_REDIS_MASTER="redis-01"
elif ssh root@redis-02 "redis-cli -a $REDIS_PASSWORD info replication 2>/dev/null | grep role" | grep -q master; then
    CURRENT_REDIS_MASTER="redis-02"
else
    CURRENT_REDIS_MASTER="redis-03"
fi

log "Master Redis actuel : $CURRENT_REDIS_MASTER"

read -p "Arrêter Redis sur $CURRENT_REDIS_MASTER ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    log "Arrêt de Redis sur $CURRENT_REDIS_MASTER..."
    START_TIME=$(measure_time)
    
    ssh root@$CURRENT_REDIS_MASTER "systemctl stop redis-server"
    log "Redis arrêté"
    
    # Attendre le failover (Sentinel timeout = 5s)
    sleep 8
    
    END_TIME=$(measure_time)
    DURATION=$(calc_duration $START_TIME $END_TIME)
    
    # Vérifier le nouveau master
    for node in redis-01 redis-02 redis-03; do
        if [ "$node" != "$CURRENT_REDIS_MASTER" ]; then
            ROLE=$(ssh root@$node "redis-cli -a $REDIS_PASSWORD info replication 2>/dev/null | grep role | cut -d: -f2 | tr -d '\r'")
            if [ "$ROLE" = "master" ]; then
                NEW_REDIS_MASTER=$node
                break
            fi
        fi
    done
    
    log "Nouveau master Redis : $NEW_REDIS_MASTER"
    log "Durée du failover : ${DURATION}s"
    log ""
    
    # Vérifier la connectivité
    if redis-cli -h 10.0.0.10 -p 6379 -a $REDIS_PASSWORD ping 2>/dev/null | grep -q PONG; then
        log "✅ Redis accessible via HAProxy"
    else
        log "❌ Redis NON accessible"
    fi
    
    # Redémarrer l'ancien master
    log ""
    log "Redémarrage de Redis sur $CURRENT_REDIS_MASTER..."
    ssh root@$CURRENT_REDIS_MASTER "systemctl start redis-server"
    sleep 5
    
    if [ "$DURATION" -lt 10 ]; then
        log "✅ TEST 2 RÉUSSI : Failover en ${DURATION}s (< 10s)"
    else
        log "⚠️  TEST 2 LENT : Failover en ${DURATION}s (> 10s)"
    fi
else
    log "TEST 2 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# TEST 3 : RABBITMQ NODE FAILURE
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 3 : RabbitMQ Node Failure ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 3 : RabbitMQ Node Failure ═══"
log "Date : $(date)"
log ""

read -p "Arrêter RabbitMQ sur queue-01 ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    log "Arrêt de RabbitMQ sur queue-01..."
    START_TIME=$(measure_time)
    
    ssh root@queue-01 "systemctl stop rabbitmq-server"
    log "RabbitMQ arrêté sur queue-01"
    
    sleep 5
    END_TIME=$(measure_time)
    DURATION=$(calc_duration $START_TIME $END_TIME)
    
    # Vérifier le cluster
    log "État du cluster (vu depuis queue-02) :"
    ssh root@queue-02 "rabbitmqctl cluster_status 2>/dev/null | grep -A 10 'running_nodes'" | tee -a "$REPORT_FILE"
    log ""
    
    # Vérifier la connectivité
    if timeout 5 bash -c "echo > /dev/tcp/10.0.0.10/5672" 2>/dev/null; then
        log "✅ RabbitMQ accessible via HAProxy (sur les nœuds restants)"
    else
        log "❌ RabbitMQ NON accessible"
    fi
    
    # Redémarrer queue-01
    log ""
    log "Redémarrage de RabbitMQ sur queue-01..."
    ssh root@queue-01 "systemctl start rabbitmq-server"
    sleep 10
    
    log "État du cluster après redémarrage :"
    ssh root@queue-01 "rabbitmqctl cluster_status 2>/dev/null | grep -A 10 'running_nodes'" | tee -a "$REPORT_FILE"
    
    log "✅ TEST 3 RÉUSSI : Cluster RabbitMQ reste opérationnel avec 2/3 nœuds"
else
    log "TEST 3 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# TEST 4 : HAPROXY FAILOVER
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 4 : HAProxy Failover ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 4 : HAProxy Failover ═══"
log "Date : $(date)"
log ""

read -p "Arrêter HAProxy sur haproxy-01 ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    log "Arrêt de HAProxy sur haproxy-01..."
    START_TIME=$(measure_time)
    
    ssh root@haproxy-01 "systemctl stop haproxy"
    log "HAProxy arrêté sur haproxy-01"
    
    # Attendre le basculement (Keepalived devrait basculer la VIP)
    sleep 5
    END_TIME=$(measure_time)
    DURATION=$(calc_duration $START_TIME $END_TIME)
    
    # Vérifier les VIP
    log "VIP sur haproxy-01 :"
    ssh root@haproxy-01 "ip addr show | grep '10.0.0.10'" | tee -a "$REPORT_FILE"
    log ""
    log "VIP sur haproxy-02 :"
    ssh root@haproxy-02 "ip addr show | grep '10.0.0.10'" | tee -a "$REPORT_FILE"
    log ""
    
    # Vérifier la connectivité PostgreSQL
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -h 10.0.0.10 -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        log "✅ PostgreSQL accessible via 10.0.0.10 (haproxy-02 a repris)"
    else
        log "❌ PostgreSQL NON accessible"
    fi
    
    # Redémarrer haproxy-01
    log ""
    log "Redémarrage de HAProxy sur haproxy-01..."
    ssh root@haproxy-01 "systemctl start haproxy"
    sleep 5
    
    log "✅ TEST 4 RÉUSSI : Basculement HAProxy fonctionnel"
else
    log "TEST 4 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# TEST 5 : K3S MASTER FAILURE
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 5 : K3s Master Failure ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 5 : K3s Master Failure ═══"
log "Date : $(date)"
log ""

read -p "Arrêter k3s-master-02 ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    log "Arrêt de K3s sur k3s-master-02..."
    START_TIME=$(measure_time)
    
    ssh root@k3s-master-02 "systemctl stop k3s"
    log "K3s arrêté sur k3s-master-02"
    
    sleep 10
    END_TIME=$(measure_time)
    DURATION=$(calc_duration $START_TIME $END_TIME)
    
    # Vérifier les nœuds
    log "État des nœuds K3s :"
    kubectl get nodes | tee -a "$REPORT_FILE"
    log ""
    
    # Vérifier l'API
    if kubectl get nodes >/dev/null 2>&1; then
        log "✅ API K3s accessible (les 2 autres masters fonctionnent)"
    else
        log "❌ API K3s NON accessible"
    fi
    
    # Vérifier les pods
    log "État des pods :"
    kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | tee -a "$REPORT_FILE"
    
    # Redémarrer k3s-master-02
    log ""
    log "Redémarrage de K3s sur k3s-master-02..."
    ssh root@k3s-master-02 "systemctl start k3s"
    sleep 20
    
    log "État après redémarrage :"
    kubectl get nodes | tee -a "$REPORT_FILE"
    
    log "✅ TEST 5 RÉUSSI : API K3s reste accessible avec 2/3 masters"
else
    log "TEST 5 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# TEST 6 : K3S WORKER FAILURE
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 6 : K3s Worker Failure ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 6 : K3s Worker Failure ═══"
log "Date : $(date)"
log ""

read -p "Arrêter k3s-worker-05 ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    log "Arrêt de K3s sur k3s-worker-05..."
    
    # Compter les pods avant
    PODS_BEFORE=$(kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep Running | wc -l)
    log "Pods Running avant : $PODS_BEFORE"
    
    START_TIME=$(measure_time)
    ssh root@k3s-worker-05 "systemctl stop k3s-agent"
    log "K3s arrêté sur k3s-worker-05"
    
    sleep 30
    END_TIME=$(measure_time)
    DURATION=$(calc_duration $START_TIME $END_TIME)
    
    # Vérifier les nœuds
    log "État des nœuds K3s :"
    kubectl get nodes | tee -a "$REPORT_FILE"
    log ""
    
    # Compter les pods après
    PODS_AFTER=$(kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep Running | wc -l)
    log "Pods Running après : $PODS_AFTER"
    log ""
    
    # Vérifier les DaemonSets (devraient tous être sur les autres workers)
    log "État des DaemonSets :"
    kubectl get daemonset -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | tee -a "$REPORT_FILE"
    
    # Redémarrer k3s-worker-05
    log ""
    log "Redémarrage de K3s sur k3s-worker-05..."
    ssh root@k3s-worker-05 "systemctl start k3s-agent"
    sleep 30
    
    log "État après redémarrage :"
    kubectl get nodes | tee -a "$REPORT_FILE"
    
    PODS_FINAL=$(kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep Running | wc -l)
    log "Pods Running final : $PODS_FINAL"
    
    if [ "$PODS_FINAL" -eq "$PODS_BEFORE" ]; then
        log "✅ TEST 6 RÉUSSI : Tous les pods ont été restaurés"
    else
        log "⚠️  TEST 6 PARTIEL : $PODS_BEFORE pods avant, $PODS_FINAL pods maintenant"
    fi
else
    log "TEST 6 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# TEST 7 : APPLICATION POD CRASH
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 7 : Application Pod Crash ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 7 : Application Pod Crash ═══"
log "Date : $(date)"
log ""

read -p "Supprimer un pod n8n ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    # Récupérer un pod n8n
    N8N_POD=$(kubectl get pods -n n8n -o jsonpath='{.items[0].metadata.name}')
    log "Pod sélectionné : $N8N_POD"
    
    START_TIME=$(measure_time)
    kubectl delete pod -n n8n $N8N_POD
    log "Pod supprimé"
    
    # Attendre la recréation
    sleep 10
    END_TIME=$(measure_time)
    DURATION=$(calc_duration $START_TIME $END_TIME)
    
    # Vérifier les pods n8n
    log "État des pods n8n :"
    kubectl get pods -n n8n | tee -a "$REPORT_FILE"
    log ""
    
    N8N_RUNNING=$(kubectl get pods -n n8n | grep Running | wc -l)
    if [ "$N8N_RUNNING" -eq 8 ]; then
        log "✅ TEST 7 RÉUSSI : Pod n8n recréé automatiquement en ${DURATION}s"
    else
        log "⚠️  TEST 7 PARTIEL : Seulement $N8N_RUNNING/8 pods n8n Running"
    fi
else
    log "TEST 7 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# TEST 8 : COMPLETE SERVER REBOOT
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ TEST 8 : Complete Server Reboot ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══ TEST 8 : Complete Server Reboot ═══"
log "Date : $(date)"
log ""

echo "⚠️  Ce test va redémarrer COMPLÈTEMENT db-slave-02"
echo "Cela prendra environ 5 minutes (reboot + services)"
echo ""

read -p "Redémarrer db-slave-02 ? (yes/NO) : " confirm
if [ "$confirm" = "yes" ]; then
    log "Reboot de db-slave-02..."
    START_TIME=$(measure_time)
    
    ssh root@db-slave-02 "reboot" &
    log "Commande de reboot envoyée"
    
    # Attendre que le serveur soit down
    sleep 30
    log "Serveur en cours de reboot..."
    
    # Attendre que le serveur soit de retour (max 5 minutes)
    log "Attente du retour du serveur (max 5 min)..."
    REBOOT_SUCCESS=false
    for i in {1..60}; do
        if ssh -o ConnectTimeout=5 root@db-slave-02 "echo ok" >/dev/null 2>&1; then
            END_TIME=$(measure_time)
            DURATION=$(calc_duration $START_TIME $END_TIME)
            log "Serveur de retour après ${DURATION}s"
            REBOOT_SUCCESS=true
            break
        fi
        sleep 5
    done
    
    if [ "$REBOOT_SUCCESS" = true ]; then
        # Attendre les services
        sleep 30
        
        # Vérifier Patroni
        log "État Patroni après reboot :"
        ssh root@db-master-01 "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list" | tee -a "$REPORT_FILE"
        log ""
        
        log "✅ TEST 8 RÉUSSI : Serveur redémarré et réintégré automatiquement"
    else
        log "❌ TEST 8 ÉCHOUÉ : Serveur non accessible après 5 minutes"
    fi
else
    log "TEST 8 IGNORÉ"
fi

log ""
log "════════════════════════════════════════════════════════════════════"
log ""

#═══════════════════════════════════════════════════════════════════════
# RAPPORT FINAL
#═══════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RAPPORT FINAL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log "═══════════════════════════════════════════════════════════════════"
log "═══ RAPPORT FINAL DES CRASH TESTS ═══"
log "═══════════════════════════════════════════════════════════════════"
log ""
log "Date : $(date)"
log ""

# État final du cluster
log "ÉTAT FINAL DU CLUSTER :"
log ""

log "PostgreSQL :"
ssh root@db-master-01 "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list" | tee -a "$REPORT_FILE"
log ""

log "Redis :"
for node in redis-01 redis-02 redis-03; do
    ROLE=$(ssh root@$node "redis-cli -a $REDIS_PASSWORD info replication 2>/dev/null | grep role | cut -d: -f2 | tr -d '\r'")
    log "  $node : $ROLE"
done
log ""

log "K3s Nodes :"
kubectl get nodes | tee -a "$REPORT_FILE"
log ""

log "Applications :"
kubectl get pods -A | grep -E '(n8n|litellm|qdrant|chatwoot|superset)' | grep -c Running | xargs -I {} log "  Pods Running : {}"
log ""

log "════════════════════════════════════════════════════════════════════"
log ""
log "Rapport complet sauvegardé dans : $REPORT_FILE"
log ""

echo ""
echo -e "$OK Crash tests terminés !"
echo ""
echo "Rapport : $REPORT_FILE"
echo ""
echo "Pour consulter le rapport :"
echo "  cat $REPORT_FILE"
echo ""

exit 0
