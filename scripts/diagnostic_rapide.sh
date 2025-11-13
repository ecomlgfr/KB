#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         DIAGNOSTIC RAPIDE INFRASTRUCTURE KEYBUZZ                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CRED_FILE="/opt/keybuzz-installer/credentials/postgres.env"

# Charger credentials
if [ -f "$CRED_FILE" ]; then
    source "$CRED_FILE"
else
    echo -e "$KO Fichier credentials manquant"
    exit 1
fi

# IPs
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2_IP=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

SUCCESS=0
TOTAL=0

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "              DIAGNOSTIC AU $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ============================================================================
# SECTION 1: CONTENEURS DOCKER
# ============================================================================

echo "▓▓▓ 1. CONTENEURS DOCKER ▓▓▓"
echo ""

declare -A EXPECTED_CONTAINERS=(
    ["db-master-01"]="patroni"
    ["db-slave-01"]="patroni"
    ["db-slave-02"]="patroni"
    ["haproxy-01"]="haproxy pgbouncer"
    ["haproxy-02"]="haproxy pgbouncer"
)

for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP" "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    echo "→ $NAME ($IP)"
    
    for CONTAINER in ${EXPECTED_CONTAINERS[$NAME]}; do
        ((TOTAL++))
        echo -n "    $CONTAINER: "
        
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" "docker ps | grep -q $CONTAINER" 2>/dev/null; then
            # Vérifier si en restart loop
            STATE=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps --format '{{.Status}}' --filter name=$CONTAINER" 2>/dev/null)
            if echo "$STATE" | grep -qi "restarting"; then
                echo -e "$WARN (Restarting)"
            else
                echo -e "$OK Up"
                ((SUCCESS++))
            fi
        else
            echo -e "$KO Stopped ou absent"
        fi
    done
    echo ""
done

# ============================================================================
# SECTION 2: CLUSTER PATRONI
# ============================================================================

echo "▓▓▓ 2. CLUSTER PATRONI ▓▓▓"
echo ""

LEADER_COUNT=0
REPLICA_COUNT=0

