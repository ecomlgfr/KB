#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      08_TEST_INFRASTRUCTURE - Tests complets infrastructure DB     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_FILE="/opt/keybuzz-installer/logs/test_infrastructure_$(date +%Y%m%d_%H%M%S).log"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
[ ! -f "$CREDS_DIR/postgres.env" ] && { echo -e "$KO postgres.env introuvable"; exit 1; }

source "$CREDS_DIR/postgres.env"

mkdir -p "$(dirname "$LOG_FILE")"

declare -i TOTAL_TESTS=0
declare -i PASSED_TESTS=0
declare -i FAILED_TESTS=0

test_result() {
    local test_name="$1"
    local result="$2"
    
    ((TOTAL_TESTS++))
    
    if [ "$result" = "0" ]; then
        echo -e "  $OK $test_name" | tee -a "$LOG_FILE"
        ((PASSED_TESTS++))
    else
        echo -e "  $KO $test_name" | tee -a "$LOG_FILE"
        ((FAILED_TESTS++))
    fi
}

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "          TESTS DE L'INFRASTRUCTURE POSTGRESQL HA" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ===== 1. TESTS PATRONI CLUSTER =====
echo "1. TESTS PATRONI CLUSTER" | tee -a "$LOG_FILE"
echo "─────────────────────────" | tee -a "$LOG_FILE"

declare -A DB_IPS=(
    [db-master-01]="10.0.0.120"
    [db-slave-01]="10.0.0.121"
    [db-slave-02]="10.0.0.122"
)

LEADER_IP=""
LEADER_NAME=""

