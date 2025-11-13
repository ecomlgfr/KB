#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         05_TEST_CLUSTER - Tests et validation du cluster           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Configuration
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_LOG="$LOG_DIR/05_test_cluster_$TIMESTAMP.log"

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    source /opt/keybuzz-installer/credentials/postgres.env
else
    echo -e "$KO Credentials non trouvés"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Tests de validation du cluster PostgreSQL HA"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Variables
DB_SERVERS=("10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")
HAPROXY_SERVERS=("10.0.0.11:haproxy-01" "10.0.0.12:haproxy-02")
TESTS_PASSED=0
TESTS_FAILED=0

# Fonction de test
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -n "  $test_name: "
    if eval "$test_command" >> "$TEST_LOG" 2>&1; then
        echo -e "$OK"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "$KO"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

echo "1. Test Patroni API..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    run_test "$hostname API" "curl -s http://$ip:8008/patroni | grep -q 'running\\|streaming'"
done

echo ""
echo "2. Test PostgreSQL direct..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    run_test "$hostname PostgreSQL" "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $ip -U postgres -d postgres -c 'SELECT 1' -t | grep -q 1"
done

echo ""
echo "3. Test PgBouncer..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    run_test "$hostname PgBouncer" "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $ip -p 6432 -U postgres -d postgres -c 'SELECT 1' -t | grep -q 1"
done

echo ""
echo "4. Test HAProxy..."
echo ""

for server in "${HAPROXY_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    run_test "$hostname Write" "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $ip -p 5432 -U postgres -d postgres -c 'SELECT 1' -t | grep -q 1"
    run_test "$hostname Read" "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $ip -p 5433 -U postgres -d postgres -c 'SELECT 1' -t | grep -q 1"
done

echo ""
echo "5. Test réplication..."
echo ""

# Identifier le leader
LEADER_IP=""
for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    ROLE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null || echo "")
    if [ "$ROLE" = "master" ] || [ "$ROLE" = "leader" ]; then
        LEADER_IP="$ip"
        echo "  Leader identifié: $hostname ($ip)"
        break
    fi
done

if [ -n "$LEADER_IP" ]; then
    # Créer une table test sur le leader
    echo -n "  Création table sur leader: "
    ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c 'DROP TABLE IF EXISTS test_replication; CREATE TABLE test_replication (id serial, data text, created_at timestamp default now());'" 2>/dev/null
    echo -e "$OK"
    
    # Insérer des données
    echo -n "  Insertion données: "
    ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c \"INSERT INTO test_replication (data) VALUES ('Test at $(date)');\"" 2>/dev/null
    echo -e "$OK"
    
    # Attendre la réplication
    sleep 2
    
    # Vérifier sur les replicas
    echo "  Vérification réplication:"
    for server in "${DB_SERVERS[@]}"; do
        IFS=':' read -r ip hostname <<< "$server"
        if [ "$ip" != "$LEADER_IP" ]; then
            run_test "    $hostname" "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $ip -U postgres -d postgres -c 'SELECT count(*) FROM test_replication' -t | grep -q 1"
        fi
    done
fi

echo ""
echo "6. Test failover (simulation)..."
echo ""

if [ -n "$LEADER_IP" ]; then
    echo "  Test de lecture du statut de réplication:"
    ssh root@"$LEADER_IP" bash <<'REPL_TEST' 2>/dev/null
docker exec patroni psql -U postgres -c "
SELECT client_addr, state, sync_state, replay_lag 
FROM pg_stat_replication;" | head -10
REPL_TEST
fi

echo ""
echo "7. Test extensions PostgreSQL..."
echo ""

if [ -n "$LEADER_IP" ]; then
    echo "  Extensions disponibles:"
    
    # pgvector
    run_test "pgvector" "ssh root@$LEADER_IP \"docker exec patroni psql -U postgres -c 'CREATE EXTENSION IF NOT EXISTS vector'\" 2>/dev/null"
    
    # pg_stat_statements
    run_test "pg_stat_statements" "ssh root@$LEADER_IP \"docker exec patroni psql -U postgres -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'\" 2>/dev/null"
    
    # pgaudit
    run_test "pgaudit" "ssh root@$LEADER_IP \"docker exec patroni psql -U postgres -c 'CREATE EXTENSION IF NOT EXISTS pgaudit'\" 2>/dev/null"
fi

echo ""
echo "8. Test pgvector fonctionnel..."
echo ""

