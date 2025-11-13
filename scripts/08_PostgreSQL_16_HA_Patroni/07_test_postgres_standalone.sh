#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        07_TEST_POSTGRES_STANDALONE - Vérification                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    source /opt/keybuzz-installer/credentials/postgres.env
else
    echo -e "$KO Credentials postgres.env introuvables"
    exit 1
fi

echo ""
echo "═══ Test PostgreSQL Standalone ═══"
echo ""

SUCCESS=0
FAILED=0

for node in "${DB_NODES[@]}"; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP" ] && { echo -e "$node: $KO IP introuvable"; ((FAILED++)); continue; }
    
    echo "→ $node ($IP)"
    
    # Test 1: Container running
    echo -n "  Container: "
    if ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps | grep -q postgres" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
        ((FAILED++))
        continue
    fi
    
    # Test 2: PostgreSQL ready
    echo -n "  PG Ready: "
    if ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker exec postgres pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
        echo -e "$OK"
    else
        echo -e "$KO"
        ((FAILED++))
        continue
    fi
    
    # Test 3: Version
    echo -n "  Version: "
    VERSION=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker exec postgres psql -U postgres -t -c 'SELECT version()'" 2>/dev/null | grep -oP 'PostgreSQL \K[0-9]+')
    if [ "$VERSION" = "$POSTGRES_VERSION" ]; then
        echo -e "$OK PostgreSQL $VERSION"
    else
        echo -e "$KO Version mismatch"
        ((FAILED++))
        continue
    fi
    
    # Test 4: Users
    echo -n "  Users: "
    USERS=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker exec postgres psql -U postgres -t -c \"SELECT string_agg(usename, ', ') FROM pg_user WHERE usename IN ('postgres', 'replicator', 'patroni')\"" 2>/dev/null | xargs)
    if [[ "$USERS" == *"postgres"* ]] && [[ "$USERS" == *"replicator"* ]] && [[ "$USERS" == *"patroni"* ]]; then
        echo -e "$OK ($USERS)"
    else
        echo -e "$KO Users manquants"
        ((FAILED++))
    fi
    
    # Test 5: Database keybuzz
    echo -n "  DB keybuzz: "
    if ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker exec postgres psql -U postgres -lqt" 2>/dev/null | grep -q "keybuzz"; then
        echo -e "$OK"
    else
        echo -e "$KO"
        ((FAILED++))
    fi
    
    # Test 6: Configuration
    echo -n "  Config: "
    MAX_CONN=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker exec postgres psql -U postgres -t -c 'SHOW max_connections'" 2>/dev/null | xargs)
    WAL_LEVEL=$(ssh -o StrictHostKeyChecking=no root@"$IP" \
        "docker exec postgres psql -U postgres -t -c 'SHOW wal_level'" 2>/dev/null | xargs)
    if [ "$MAX_CONN" = "200" ] && [ "$WAL_LEVEL" = "replica" ]; then
        echo -e "$OK (max_conn=$MAX_CONN, wal=$WAL_LEVEL)"
    else
        echo -e "$KO Config non appliquée"
        ((FAILED++))
    fi
    
    # Test 7: Connexion réseau
    echo -n "  Network: "
    if timeout 2 nc -zv "$IP" 5432 2>/dev/null; then
        echo -e "$OK Port 5432 accessible"
    else
        echo -e "$KO Port 5432 inaccessible"
        ((FAILED++))
    fi
    
    ((SUCCESS++))
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "Résultat: $SUCCESS/${#DB_NODES[@]} nœuds PostgreSQL OK"
echo ""

# Tests croisés si tous les nœuds sont OK
if [ $SUCCESS -eq ${#DB_NODES[@]} ]; then
    echo "Tests de connectivité croisée:"
    echo ""
    
    for source in "${DB_NODES[@]}"; do
        SOURCE_IP=$(awk -F'\t' -v h="$source" '$2==h {print $3}' "$SERVERS_TSV")
        echo "  Depuis $source:"
        
        for target in "${DB_NODES[@]}"; do
            [ "$source" = "$target" ] && continue
            TARGET_IP=$(awk -F'\t' -v h="$target" '$2==h {print $3}' "$SERVERS_TSV")
            
            echo -n "    → $target ($TARGET_IP:5432): "
            if ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $TARGET_IP -U postgres -d keybuzz -c 'SELECT 1' &>/dev/null" 2>/dev/null; then
                echo -e "$OK"
            else
                echo -e "$KO"
            fi
        done
    done
    
    echo ""
    echo -e "$OK PostgreSQL standalone opérationnel"
    echo ""
    echo "Prochaine étape: ./08_postgres_to_patroni.sh"
    exit 0
else
    echo -e "$KO PostgreSQL standalone non opérationnel"
    echo ""
    echo "Debug:"
    for node in "${DB_NODES[@]}"; do
        IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
        echo "  ssh root@$IP 'docker logs postgres --tail 20'"
    done
    exit 1
fi