for node_name in db-master-01 db-slave-01 db-slave-02; do
    node_ip="${DB_IPS[$node_name]}"
    
    # Test conteneur actif
    if ssh -o StrictHostKeyChecking=no root@"$node_ip" "docker ps | grep -q patroni" 2>/dev/null; then
        test_result "Conteneur Patroni actif sur $node_name" 0
        
        # Test PostgreSQL prêt
        if ssh -o StrictHostKeyChecking=no root@"$node_ip" \
            "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
            test_result "PostgreSQL prêt sur $node_name" 0
            
            # Identifier le rôle
            IS_LEADER=$(ssh -o StrictHostKeyChecking=no root@"$node_ip" \
                "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
            
            if [ "$IS_LEADER" = "f" ]; then
                LEADER_IP="$node_ip"
                LEADER_NAME="$node_name"
                test_result "$node_name est le LEADER" 0
            else
                test_result "$node_name est une REPLICA" 0
            fi
        else
            test_result "PostgreSQL prêt sur $node_name" 1
        fi
    else
        test_result "Conteneur Patroni actif sur $node_name" 1
    fi
done

if [ -n "$LEADER_IP" ]; then
    echo "" | tee -a "$LOG_FILE"
    echo "  → Leader actuel: $LEADER_NAME ($LEADER_IP)" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# ===== 2. TESTS PATRONI API =====
echo "2. TESTS PATRONI API" | tee -a "$LOG_FILE"
echo "────────────────────" | tee -a "$LOG_FILE"

for node_name in db-master-01 db-slave-01 db-slave-02; do
    node_ip="${DB_IPS[$node_name]}"
    
    if curl -s -u "patroni:$PATRONI_API_PASSWORD" "http://$node_ip:8008/health" 2>/dev/null | grep -q "200"; then
        test_result "API Patroni accessible sur $node_name" 0
    else
        test_result "API Patroni accessible sur $node_name" 1
    fi
done

echo "" | tee -a "$LOG_FILE"

# ===== 3. TESTS POSTGRESQL =====
echo "3. TESTS POSTGRESQL" | tee -a "$LOG_FILE"
echo "───────────────────" | tee -a "$LOG_FILE"

if [ -n "$LEADER_IP" ]; then
    # Test version PostgreSQL
    VERSION=$(ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
        "docker exec patroni psql -U postgres -t -c 'SELECT version()' 2>/dev/null" | grep -oP 'PostgreSQL \K[0-9]+')
    
    if [ "$VERSION" = "16" ]; then
        test_result "Version PostgreSQL 16" 0
    else
        test_result "Version PostgreSQL 16 (trouvé: $VERSION)" 1
    fi
    
    # Test extensions
    EXTENSIONS=$(ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
        "docker exec patroni psql -U postgres -d keybuzz -t -c \"SELECT string_agg(extname, ', ') FROM pg_extension WHERE extname IN ('uuid-ossp', 'vector')\" 2>/dev/null" | xargs)
    
    if [[ "$EXTENSIONS" == *"uuid-ossp"* ]] && [[ "$EXTENSIONS" == *"vector"* ]]; then
        test_result "Extensions (uuid-ossp, vector) installées" 0
    else
        test_result "Extensions (uuid-ossp, vector) installées" 1
    fi
    
    # Test bases de données
    for db in keybuzz n8n chatwoot; do
        if ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
            "docker exec patroni psql -U postgres -lqt 2>/dev/null | grep -q '$db'"; then
            test_result "Base de données '$db' existe" 0
        else
            test_result "Base de données '$db' existe" 1
        fi
    done
    
    # Test utilisateurs
    for user in n8n chatwoot pgbouncer; do
        if ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
            "docker exec patroni psql -U postgres -t -c \"SELECT 1 FROM pg_user WHERE usename='$user'\" 2>/dev/null | grep -q '1'"; then
            test_result "Utilisateur '$user' existe" 0
        else
            test_result "Utilisateur '$user' existe" 1
        fi
    done
fi

echo "" | tee -a "$LOG_FILE"

# ===== 4. TESTS HAPROXY =====
echo "4. TESTS HAPROXY" | tee -a "$LOG_FILE"
echo "────────────────" | tee -a "$LOG_FILE"

for proxy in haproxy-01:10.0.0.11 haproxy-02:10.0.0.12; do
    IFS=':' read -r proxy_name proxy_ip <<< "$proxy"
    
    # Test conteneur actif
    if ssh -o StrictHostKeyChecking=no root@"$proxy_ip" "docker ps | grep -q haproxy" 2>/dev/null; then
        test_result "Conteneur HAProxy actif sur $proxy_name" 0
    else
        test_result "Conteneur HAProxy actif sur $proxy_name" 1
    fi
    
    # Test port 5432 (écriture)
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$proxy_ip" -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        test_result "HAProxy port 5432 (écriture) sur $proxy_name" 0
    else
        test_result "HAProxy port 5432 (écriture) sur $proxy_name" 1
    fi
    
    # Test port 5433 (lecture)
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$proxy_ip" -p 5433 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        test_result "HAProxy port 5433 (lecture) sur $proxy_name" 0
    else
        test_result "HAProxy port 5433 (lecture) sur $proxy_name" 1
    fi
    
    # Test stats page
    if curl -s -u "admin:$PATRONI_API_PASSWORD" "http://$proxy_ip:8404/stats" | grep -q "HAProxy"; then
        test_result "Stats page HAProxy accessible sur $proxy_name" 0
    else
        test_result "Stats page HAProxy accessible sur $proxy_name" 1
    fi
done

echo "" | tee -a "$LOG_FILE"

# ===== 5. TESTS PGBOUNCER =====
echo "5. TESTS PGBOUNCER" | tee -a "$LOG_FILE"
echo "──────────────────" | tee -a "$LOG_FILE"

for proxy in haproxy-01:10.0.0.11 haproxy-02:10.0.0.12; do
    IFS=':' read -r proxy_name proxy_ip <<< "$proxy"
    
    # Test conteneur actif
    if ssh -o StrictHostKeyChecking=no root@"$proxy_ip" "docker ps | grep -q pgbouncer" 2>/dev/null; then
        test_result "Conteneur PgBouncer actif sur $proxy_name" 0
        
        # Test connexion avec différents users
        if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$proxy_ip" -p 6432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
            test_result "PgBouncer connexion user 'postgres' sur $proxy_name" 0
        else
            test_result "PgBouncer connexion user 'postgres' sur $proxy_name" 1
        fi
        
        if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$proxy_ip" -p 6432 -U n8n -d n8n -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
            test_result "PgBouncer connexion user 'n8n' sur $proxy_name" 0
        else
            test_result "PgBouncer connexion user 'n8n' sur $proxy_name" 1
        fi
        
        if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$proxy_ip" -p 6432 -U chatwoot -d chatwoot -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
            test_result "PgBouncer connexion user 'chatwoot' sur $proxy_name" 0
        else
            test_result "PgBouncer connexion user 'chatwoot' sur $proxy_name" 1
        fi
    else
        test_result "Conteneur PgBouncer actif sur $proxy_name" 1
    fi
done

echo "" | tee -a "$LOG_FILE"

# ===== 6. TESTS KEEPALIVED =====
echo "6. TESTS KEEPALIVED" | tee -a "$LOG_FILE"
echo "───────────────────" | tee -a "$LOG_FILE"

for proxy in haproxy-01:10.0.0.11 haproxy-02:10.0.0.12; do
    IFS=':' read -r proxy_name proxy_ip <<< "$proxy"
    
    if ssh -o StrictHostKeyChecking=no root@"$proxy_ip" "systemctl is-active --quiet keepalived" 2>/dev/null; then
        test_result "Service Keepalived actif sur $proxy_name" 0
        
        # Lire l'état
        STATE=$(ssh -o StrictHostKeyChecking=no root@"$proxy_ip" "cat /var/run/keepalived-state 2>/dev/null || echo 'UNKNOWN'")
        echo "    → État: $STATE" | tee -a "$LOG_FILE"
    else
        test_result "Service Keepalived actif sur $proxy_name" 1
    fi
done

echo "" | tee -a "$LOG_FILE"

# ===== 7. TESTS VIP =====
echo "7. TESTS VIP (10.0.0.10)" | tee -a "$LOG_FILE"
echo "────────────────────────" | tee -a "$LOG_FILE"

# Test connexion directe via VIP
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
    test_result "Connexion PostgreSQL via VIP (10.0.0.10:5432)" 0
else
    test_result "Connexion PostgreSQL via VIP (10.0.0.10:5432)" 1
fi

echo "" | tee -a "$LOG_FILE"

# ===== 8. TESTS DE RÉPLICATION =====
echo "8. TESTS DE RÉPLICATION" | tee -a "$LOG_FILE"
echo "───────────────────────" | tee -a "$LOG_FILE"

if [ -n "$LEADER_IP" ]; then
    # Créer une table de test
    ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
        "docker exec patroni psql -U postgres -d keybuzz -c 'CREATE TABLE IF NOT EXISTS test_replication (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT NOW())' 2>/dev/null" >/dev/null
    
    # Insérer une donnée
    TEST_DATA="test_$(date +%s)"
    ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
        "docker exec patroni psql -U postgres -d keybuzz -c \"INSERT INTO test_replication (data) VALUES ('$TEST_DATA')\" 2>/dev/null" >/dev/null
    
    sleep 2
    
    # Vérifier sur les replicas
    for node_name in db-master-01 db-slave-01 db-slave-02; do
        node_ip="${DB_IPS[$node_name]}"
        
        if [ "$node_ip" = "$LEADER_IP" ]; then
            continue
        fi
        
        if ssh -o StrictHostKeyChecking=no root@"$node_ip" \
            "docker exec patroni psql -U postgres -d keybuzz -t -c \"SELECT data FROM test_replication WHERE data='$TEST_DATA'\" 2>/dev/null | grep -q '$TEST_DATA'"; then
            test_result "Réplication vers $node_name" 0
        else
            test_result "Réplication vers $node_name" 1
        fi
    done
    
    # Nettoyer
    ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
        "docker exec patroni psql -U postgres -d keybuzz -c 'DROP TABLE IF EXISTS test_replication' 2>/dev/null" >/dev/null
fi

echo "" | tee -a "$LOG_FILE"

# ===== 9. TESTS DE PERFORMANCE BASIQUE =====
echo "9. TESTS DE PERFORMANCE BASIQUE" | tee -a "$LOG_FILE"
echo "────────────────────────────────" | tee -a "$LOG_FILE"

if [ -n "$LEADER_IP" ]; then
    # Test latence
    START=$(date +%s%N)
    ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
        "docker exec patroni psql -U postgres -d postgres -c 'SELECT 1' 2>/dev/null" >/dev/null
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000000 ))
    
    if [ $LATENCY -lt 100 ]; then
        test_result "Latence acceptable (${LATENCY}ms < 100ms)" 0
    else
        test_result "Latence acceptable (${LATENCY}ms)" 1
    fi
