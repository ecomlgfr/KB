#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          Vérification configuration Redis (password)              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

echo ""
echo "Test sur les nœuds Redis (redis-01, redis-02, redis-03)..."
echo ""

for node in redis-01 redis-02 redis-03; do
    echo "━━━ $node ━━━"
    
    NODE_IP=$(awk -F'\t' -v node="$node" '$2==node {print $3}' /opt/keybuzz-installer/inventory/servers.tsv)
    
    if [ -z "$NODE_IP" ]; then
        echo "  IP introuvable"
        continue
    fi
    
    echo "  IP : $NODE_IP"
    echo ""
    
    # Vérifier requirepass dans redis.conf
    echo "  Configuration requirepass :"
    ssh root@"$NODE_IP" "grep '^requirepass' /etc/redis/redis.conf 2>/dev/null || echo '  → Aucun mot de passe configuré'"
    
    echo ""
    
    # Tester la connexion Redis
    echo "  Test connexion Redis (sans password) :"
    ssh root@"$NODE_IP" "redis-cli -h 127.0.0.1 PING 2>&1 | head -3"
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Si vous voyez :"
echo "  • PONG                    → Redis SANS mot de passe"
echo "  • NOAUTH                  → Redis AVEC mot de passe"
echo "  • requirepass <password>  → Mot de passe Redis"
echo ""
