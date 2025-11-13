#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           INFRASTRUCTURE_DASHBOARD - État en temps réel            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m●\033[0m'
KO='\033[0;31m●\033[0m'
WARN='\033[0;33m●\033[0m'
INFO='\033[0;36mℹ\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

# Vérifier que nous sommes sur install-01
if [ ! -f "$SERVERS_TSV" ]; then
    echo "❌ Erreur: Ce script doit être exécuté depuis install-01"
    echo "   Fichier manquant: $SERVERS_TSV"
    exit 1
fi

# Récupérer les credentials
PG_PASS=$(jq -r '.postgres_password // "b2eUq9eBCxTMsatoQMNJ"' "$CREDS_DIR/secrets.json" 2>/dev/null || echo "b2eUq9eBCxTMsatoQMNJ")
REDIS_PASS=$(jq -r '.redis_password // "Lm1wszsUh07xuU9pttHw9YZOB"' "$CREDS_DIR/secrets.json" 2>/dev/null || echo "Lm1wszsUh07xuU9pttHw9YZOB")

# Fonction utilitaire
get_ip() {
    local hostname=$1
    awk -F'\t' -v h="$hostname" '$2==h{print $3}' "$SERVERS_TSV"
}

test_tcp() {
    timeout 2 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null
}

clear
echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                   KEYBUZZ INFRASTRUCTURE DASHBOARD                 ║"
echo "║                     $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: VIP ENDPOINTS
# ═══════════════════════════════════════════════════════════════════

echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ 🌐 VIP ENDPOINTS (10.0.0.10)                                        │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""

VIP="10.0.0.10"

# PostgreSQL HAProxy Write (5432)
if test_tcp "$VIP" 5432; then
    echo -e "  $OK PostgreSQL HAProxy Write      : $VIP:5432"
else
    echo -e "  $KO PostgreSQL HAProxy Write      : $VIP:5432"
fi

# PostgreSQL HAProxy Read (5433)
if test_tcp "$VIP" 5433; then
    echo -e "  $OK PostgreSQL HAProxy Read       : $VIP:5433"
else
    echo -e "  $KO PostgreSQL HAProxy Read       : $VIP:5433"
fi

# PgBouncer (6432)
if test_tcp "$VIP" 6432; then
    echo -e "  $OK PgBouncer                     : $VIP:6432"
    
    # Test SQL
    if PGPASSWORD="$PG_PASS" psql -h "$VIP" -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        echo -e "      └─ SQL connexion           : ✓ OK"
    else
        echo -e "      └─ SQL connexion           : ✗ KO"
    fi
else
    echo -e "  $KO PgBouncer                     : $VIP:6432"
fi

# Redis (6379)
if test_tcp "$VIP" 6379; then
    echo -e "  $OK Redis                         : $VIP:6379"
    
    # Test PING
    if redis-cli -h "$VIP" -p 6379 -a "$REDIS_PASS" PING 2>/dev/null | grep -q "PONG"; then
        echo -e "      └─ PING                    : ✓ OK"
    else
        echo -e "      └─ PING                    : ✗ KO"
    fi
else
    echo -e "  $KO Redis                         : $VIP:6379"
fi

# RabbitMQ AMQP (5672)
if test_tcp "$VIP" 5672; then
    echo -e "  $OK RabbitMQ AMQP                 : $VIP:5672"
else
    echo -e "  $KO RabbitMQ AMQP                 : $VIP:5672"
fi

# RabbitMQ Management (15672)
if test_tcp "$VIP" 15672; then
    echo -e "  $OK RabbitMQ Management           : $VIP:15672"
else
    echo -e "  $KO RabbitMQ Management           : $VIP:15672"
fi

# K3s API (6443)
if test_tcp "$VIP" 6443; then
    echo -e "  $OK K3s API                       : $VIP:6443"
else
    echo -e "  $KO K3s API                       : $VIP:6443"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: POSTGRESQL CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ 🐘 POSTGRESQL CLUSTER (Patroni)                                    │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""