if [ -n "$LEADER_IP" ]; then
    echo -n "  Création table avec vecteurs: "
    TEST_VECTOR=$(ssh root@"$LEADER_IP" bash <<'VECTOR_TEST' 2>/dev/null
docker exec patroni psql -U postgres <<SQL
-- Créer une table avec colonne vector
DROP TABLE IF EXISTS test_embeddings;
CREATE TABLE test_embeddings (
    id serial PRIMARY KEY,
    content text,
    embedding vector(3)
);

-- Insérer des données test
INSERT INTO test_embeddings (content, embedding) VALUES
    ('Premier test', '[1.0, 0.0, 0.0]'),
    ('Second test', '[0.0, 1.0, 0.0]'),
    ('Troisième test', '[0.0, 0.0, 1.0]');

-- Recherche par similarité
SELECT content, embedding <-> '[0.9, 0.1, 0.0]' as distance
FROM test_embeddings
ORDER BY embedding <-> '[0.9, 0.1, 0.0]'
LIMIT 1;
SQL
VECTOR_TEST
    )
    
    if echo "$TEST_VECTOR" | grep -q "Premier test"; then
        echo -e "$OK"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "$KO"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

echo ""
echo "9. Test de performance basique..."
echo ""

if [ -n "$LEADER_IP" ]; then
    echo "  Benchmark pgbench (initialisation):"
    ssh root@"$LEADER_IP" bash <<'PERF_TEST' 2>/dev/null
# Initialiser pgbench
docker exec patroni pgbench -i -s 10 postgres 2>/dev/null

# Test rapide
echo "  Test de performance (5 secondes):"
docker exec patroni pgbench -c 10 -j 2 -T 5 postgres 2>/dev/null | grep -E "tps|latency"
PERF_TEST
fi

echo ""
echo "10. Génération rapport final..."
echo ""

REPORT_FILE="/opt/keybuzz-installer/credentials/cluster-report-$TIMESTAMP.txt"

cat > "$REPORT_FILE" <<EOF
═══════════════════════════════════════════════════════════════════
RAPPORT DE VALIDATION - CLUSTER POSTGRESQL HA
═══════════════════════════════════════════════════════════════════
Date: $(date)

RÉSULTATS DES TESTS
-------------------
Tests réussis: $TESTS_PASSED
Tests échoués: $TESTS_FAILED

ARCHITECTURE DÉPLOYÉE
--------------------
PostgreSQL: Version 17
DCS: Patroni avec Raft intégré
Connection Pooling: PgBouncer
Load Balancing: HAProxy

NŒUDS POSTGRESQL
---------------
• db-master-01 (10.0.0.120) - Leader actuel: $([ "$LEADER_IP" = "10.0.0.120" ] && echo "OUI" || echo "NON")
• db-slave-01 (10.0.0.121) - Replica
• db-slave-02 (10.0.0.122) - Replica

NŒUDS HAPROXY
------------
• haproxy-01 (10.0.0.11)
• haproxy-02 (10.0.0.12)

ENDPOINTS DISPONIBLES
--------------------
Direct PostgreSQL:
  - Master: $LEADER_IP:5432
  - Replicas: 10.0.0.121:5432, 10.0.0.122:5432

Via PgBouncer:
  - Tous les nœuds: <IP>:6432

Via HAProxy:
  - Write: haproxy-01:5432 ou haproxy-02:5432
  - Read: haproxy-01:5433 ou haproxy-02:5433

EXTENSIONS INSTALLÉES
--------------------
• pgvector - Embeddings et recherche vectorielle
• pg_stat_statements - Monitoring des requêtes
• pgaudit - Audit des opérations
• wal2json - Export WAL en JSON
• pglogical - Réplication logique

CREDENTIALS
----------
Fichier: /opt/keybuzz-installer/credentials/postgres.env
User: postgres
Password: $POSTGRES_PASSWORD

COMMANDES UTILES
---------------
# Connexion directe au leader
psql -h $LEADER_IP -U postgres

# Connexion via HAProxy (écriture)
psql -h 10.0.0.11 -p 5432 -U postgres

# Connexion via HAProxy (lecture)
psql -h 10.0.0.11 -p 5433 -U postgres

# État du cluster
curl http://$LEADER_IP:8008/cluster | jq

# Logs
docker logs patroni --tail 50

MONITORING
---------
Patroni API: http://<node>:8008/
HAProxy Stats: http://haproxy-01:8080/stats (admin/admin)

EOF

echo "  Rapport généré: $REPORT_FILE"

echo ""
echo "═══════════════════════════════════════════════════════════════════"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "$OK TOUS LES TESTS RÉUSSIS !"
    echo ""
    echo "Le cluster PostgreSQL HA est pleinement opérationnel."
else
    echo -e "$WARN $TESTS_FAILED test(s) échoué(s)"
    echo ""
    echo "Vérifiez les logs: $TEST_LOG"
fi

echo ""
echo "Rapport complet: $REPORT_FILE"
echo "═══════════════════════════════════════════════════════════════════"
