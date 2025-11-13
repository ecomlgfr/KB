#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         CHECK_PATRONI_RAFT - Vérification du cluster RAFT          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "Mots de passe actuels:"
echo "  PostgreSQL: $POSTGRES_PASSWORD"
echo "  API Patroni: $PATRONI_API_PASSWORD"
echo ""

echo "1. État des containers..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo "  Nœud $ip:"
    ssh root@"$ip" bash <<'CHECK'
    # État du container
    if docker ps | grep -q patroni; then
        echo "    Container: Running"
        # Ports en écoute
        echo -n "    Ports: "
        ss -tlnp 2>/dev/null | grep -E "(5432|7000|8008)" | awk '{print $4}' | cut -d: -f2 | sort -u | tr '\n' ' '
        echo ""
    else
        echo "    Container: Stopped"
        echo "    Dernière erreur:"
        docker logs patroni 2>&1 | tail -3 | sed 's/^/      /'
    fi
CHECK
done

echo ""
echo "2. Test de l'API Patroni..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  API $ip: "
    
    # Test sans auth d'abord
    if curl -s "http://$ip:8008/" 2>/dev/null | grep -q "401"; then
        # L'API répond, essayer avec auth
        if curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$ip:8008/patroni" 2>/dev/null | grep -q "state"; then
            echo -e "$OK Authentifié"
            # Afficher le rôle
            role=$(curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null)
            echo "      Rôle: $role"
        else
            echo -e "$KO Auth échouée"
        fi
    else
        echo -e "$KO Pas de réponse"
    fi
done

echo ""
echo "3. Test PostgreSQL direct..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  PostgreSQL $ip: "
    
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -c "SELECT version()" -t 2>/dev/null | grep -q "PostgreSQL"; then
        echo -e "$OK"
        # Vérifier si c'est master ou replica
        is_recovery=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | xargs)
        if [ "$is_recovery" = "f" ]; then
            echo "      Type: Master (lecture/écriture)"
        else
            echo "      Type: Replica (lecture seule)"
        fi
    else
        echo -e "$KO"
    fi
done

echo ""
echo "4. État du cluster via l'API..."
echo ""

# Chercher un nœud avec API fonctionnelle
API_NODE=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    if curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$ip:8008/cluster" 2>/dev/null | grep -q "members"; then
        API_NODE="$ip"
        break
    fi
done

if [ -n "$API_NODE" ]; then
    echo "  Cluster via $API_NODE:"
    curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$API_NODE:8008/cluster" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(f\"    Scope: {data.get('scope', 'N/A')}\")
    print(f\"    Members: {len(data.get('members', []))}\")
    for member in data.get('members', []):
        state = '✓' if member.get('state') == 'running' else '✗'
        role = member.get('role', 'unknown')
        lag = member.get('lag', 'N/A')
        print(f\"      - {member.get('name')}: {role} {state} (lag: {lag})\")
except:
    print('    Erreur parsing JSON')
" 2>/dev/null
else
    echo "  API non accessible, vérification via psql..."
    
    # Trouver le master via psql
    MASTER=""
    for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
        is_master=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -c "SELECT NOT pg_is_in_recovery()" -t 2>/dev/null | xargs)
        if [ "$is_master" = "t" ]; then
            MASTER="$ip"
            echo "  Master trouvé: $ip"
            break
        fi
    done
fi

echo ""
echo "5. Test de réplication..."
echo ""

if [ -n "${MASTER:-}" ]; then
    echo "  Création table test sur master ($MASTER)..."
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$MASTER" -p 5432 -U postgres <<SQL 2>/dev/null
CREATE TABLE IF NOT EXISTS replication_test (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO replication_test (data) VALUES ('Test RAFT $(date +%s)');
SQL
    
    echo "  Vérification sur les replicas..."
    sleep 2
    
    for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
        [ "$ip" = "$MASTER" ] && continue
        
        echo -n "    Replica $ip: "
        count=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -c "SELECT COUNT(*) FROM replication_test" -t 2>/dev/null | xargs)
        if [ -n "$count" ] && [ "$count" -gt 0 ]; then
            echo -e "$OK ($count lignes)"
        else
            echo -e "$KO"
        fi
    done
fi

echo ""
echo "6. Vérification RAFT..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo "  RAFT $ip:"
    ssh root@"$ip" bash <<'CHECK_RAFT'
    # Vérifier les fichiers RAFT
    if [ -d /opt/keybuzz/postgres/raft ]; then
        echo -n "    Fichiers RAFT: "
        ls -la /opt/keybuzz/postgres/raft 2>/dev/null | wc -l
        
        # Port RAFT
        echo -n "    Port 7000: "
        if ss -tlnp 2>/dev/null | grep -q ":7000"; then
            echo "En écoute"
        else
            echo "Fermé"
        fi
    else
        echo "    Répertoire RAFT manquant"
    fi
CHECK_RAFT
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ"
echo "═══════════════════════════════════════════════════════════════════"

# Compter les services OK
PG_OK=0
API_OK=0
RAFT_OK=0

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -p 5432 -U postgres -c "SELECT 1" &>/dev/null && ((PG_OK++))
    curl -s -u patroni:"$PATRONI_API_PASSWORD" "http://$ip:8008/patroni" 2>/dev/null | grep -q state && ((API_OK++))
    ssh root@"$ip" "ss -tlnp 2>/dev/null | grep -q :7000" && ((RAFT_OK++))
done

echo "  PostgreSQL: $PG_OK/3 nœuds accessibles"
echo "  API Patroni: $API_OK/3 nœuds accessibles"
echo "  RAFT: $RAFT_OK/3 ports ouverts"

if [ $PG_OK -ge 2 ] && [ $API_OK -ge 1 ]; then
    echo ""
    echo -e "$OK Le cluster est opérationnel (mode dégradé acceptable)"
    echo ""
    echo "Connexion:"
    echo "  export PGPASSWORD='$POSTGRES_PASSWORD'"
    echo "  psql -h 10.0.0.120 -p 5432 -U postgres"
else
    echo ""
    echo -e "$KO Le cluster nécessite attention"
    echo ""
    echo "Debug:"
    echo "  ssh root@10.0.0.120 'docker logs patroni | tail -20'"
fi

echo "═══════════════════════════════════════════════════════════════════"