DB_MASTER_IP=$(get_ip "db-master-01")
if [ -n "$DB_MASTER_IP" ]; then
    CLUSTER_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$DB_MASTER_IP" \
        "docker exec patroni patronictl list 2>/dev/null" || echo "")
    
    if [ -n "$CLUSTER_STATUS" ]; then
        echo "$CLUSTER_STATUS" | while IFS= read -r line; do
            if echo "$line" | grep -q "Leader"; then
                echo -e "  $OK $line"
            elif echo "$line" | grep -q "Replica.*streaming"; then
                echo -e "  $OK $line"
            elif echo "$line" | grep -q "running"; then
                echo -e "  $OK $line"
            else
                echo "  $line"
            fi
        done
        
        # Compter les nœuds
        LEADER_COUNT=$(echo "$CLUSTER_STATUS" | grep -c "Leader" || echo 0)
        REPLICA_COUNT=$(echo "$CLUSTER_STATUS" | grep -c "Replica.*streaming" || echo 0)
        
        echo ""
        if [ "$LEADER_COUNT" -eq 1 ] && [ "$REPLICA_COUNT" -eq 2 ]; then
            echo -e "  $OK Cluster: 1 Leader + 2 Replicas (OPTIMAL)"
        elif [ "$LEADER_COUNT" -eq 1 ]; then
            echo -e "  $WARN Cluster: 1 Leader + $REPLICA_COUNT Replicas (DÉGRADÉ)"
        else
            echo -e "  $KO Cluster: $LEADER_COUNT Leaders (PROBLÈME)"
        fi
    else
        echo -e "  $KO Impossible de récupérer l'état du cluster"
    fi
else
    echo -e "  $KO IP db-master-01 non trouvée"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: HAPROXY & KEEPALIVED
# ═══════════════════════════════════════════════════════════════════

echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ ⚖️  HAPROXY & KEEPALIVED                                            │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""

for host in haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    # Vérifier si la VIP est sur ce nœud
    VIP_ACTIVE=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "ip addr show | grep '10.0.0.10/32' 2>/dev/null" || echo "")
    
    if [ -n "$VIP_ACTIVE" ]; then
        ROLE="🟢 MASTER (VIP active)"
    else
        ROLE="🔵 BACKUP"
    fi
    
    # Vérifier HAProxy
    HAPROXY_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=haproxy --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$HAPROXY_STATUS" | grep -q "Up"; then
        echo -e "  $OK $host ($IP) - $ROLE"
        echo "      ├─ HAProxy        : ✓ Running"
    else
        echo -e "  $KO $host ($IP) - $ROLE"
        echo "      ├─ HAProxy        : ✗ Down"
    fi
    
    # Vérifier PgBouncer
    PGBOUNCER_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=pgbouncer --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$PGBOUNCER_STATUS" | grep -q "Up"; then
        echo "      ├─ PgBouncer      : ✓ Running"
    else
        echo "      ├─ PgBouncer      : ✗ Down"
    fi
    
    # Vérifier Keepalived
    KEEPALIVED_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=keepalived --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$KEEPALIVED_STATUS" | grep -q "Up"; then
        echo "      └─ Keepalived     : ✓ Running"
    else
        echo "      └─ Keepalived     : ✗ Down"
    fi
    
    echo ""
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 4: REDIS SENTINEL
# ═══════════════════════════════════════════════════════════════════

echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ 📦 REDIS CLUSTER + SENTINEL                                         │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""

# Détecter le master
REDIS_01_IP=$(get_ip "redis-01")
if [ -n "$REDIS_01_IP" ]; then
    MASTER_INFO=$(ssh -o StrictHostKeyChecking=no root@"$REDIS_01_IP" \
        "docker exec sentinel redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null" || echo "")
    
    MASTER_IP=$(echo "$MASTER_INFO" | head -1)
    
    if [ -n "$MASTER_IP" ]; then
        echo -e "  $INFO Sentinel Master: $MASTER_IP"
        echo ""
    fi
fi

