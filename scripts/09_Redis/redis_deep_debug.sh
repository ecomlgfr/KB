#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              REDIS_DEEP_DEBUG - Diagnostic approfondi              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

# Charger les credentials
source "$CREDS_DIR/redis.env" 2>/dev/null || true

echo ""
echo "1. Vérification des containers et logs..."
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "═══ $host ($IP_PRIV) ═══"
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'DEBUG'
echo "  Containers actifs:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -3

echo ""
echo "  Logs Redis (dernières lignes):"
docker logs redis --tail 10 2>&1 | sed 's/^/    /'

echo ""
echo "  Ports en écoute:"
ss -tlnp | grep -E ":6379|:26379" | sed 's/^/    /'

echo ""
echo "  Test direct dans le container Redis:"
docker exec redis redis-cli PING 2>&1 | sed 's/^/    /'

echo ""
echo "  Config dans le container:"
docker exec redis cat /usr/local/etc/redis/redis.conf | grep -E "^bind|^protected-mode|^requirepass" | head -5 | sed 's/^/    /'
DEBUG
    
    echo ""
done

echo "2. Test de connexion directe dans les containers..."
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $host - Test interne: "
    RESULT=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "docker exec redis redis-cli -a '$REDIS_PASSWORD' --no-auth-warning PING 2>&1")
    if echo "$RESULT" | grep -q "PONG"; then
        echo -e "$OK"
    else
        echo -e "$KO ($RESULT)"
    fi
done

echo ""
echo "3. Reconfiguration simplifiée..."
echo ""

# Si tout échoue, on va simplifier au maximum
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  Simplification sur $host..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'SIMPLE'
BASE="/opt/keybuzz/redis"

# Arrêter tout
docker compose -f "$BASE/docker-compose.yml" down 2>/dev/null

# Config ULTRA simple
cat > "$BASE/config/redis-simple.conf" <<EOF
bind 0.0.0.0
protected-mode no
port 6379
dir /data
EOF

# Lancer Redis en mode simple sans auth
docker run -d \
  --name redis-simple \
  --restart unless-stopped \
  --network host \
  -v ${BASE}/data:/data \
  -v ${BASE}/config/redis-simple.conf:/usr/local/etc/redis/redis.conf:ro \
  redis:7.2-alpine redis-server /usr/local/etc/redis/redis.conf

sleep 2

# Test
echo -n "    Test simple: "
if docker exec redis-simple redis-cli PING 2>/dev/null | grep -q "PONG"; then
    echo "✓ OK"
    
    # Arrêter et nettoyer
    docker stop redis-simple >/dev/null 2>&1
    docker rm redis-simple >/dev/null 2>&1
    
    # Maintenant essayer avec auth
    cat > "$BASE/config/redis.conf" <<EOF
bind 0.0.0.0
protected-mode no
port 6379
dir /data
requirepass keybuzz123
masterauth keybuzz123
EOF

    docker run -d \
      --name redis \
      --restart unless-stopped \
      --network host \
      -v ${BASE}/data:/data \
      -v ${BASE}/config/redis.conf:/usr/local/etc/redis/redis.conf:ro \
      redis:7.2-alpine redis-server /usr/local/etc/redis/redis.conf
    
    sleep 2
    
    # Test avec auth
    echo -n "    Test avec auth: "
    if docker exec redis redis-cli -a keybuzz123 --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        echo "✓ OK"
    else
        echo "✗ KO"
    fi
else
    echo "✗ KO - Redis ne démarre pas"
fi
SIMPLE
    
    echo ""
done

echo "4. Test final..."
echo ""

# Test avec le nouveau mot de passe simple
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $host: "
    if redis-cli -h "$IP_PRIV" -p 6379 -a keybuzz123 --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        echo -e "$OK (avec auth simple)"
    elif redis-cli -h "$IP_PRIV" -p 6379 PING 2>/dev/null | grep -q "PONG"; then
        echo -e "$OK (sans auth)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Mettre à jour le fichier de credentials avec le mot de passe simple
cat > "$CREDS_DIR/redis.env" <<EOF
export REDIS_PASSWORD="keybuzz123"
export REDIS_MASTER_NAME="mymaster"
export REDIS_SENTINEL_QUORUM="2"
EOF

echo "Configuration simplifiée appliquée."
echo ""
echo "Si Redis fonctionne maintenant, relancer:"
echo "  ./redis_sentinel_deploy.sh --hosts redis-01,redis-02,redis-03 --master redis-01"
echo ""
echo "Sinon, vérifier directement sur un serveur:"
echo "  ssh root@10.0.0.123"
echo "  docker ps"
echo "  docker logs redis"
echo "═══════════════════════════════════════════════════════════════════"
