#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          CLEANUP_REDIS_RABBITMQ - Nettoyage avant re-test          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

echo ""
echo "Nettoyage des containers Redis et RabbitMQ"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# NETTOYAGE REDIS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Nettoyage Redis (redis-01/02/03)                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in redis-01 redis-02 redis-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  $host ($IP): "
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" bash <<'CLEANUP' 2>/dev/null
docker stop redis sentinel 2>/dev/null
docker rm redis sentinel 2>/dev/null
exit 0
CLEANUP
    
    echo -e "$OK Nettoyé"
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# NETTOYAGE RABBITMQ
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Nettoyage RabbitMQ (queue-01/02/03)                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in queue-01 queue-02 queue-03; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  $host ($IP): "
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" bash <<'CLEANUP' 2>/dev/null
docker stop rabbitmq 2>/dev/null
docker rm rabbitmq 2>/dev/null
exit 0
CLEANUP
    
    echo -e "$OK Nettoyé"
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# NETTOYAGE HAPROXY
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Nettoyage HAProxy (haproxy-01/02)                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for host in haproxy-01 haproxy-02; do
    IP=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    echo -n "  $host ($IP): "
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" bash <<'CLEANUP' 2>/dev/null
docker stop haproxy-redis redis-sentinel-watcher haproxy-rabbitmq 2>/dev/null
docker rm haproxy-redis redis-sentinel-watcher haproxy-rabbitmq 2>/dev/null
exit 0
CLEANUP
    
    echo -e "$OK Nettoyé"
done

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Nettoyage terminé                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  Containers supprimés:"
echo "    • Redis (3 nœuds) + Sentinel"
echo "    • RabbitMQ (3 nœuds)"
echo "    • HAProxy Redis + Watcher"
echo "    • HAProxy RabbitMQ"
echo ""
echo "  Notes:"
echo "    • Les volumes/data sont conservés (/opt/keybuzz/*/data)"
echo "    • Les configurations sont conservées"
echo "    • Les credentials sont conservés"
echo ""
echo -e "$OK Prêt pour réinstallation"
echo ""
echo "  Commandes suivantes:"
echo "    1. ./redis_ha_install_final_PATCHED.sh"
echo "    2. ./rabbitmq_ha_install_PATCHED.sh"
echo "    3. sleep 30 && ./diagnostic_redis_rmq_V2.sh"
echo ""