for host in redis-01 redis-02 redis-03; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    # Déterminer le rôle
    if [ "$IP" = "$MASTER_IP" ]; then
        ROLE="🔴 MASTER"
    else
        ROLE="🔵 REPLICA"
    fi
    
    REDIS_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=redis --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$REDIS_STATUS" | grep -q "Up"; then
        echo -e "  $OK $host ($IP) - $ROLE"
        echo "      ├─ Redis          : ✓ Running"
    else
        echo -e "  $KO $host ($IP) - $ROLE"
        echo "      ├─ Redis          : ✗ Down"
    fi
    
    SENTINEL_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=sentinel --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$SENTINEL_STATUS" | grep -q "Up"; then
        echo "      └─ Sentinel       : ✓ Running"
    else
        echo "      └─ Sentinel       : ✗ Down"
    fi
    
    echo ""
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 5: RABBITMQ CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ 🐰 RABBITMQ CLUSTER                                                 │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""

for host in rabbitmq-01 rabbitmq-02 rabbitmq-03; do
    IP=$(get_ip "$host")
    [ -z "$IP" ] && continue
    
    RMQ_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=rabbitmq --format '{{.Status}}' 2>/dev/null" || echo "")
    
    if echo "$RMQ_STATUS" | grep -q "Up"; then
        echo -e "  $OK $host ($IP)"
        echo "      ├─ RabbitMQ       : ✓ Running"
        
        # Vérifier les ports
        if test_tcp "$IP" 5672; then
            echo "      ├─ AMQP (5672)    : ✓ OK"
        else
            echo "      ├─ AMQP (5672)    : ✗ KO"
        fi
        
        if test_tcp "$IP" 15672; then
            echo "      └─ Management     : ✓ OK"
        else
            echo "      └─ Management     : ✗ KO"
        fi
    else
        echo -e "  $KO $host ($IP)"
        echo "      └─ RabbitMQ       : ✗ Down"
    fi
    
    echo ""
done

# Vérifier l'état du cluster
RMQ_01_IP=$(get_ip "rabbitmq-01")
if [ -n "$RMQ_01_IP" ]; then
    CLUSTER_NODES=$(ssh -o StrictHostKeyChecking=no root@"$RMQ_01_IP" \
        "docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | grep -c '@rabbitmq-0' || echo 0")
    
    if [ "$CLUSTER_NODES" -ge 3 ]; then
        echo -e "  $OK Cluster: $CLUSTER_NODES/3 nœuds actifs"
    else
        echo -e "  $WARN Cluster: $CLUSTER_NODES/3 nœuds actifs (DÉGRADÉ)"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION 6: K3S CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ ☸️  K3S KUBERNETES CLUSTER                                          │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""

K3S_MASTER_IP=$(get_ip "k3s-master-01")
if [ -n "$K3S_MASTER_IP" ]; then
    NODES_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$K3S_MASTER_IP" \
        "kubectl get nodes --no-headers 2>/dev/null" || echo "")
    
    if [ -n "$NODES_STATUS" ]; then
        TOTAL_NODES=$(echo "$NODES_STATUS" | wc -l)
        READY_NODES=$(echo "$NODES_STATUS" | grep -c " Ready" || echo 0)
        NOTREADY_NODES=$(echo "$NODES_STATUS" | grep -c "NotReady" || echo 0)
        
        echo -e "  Nœuds K3s:"
        echo "  ├─ Total          : $TOTAL_NODES"
        
        if [ "$READY_NODES" -eq "$TOTAL_NODES" ]; then
            echo -e "  ├─ Ready          : $OK $READY_NODES/$TOTAL_NODES"
        else
            echo -e "  ├─ Ready          : $WARN $READY_NODES/$TOTAL_NODES"
        fi
        
        if [ "$NOTREADY_NODES" -gt 0 ]; then
            echo -e "  └─ NotReady       : $KO $NOTREADY_NODES"
        else
            echo -e "  └─ NotReady       : $OK 0"
        fi
        
        echo ""
        
        # Pods système
        SYSTEM_PODS=$(ssh -o StrictHostKeyChecking=no root@"$K3S_MASTER_IP" \
            "kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c 'Running' || echo 0")
        
        echo "  Pods système (kube-system):"
        if [ "$SYSTEM_PODS" -ge 5 ]; then
            echo -e "  └─ Running        : $OK $SYSTEM_PODS pods"
        else
            echo -e "  └─ Running        : $WARN $SYSTEM_PODS pods"
        fi
    else
        echo -e "  $KO Impossible de récupérer l'état du cluster K3s"
    fi