for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    ((TOTAL++))
    echo -n "  $NAME ($IP): "
    
    # Test API Patroni
    ROLE=$(curl -s -m 5 "http://${IP}:8008/" 2>/dev/null | grep -o '"role":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    STATE=$(curl -s -m 5 "http://${IP}:8008/" 2>/dev/null | grep -o '"state":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    
    if [ "$STATE" = "running" ]; then
        if [ "$ROLE" = "leader" ] || [ "$ROLE" = "primary" ]; then
            echo -e "$OK Leader"
            ((LEADER_COUNT++))
            ((SUCCESS++))
        elif [ "$ROLE" = "replica" ] || [ "$ROLE" = "standby" ]; then
            echo -e "$OK Replica"
            ((REPLICA_COUNT++))
            ((SUCCESS++))
        else
            echo -e "$WARN $ROLE/$STATE"
        fi
    else
        echo -e "$KO $ROLE/$STATE"
    fi
done

echo ""
echo "  Résumé: $LEADER_COUNT leader(s), $REPLICA_COUNT replica(s)"

if [ $LEADER_COUNT -eq 1 ] && [ $REPLICA_COUNT -eq 2 ]; then
    echo -e "  $OK Topology correcte"
else
    echo -e "  $WARN Topology incorrecte (attendu: 1 leader + 2 replicas)"
fi

# ============================================================================
# SECTION 3: RÉPLICATION POSTGRESQL
# ============================================================================

echo ""
echo "▓▓▓ 3. RÉPLICATION POSTGRESQL ▓▓▓"
echo ""

((TOTAL++))
echo -n "  Replicas connectées: "
REPL_COUNT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$DB_MASTER_IP" \
    "docker exec patroni psql -U postgres -t -c 'SELECT COUNT(*) FROM pg_stat_replication;' 2>/dev/null" | xargs 2>/dev/null || echo "0")

if [ "$REPL_COUNT" -eq 2 ]; then
    echo -e "$OK ($REPL_COUNT/2)"
    ((SUCCESS++))
    
    # Afficher les détails
    echo ""
    echo "  Détails:"
    ssh -o StrictHostKeyChecking=no root@"$DB_MASTER_IP" \
        "docker exec patroni psql -U postgres -c 'SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;' 2>/dev/null" | sed 's/^/    /' || true
else
    echo -e "$KO ($REPL_COUNT/2)"
fi

# ============================================================================
# SECTION 4: HAPROXY
# ============================================================================

echo ""
echo "▓▓▓ 4. HAPROXY ▓▓▓"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    echo "→ $NAME ($IP)"
    
    # Test Stats
    ((TOTAL++))
    echo -n "    Stats (8404): "
    if curl -sf -m 5 "http://${IP}:8404/" | grep -q "Statistics" 2>/dev/null; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
    fi
    
    # Test Write
    ((TOTAL++))
    echo -n "    Write (5432): "
    if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $IP -p 5432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
    fi
    
    # Test Read
    ((TOTAL++))
    echo -n "    Read (5433): "
    if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $IP -p 5433 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
    fi
    
    echo ""
done

# ============================================================================
# SECTION 5: PGBOUNCER
# ============================================================================

echo "▓▓▓ 5. PGBOUNCER ▓▓▓"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    ((TOTAL++))
    echo -n "  $NAME ($IP): "
    
    # Test connexion PgBouncer
    if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $IP -p 6432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
        
        # Vérifier si le conteneur tourne
        PGBOUNCER_STATE=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps --format '{{.Status}}' --filter name=pgbouncer" 2>/dev/null)
        if echo "$PGBOUNCER_STATE" | grep -qi "restarting"; then
            echo "    → Conteneur en crash loop (voir logs: ssh root@$IP 'docker logs pgbouncer')"
        elif [ -z "$PGBOUNCER_STATE" ]; then
            echo "    → Conteneur arrêté"
        fi
    fi
done

# ============================================================================
# SECTION 6: LOAD BALANCER HETZNER (optionnel)
# ============================================================================

echo ""
echo "▓▓▓ 6. LOAD BALANCER HETZNER (10.0.0.10) ▓▓▓"
echo ""

((TOTAL++))
echo -n "  PostgreSQL Write (5432): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 5432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
    ((SUCCESS++))
else
    echo -e "$WARN (peut ne pas être configuré)"
fi

((TOTAL++))
echo -n "  PostgreSQL Read (5433): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 5433 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
    ((SUCCESS++))
else
    echo -e "$WARN (peut ne pas être configuré)"
fi

((TOTAL++))
echo -n "  PgBouncer (6432): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 6432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
    ((SUCCESS++))
else
    echo -e "$WARN (peut ne pas être configuré)"
fi

# ============================================================================
# RÉSUMÉ FINAL
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

PERCENT=$((SUCCESS * 100 / TOTAL))

if [ $PERCENT -ge 90 ]; then
    echo -e "  🎉 INFRASTRUCTURE: $OK OPÉRATIONNELLE ($SUCCESS/$TOTAL - $PERCENT%)"
elif [ $PERCENT -ge 70 ]; then
    echo -e "  $WARN INFRASTRUCTURE: PARTIELLEMENT OPÉRATIONNELLE ($SUCCESS/$TOTAL - $PERCENT%)"
else
    echo -e "  $KO INFRASTRUCTURE: NON OPÉRATIONNELLE ($SUCCESS/$TOTAL - $PERCENT%)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Conseils en fonction des problèmes détectés
if [ $PERCENT -lt 90 ]; then
    echo "🔧 ACTIONS RECOMMANDÉES:"
    echo ""
    
    # PgBouncer en problème ?
    for IP in "$HAPROXY1_IP" "$HAPROXY2_IP"; do
        if ! timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $IP -p 6432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
            echo "   • Corriger PgBouncer: bash /opt/keybuzz-installer/scripts/06_pgbouncer_scram_CORRECTED_V5.sh"
            break
        fi
    done
    
    # Réplication en problème ?
    if [ "$REPL_COUNT" -lt 2 ]; then
        echo "   • Rejoindre les replicas au cluster: bash /opt/keybuzz-installer/scripts/fix_replicas_deep_clean.sh"
    fi
    
    # Leader manquant ?
    if [ $LEADER_COUNT -ne 1 ]; then
        echo "   • Cluster Patroni en split-brain - vérifier manuellement"
    fi
    
    echo ""
fi

echo "📖 Pour plus de détails, lancer:"
echo "   bash /opt/keybuzz-installer/scripts/07_test_infrastructure_FINAL.sh"
echo ""
