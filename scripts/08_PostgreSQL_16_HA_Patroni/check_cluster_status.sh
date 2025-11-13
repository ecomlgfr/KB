#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                 CHECK_CLUSTER_STATUS - État réel du cluster        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

echo ""
echo "1. Vérification des containers Docker..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo "  $hostname ($ip):"
    
    # État Patroni
    echo -n "    Container Patroni: "
    PATRONI_STATUS=$(ssh root@"$ip" "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep patroni" 2>/dev/null)
    if [ -n "$PATRONI_STATUS" ]; then
        echo "$PATRONI_STATUS"
    else
        echo -e "$KO Pas de container ou arrêté"
        
        # Vérifier s'il existe mais est arrêté
        STOPPED=$(ssh root@"$ip" "docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep patroni" 2>/dev/null)
        if [ -n "$STOPPED" ]; then
            echo "      État: $STOPPED"
            
            # Afficher les dernières erreurs
            echo "      Dernière erreur:"
            ssh root@"$ip" "docker logs patroni 2>&1 | tail -3" 2>/dev/null | sed 's/^/        /'
        fi
    fi
done

echo ""
echo "2. Test PostgreSQL direct (sans Patroni API)..."
echo ""

source /opt/keybuzz-installer/credentials/postgres.env

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo -n "  Test PostgreSQL $hostname (port 5432): "
    
    # Test direct avec psql
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -d postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -E "t|f" > /dev/null; then
        RECOVERY=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -d postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | tr -d ' ')
        if [ "$RECOVERY" = "f" ]; then
            echo -e "$OK (Master/Leader)"
        else
            echo -e "$OK (Replica)"
        fi
    else
        echo -e "$KO"
    fi
done

echo ""
echo "3. Redémarrage de Patroni si nécessaire..."
echo ""

NEED_RESTART=false

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    # Vérifier si Patroni est arrêté
    if ! ssh root@"$ip" "docker ps | grep -q patroni" 2>/dev/null; then
        NEED_RESTART=true
        echo -n "  Redémarrage Patroni sur $ip: "
        
        # Essayer de redémarrer
        ssh root@"$ip" bash <<'RESTART' 2>/dev/null
# Si le container existe mais est arrêté
if docker ps -a | grep -q patroni; then
    docker start patroni
else
    # Sinon le recréer
    docker run -d \
      --name patroni \
      --hostname $(hostname) \
      --network host \
      --restart unless-stopped \
      -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
      -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
      -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
      patroni:17-raft
fi
RESTART
        
        echo -e "$OK"
    fi
done

if [ "$NEED_RESTART" = true ]; then
    echo ""
    echo "  Attente du redémarrage (30s)..."
    sleep 30
fi

echo ""
echo "4. Test final des connexions HAProxy..."
echo ""

# Test via HAProxy
echo -n "  Via haproxy-01 port 5432 (write): "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo -n "  Via haproxy-01 port 5433 (read): "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5433 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "5. État final de l'API Patroni..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  API Patroni $ip: "
    if curl -s "http://$ip:8008/patroni" 2>/dev/null | grep -q "state"; then
        STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d.get(\"state\")}/{d.get(\"role\")}')" 2>/dev/null || echo "ERROR")
        echo -e "$OK $STATE"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "RÉSUMÉ:"

# Compter les services fonctionnels
PATRONI_OK=0
POSTGRES_OK=0
HAPROXY_OK=0

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    curl -s "http://$ip:8008/patroni" 2>/dev/null | grep -q "state" && PATRONI_OK=$((PATRONI_OK + 1))
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && POSTGRES_OK=$((POSTGRES_OK + 1))
done

PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.11 -p 5432 -U postgres -d postgres -c "SELECT 1" &>/dev/null && HAPROXY_OK=$((HAPROXY_OK + 1))

echo "  • PostgreSQL direct: $POSTGRES_OK/3 nœuds accessibles"
echo "  • Patroni API: $PATRONI_OK/3 nœuds actifs"
echo "  • HAProxy: $([ $HAPROXY_OK -gt 0 ] && echo "Fonctionnel" || echo "Non fonctionnel")"
echo ""

if [ $POSTGRES_OK -eq 3 ] && [ $HAPROXY_OK -gt 0 ]; then
    echo -e "$OK Le cluster est FONCTIONNEL même si l'API Patroni a des problèmes"
    echo ""
    echo "Vous pouvez utiliser le cluster via HAProxy:"
    echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.11 -p 5432 -U postgres"
else
    echo -e "$KO Des problèmes persistent"
fi

echo "═══════════════════════════════════════════════════════════════════"