else
    echo -e "  $KO IP k3s-master-01 non trouvée"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION 7: RÉSUMÉ GÉNÉRAL
# ═══════════════════════════════════════════════════════════════════

echo "┌────────────────────────────────────────────────────────────────────┐"
echo "│ 📊 RÉSUMÉ GÉNÉRAL                                                   │"
echo "└────────────────────────────────────────────────────────────────────┘"
echo ""

# Compter les services OK/KO
OK_COUNT=0
TOTAL_COUNT=0

# Test VIP endpoints
for port in 5432 5433 6432 6379 5672 15672 6443; do
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if test_tcp "$VIP" "$port" 1; then
        OK_COUNT=$((OK_COUNT + 1))
    fi
done

# Test Patroni cluster
if [ "$LEADER_COUNT" -eq 1 ] && [ "$REPLICA_COUNT" -eq 2 ]; then
    OK_COUNT=$((OK_COUNT + 1))
fi
TOTAL_COUNT=$((TOTAL_COUNT + 1))

# Test HAProxy/Keepalived
for host in haproxy-01 haproxy-02; do
    IP=$(get_ip "$host")
    HAPROXY_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=haproxy --format '{{.Status}}' 2>/dev/null" || echo "")
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if echo "$HAPROXY_STATUS" | grep -q "Up"; then
        OK_COUNT=$((OK_COUNT + 1))
    fi
done

# Test Redis
for host in redis-01 redis-02 redis-03; do
    IP=$(get_ip "$host")
    REDIS_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=redis --format '{{.Status}}' 2>/dev/null" || echo "")
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if echo "$REDIS_STATUS" | grep -q "Up"; then
        OK_COUNT=$((OK_COUNT + 1))
    fi
done

# Test RabbitMQ
for host in rabbitmq-01 rabbitmq-02 rabbitmq-03; do
    IP=$(get_ip "$host")
    RMQ_STATUS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker ps --filter name=rabbitmq --format '{{.Status}}' 2>/dev/null" || echo "")
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if echo "$RMQ_STATUS" | grep -q "Up"; then
        OK_COUNT=$((OK_COUNT + 1))
    fi
done

# Test K3s
if [ "$READY_NODES" -ge 3 ]; then
    OK_COUNT=$((OK_COUNT + 1))
fi
TOTAL_COUNT=$((TOTAL_COUNT + 1))

# Calculer le pourcentage
HEALTH_PERCENT=$((OK_COUNT * 100 / TOTAL_COUNT))

echo "  Composants vérifiés: $OK_COUNT/$TOTAL_COUNT fonctionnels"
echo ""

if [ "$HEALTH_PERCENT" -ge 95 ]; then
    echo -e "  État global: $OK EXCELLENT ($HEALTH_PERCENT%)"
    echo "  └─ Infrastructure opérationnelle et performante"
elif [ "$HEALTH_PERCENT" -ge 80 ]; then
    echo -e "  État global: $WARN ACCEPTABLE ($HEALTH_PERCENT%)"
    echo "  └─ Infrastructure fonctionnelle avec quelques problèmes mineurs"
else
    echo -e "  État global: $KO DÉGRADÉ ($HEALTH_PERCENT%)"
    echo "  └─ Problèmes critiques détectés, action requise"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                      Fin du dashboard                              ║"
echo "║         Pour des tests détaillés, lancez:                          ║"
echo "║         ./test_infrastructure_complete.sh                          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

exit 0