fi

echo "" | tee -a "$LOG_FILE"

# ===== RÉSUMÉ =====
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "                        RÉSUMÉ DES TESTS" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

PASS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))

echo "Tests exécutés  : $TOTAL_TESTS" | tee -a "$LOG_FILE"
echo -e "Tests réussis   : $OK $PASSED_TESTS" | tee -a "$LOG_FILE"
echo -e "Tests échoués   : $KO $FAILED_TESTS" | tee -a "$LOG_FILE"
echo "Taux de réussite: ${PASS_RATE}%" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ $PASS_RATE -ge 95 ]; then
    echo -e "$OK INFRASTRUCTURE FULLY OPERATIONAL" | tee -a "$LOG_FILE"
    STATUS="OK"
elif [ $PASS_RATE -ge 80 ]; then
    echo -e "$WARN INFRASTRUCTURE MOSTLY OPERATIONAL" | tee -a "$LOG_FILE"
    STATUS="WARNING"
else
    echo -e "$KO INFRASTRUCTURE HAS ISSUES" | tee -a "$LOG_FILE"
    STATUS="KO"
fi

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ "$STATUS" = "OK" ] || [ "$STATUS" = "WARNING" ]; then
    echo "📊 ARCHITECTURE FINALE:" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "┌─────────────────────────────────────────────────────────────┐" | tee -a "$LOG_FILE"
    echo "│  VIP: 10.0.0.10 (Load Balancer Hetzner)                    │" | tee -a "$LOG_FILE"
    echo "│  ↓                                                          │" | tee -a "$LOG_FILE"
    echo "│  Keepalived (VRRP Failover)                                │" | tee -a "$LOG_FILE"
    echo "│  ├─ haproxy-01 (10.0.0.11) [MASTER]                        │" | tee -a "$LOG_FILE"
    echo "│  └─ haproxy-02 (10.0.0.12) [BACKUP]                        │" | tee -a "$LOG_FILE"
    echo "│                                                             │" | tee -a "$LOG_FILE"
    echo "│  HAProxy (détection automatique leader/replicas)           │" | tee -a "$LOG_FILE"
    echo "│  ├─ Port 5432 → Leader (écriture)                          │" | tee -a "$LOG_FILE"
    echo "│  └─ Port 5433 → Replicas (lecture, round-robin)            │" | tee -a "$LOG_FILE"
    echo "│                                                             │" | tee -a "$LOG_FILE"
    echo "│  PgBouncer (pooling de connexions)                         │" | tee -a "$LOG_FILE"
    echo "│  └─ Port 6432 → HAProxy (SCRAM-SHA-256)                    │" | tee -a "$LOG_FILE"
    echo "│                                                             │" | tee -a "$LOG_FILE"
    echo "│  Patroni RAFT Cluster (PostgreSQL 16 + pgvector)           │" | tee -a "$LOG_FILE"
    echo "│  ├─ db-master-01 (10.0.0.120) [${LEADER_NAME:+LEADER}]     │" | tee -a "$LOG_FILE"
    echo "│  ├─ db-slave-01  (10.0.0.121) [REPLICA]                    │" | tee -a "$LOG_FILE"
    echo "│  └─ db-slave-02  (10.0.0.122) [REPLICA]                    │" | tee -a "$LOG_FILE"
    echo "└─────────────────────────────────────────────────────────────┘" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "📝 POINTS D'ACCÈS:" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Applications (recommandé - avec pooling):" | tee -a "$LOG_FILE"
    echo "  postgresql://user:pass@10.0.0.10:6432/database" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Admin direct (sans pooling):" | tee -a "$LOG_FILE"
    echo "  postgresql://postgres:pass@10.0.0.10:5432/database" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Lecture seule (load balanced):" | tee -a "$LOG_FILE"
    echo "  postgresql://user:pass@10.0.0.11:5433/database" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
