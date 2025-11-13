#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║            REDIS_FIX - Diagnostic et correction Redis              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"

# Charger les credentials
source "$CREDS_DIR/redis.env"

echo ""
echo "1. Vérification des services Docker sur chaque nœud..."
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  $host ($IP_PRIV):"
    
    # Vérifier les containers
    echo -n "    Containers: "
    CONTAINERS=$(ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "docker ps --format '{{.Names}}' | grep -E 'redis|sentinel' | wc -l")
    if [ "$CONTAINERS" -eq 2 ]; then
        echo -e "$OK (2 actifs)"
    else
        echo -e "$KO ($CONTAINERS actifs)"
    fi
    
    # Vérifier les logs Redis
    echo "    Logs Redis:"
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "docker logs redis --tail 5 2>&1" | sed 's/^/      /'
    
    # Vérifier l'écoute des ports
    echo "    Ports:"
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" "ss -tlnp | grep -E ':6379|:26379'" | sed 's/^/      /'
    
    echo ""
done

echo "2. Test de connectivité depuis install-01..."
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $host - Redis (6379): "
    if timeout 2 nc -zv "$IP_PRIV" 6379 &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    echo -n "  $host - Sentinel (26379): "
    if timeout 2 nc -zv "$IP_PRIV" 26379 &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "3. Correction de la configuration bind..."
echo ""

# Corriger la configuration sur chaque nœud
for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  Correction sur $host..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash -s "$REDIS_PASSWORD" "$IP_PRIV" <<'FIX_CONFIG'
REDIS_PASSWORD="$1"
MY_IP="$2"
BASE="/opt/keybuzz/redis"

# Arrêter les services
docker compose -f "$BASE/docker-compose.yml" down

# Corriger redis.conf - bind sur l'IP privée ET 0.0.0.0
sed -i "s/^bind .*/bind 0.0.0.0 $MY_IP/" "$BASE/config/redis.conf"
sed -i "s/^protected-mode .*/protected-mode no/" "$BASE/config/redis.conf"

# Corriger sentinel.conf
sed -i "s/^bind .*/bind 0.0.0.0/" "$BASE/config/sentinel.conf"
sed -i "s/^protected-mode .*/protected-mode no/" "$BASE/config/sentinel.conf"

# Redémarrer
docker compose -f "$BASE/docker-compose.yml" up -d

sleep 3
FIX_CONFIG
done

echo ""
echo "4. Attente de stabilisation (5s)..."
sleep 5

echo ""
echo "5. Test de connexion avec mot de passe..."
echo ""

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $host - PING: "
    RESULT=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null)
    if [ "$RESULT" = "PONG" ]; then
        echo -e "$OK"
        
        # Vérifier le rôle
        ROLE=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        echo "    Role: $ROLE"
    else
        echo -e "$KO"
        
        # Essayer sans mot de passe
        echo -n "    Sans auth: "
        if redis-cli -h "$IP_PRIV" -p 6379 PING 2>/dev/null | grep -q "PONG"; then
            echo "OK (pas d'auth requise)"
        else
            echo "KO"
        fi
    fi
done

echo ""
echo "6. Test des Sentinels..."
echo ""

MASTER_IP=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $host - Sentinel master: "
    DETECTED=$(redis-cli -h "$IP_PRIV" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
    if [ -n "$DETECTED" ]; then
        echo -e "$OK (voit: $DETECTED)"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "7. Configuration de la réplication..."
echo ""

# Configurer redis-02 et redis-03 comme replicas
for host in redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "  Configuration $host comme replica..."
    redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SLAVEOF "$MASTER_IP" 6379 2>/dev/null || \
    redis-cli -h "$IP_PRIV" -p 6379 SLAVEOF "$MASTER_IP" 6379 2>/dev/null
done

sleep 3

echo ""
echo "8. Test final de réplication..."
echo ""

# Écrire sur le master
echo -n "  Écriture sur master: "
TEST_VALUE="test_$(date +%s)"
if redis-cli -h "$MASTER_IP" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning SET test_key "$TEST_VALUE" 2>/dev/null | grep -q "OK"; then
    echo -e "$OK"
    
    # Lire sur les replicas
    for host in redis-02 redis-03; do
        IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
        echo -n "    Lecture sur $host: "
        
        VALUE=$(redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning GET test_key 2>/dev/null)
        if [ "$VALUE" = "$TEST_VALUE" ]; then
            echo -e "$OK (valeur répliquée)"
        else
            echo -e "$KO"
        fi
    done
else
    echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Résumé
REDIS_OK=0
SENTINEL_OK=0

for host in redis-01 redis-02 redis-03; do
    IP_PRIV=$(awk -F'\t' -v h="$host" '$2==h {print $3}' "$SERVERS_TSV")
    
    redis-cli -h "$IP_PRIV" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING &>/dev/null && ((REDIS_OK++))
    redis-cli -h "$IP_PRIV" -p 26379 SENTINEL masters &>/dev/null && ((SENTINEL_OK++))
done

if [ "$REDIS_OK" -eq 3 ] && [ "$SENTINEL_OK" -eq 3 ]; then
    echo -e "$OK Redis Sentinel cluster opérationnel"
    echo ""
    echo "Prochaine étape OBLIGATOIRE:"
    echo "  Déployer le Load Balancer Redis pour 10.0.0.10:6379"
    echo "  ./redis_master_lb_deploy.sh --hosts haproxy-01,haproxy-02 --sentinels redis-01,redis-02"
else
    echo -e "$KO Cluster partiellement fonctionnel"
    echo "  Redis OK: $REDIS_OK/3"
    echo "  Sentinel OK: $SENTINEL_OK/3"
fi
echo "═══════════════════════════════════════════════════════════════════"
