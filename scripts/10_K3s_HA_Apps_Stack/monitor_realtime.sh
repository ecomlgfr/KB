#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    SURVEILLANCE TEMPS RÉEL - Infrastructure KeyBuzz               ║"
echo "║    (Monitoring pendant les crash tests)                           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo "servers.tsv introuvable"; exit 1; }

# Charger credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
fi

if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
fi

echo ""
echo "Ce script affiche l'état de l'infrastructure en temps réel."
echo "Lancez-le dans un terminal pendant que vous exécutez les crash tests."
echo ""
echo "Appuyez sur Ctrl+C pour arrêter."
echo ""
sleep 3

while true; do
    clear
    
    echo "════════════════════════════════════════════════════════════════════"
    echo "SURVEILLANCE INFRASTRUCTURE - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    
    # PostgreSQL Patroni
    echo "┌─ PostgreSQL Patroni ────────────────────────────────────────────┐"
    ssh root@db-master-01 "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list 2>/dev/null" | head -n 10 || echo "  ❌ Non accessible"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Redis Sentinel
    echo "┌─ Redis Cluster ─────────────────────────────────────────────────┐"
    for node in redis-01 redis-02 redis-03; do
        ROLE=$(ssh root@$node "redis-cli -a $REDIS_PASSWORD info replication 2>/dev/null | grep ^role | cut -d: -f2 | tr -d '\r'" 2>/dev/null || echo "down")
        if [ "$ROLE" = "master" ]; then
            printf "  %-12s : \033[0;32m%-10s\033[0m (MASTER)\n" "$node" "$ROLE"
        elif [ "$ROLE" = "slave" ]; then
            printf "  %-12s : \033[0;36m%-10s\033[0m\n" "$node" "$ROLE"
        else
            printf "  %-12s : \033[0;31m%-10s\033[0m\n" "$node" "DOWN"
        fi
    done
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # HAProxy
    echo "┌─ HAProxy + Keepalived ──────────────────────────────────────────┐"
    for node in haproxy-01 haproxy-02; do
        HAPROXY_STATUS=$(ssh root@$node "systemctl is-active haproxy 2>/dev/null" || echo "unknown")
        VIP=$(ssh root@$node "ip addr show | grep '10.0.0.10'" 2>/dev/null)
        if [ "$HAPROXY_STATUS" = "active" ]; then
            printf "  %-12s : \033[0;32m%-10s\033[0m" "$node" "ACTIVE"
        else
            printf "  %-12s : \033[0;31m%-10s\033[0m" "$node" "INACTIVE"
        fi
        if [ -n "$VIP" ]; then
            printf " (VIP 10.0.0.10)\n"
        else
            printf "\n"
        fi
    done
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # K3s Nodes
    echo "┌─ K3s Cluster ───────────────────────────────────────────────────┐"
    kubectl get nodes --no-headers 2>/dev/null | while read line; do
        NODE=$(echo $line | awk '{print $1}')
        STATUS=$(echo $line | awk '{print $2}')
        if [ "$STATUS" = "Ready" ]; then
            printf "  %-20s : \033[0;32m%-10s\033[0m\n" "$NODE" "$STATUS"
        else
            printf "  %-20s : \033[0;31m%-10s\033[0m\n" "$NODE" "$STATUS"
        fi
    done || echo "  ❌ API K3s non accessible"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Applications
    echo "┌─ Applications (Pods Running) ───────────────────────────────────┐"
    N8N_COUNT=$(kubectl get pods -n n8n --no-headers 2>/dev/null | grep -c Running || echo "0")
    LITELLM_COUNT=$(kubectl get pods -n litellm --no-headers 2>/dev/null | grep -c Running || echo "0")
    QDRANT_COUNT=$(kubectl get pods -n qdrant --no-headers 2>/dev/null | grep -c Running || echo "0")
    CHATWOOT_WEB=$(kubectl get pods -n chatwoot --no-headers 2>/dev/null | grep chatwoot-web | grep -c Running || echo "0")
    CHATWOOT_WORKER=$(kubectl get pods -n chatwoot --no-headers 2>/dev/null | grep chatwoot-worker | grep -c Running || echo "0")
    SUPERSET_COUNT=$(kubectl get pods -n superset --no-headers 2>/dev/null | grep -c Running || echo "0")
    
    printf "  n8n              : "
    if [ "$N8N_COUNT" -eq 8 ]; then
        printf "\033[0;32m%d/8\033[0m pods\n" "$N8N_COUNT"
    else
        printf "\033[0;31m%d/8\033[0m pods\n" "$N8N_COUNT"
    fi
    
    printf "  LiteLLM          : "
    if [ "$LITELLM_COUNT" -eq 8 ]; then
        printf "\033[0;32m%d/8\033[0m pods\n" "$LITELLM_COUNT"
    else
        printf "\033[0;31m%d/8\033[0m pods\n" "$LITELLM_COUNT"
    fi
    
    printf "  Qdrant           : "
    if [ "$QDRANT_COUNT" -eq 8 ]; then
        printf "\033[0;32m%d/8\033[0m pods\n" "$QDRANT_COUNT"
    else
        printf "\033[0;31m%d/8\033[0m pods\n" "$QDRANT_COUNT"
    fi
    
    printf "  Chatwoot Web     : "
    if [ "$CHATWOOT_WEB" -eq 8 ]; then
        printf "\033[0;32m%d/8\033[0m pods\n" "$CHATWOOT_WEB"
    else
        printf "\033[0;31m%d/8\033[0m pods\n" "$CHATWOOT_WEB"
    fi
    
    printf "  Chatwoot Worker  : "
    if [ "$CHATWOOT_WORKER" -eq 8 ]; then
        printf "\033[0;32m%d/8\033[0m pods\n" "$CHATWOOT_WORKER"
    else
        printf "\033[0;31m%d/8\033[0m pods\n" "$CHATWOOT_WORKER"
    fi
    
    printf "  Superset         : "
    if [ "$SUPERSET_COUNT" -eq 8 ]; then
        printf "\033[0;32m%d/8\033[0m pods\n" "$SUPERSET_COUNT"
    else
        printf "\033[0;31m%d/8\033[0m pods\n" "$SUPERSET_COUNT"
    fi
    
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Connectivité services
    echo "┌─ Tests de connectivité ─────────────────────────────────────────┐"
    
    # PostgreSQL
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -h 10.0.0.10 -p 6432 -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        printf "  PostgreSQL (PgBouncer) : \033[0;32mOK\033[0m\n"
    else
        printf "  PostgreSQL (PgBouncer) : \033[0;31mKO\033[0m\n"
    fi
    
    # Redis
    if redis-cli -h 10.0.0.10 -p 6379 -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
        printf "  Redis                  : \033[0;32mOK\033[0m\n"
    else
        printf "  Redis                  : \033[0;31mKO\033[0m\n"
    fi
    
    # RabbitMQ
    if timeout 2 bash -c "echo > /dev/tcp/10.0.0.10/5672" 2>/dev/null; then
        printf "  RabbitMQ               : \033[0;32mOK\033[0m\n"
    else
        printf "  RabbitMQ               : \033[0;31mKO\033[0m\n"
    fi
    
    # K3s API
    if kubectl get nodes >/dev/null 2>&1; then
        printf "  K3s API                : \033[0;32mOK\033[0m\n"
    else
        printf "  K3s API                : \033[0;31mKO\033[0m\n"
    fi
    
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    
    echo "Rafraîchissement toutes les 5 secondes... (Ctrl+C pour arrêter)"
    
    sleep 5
done