fi

# Sauvegarder le résumé
cat > /opt/keybuzz-installer/credentials/data-layer-summary.txt <<SUMMARY
═══════════════════════════════════════════════════════════════════
              KEYBUZZ DATA LAYER - RÉSUMÉ FINAL
═══════════════════════════════════════════════════════════════════

Tests: $PASSED_TESTS/$TOTAL_TESTS réussis (${PASS_RATE}%)
Status: $STATUS
Date: $(date '+%Y-%m-%d %H:%M:%S')

CREDENTIALS:
──────────────
PostgreSQL:    $POSTGRES_PASSWORD
Replicator:    $REPLICATOR_PASSWORD
Patroni API:   $PATRONI_API_PASSWORD

URLS DE CONNEXION:
─────────────────
Keybuzz:  postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:6432/keybuzz
n8n:      postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.10:6432/n8n
Chatwoot: postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.10:6432/chatwoot

MONITORING:
──────────
HAProxy Stats:  http://10.0.0.11:8404/stats (admin/$PATRONI_API_PASSWORD)
Patroni API:    http://${LEADER_IP:-10.0.0.120}:8008/cluster

═══════════════════════════════════════════════════════════════════
SUMMARY

echo "Résumé sauvegardé: /opt/keybuzz-installer/credentials/data-layer-summary.txt" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

tail -n 100 "$LOG_FILE"

[ "$STATUS" = "OK" ] && exit 0 || exit 1
