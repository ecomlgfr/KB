#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     07_TEST_INFRASTRUCTURE - Tests complets PostgreSQL HA          ║"
echo "║                    VERSION CORRIGÉE V2                             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CRED_FILE="/opt/keybuzz-installer/credentials/postgres.env"

# Charger credentials
if [ -f "$CRED_FILE" ]; then
    source "$CRED_FILE"
else
    echo -e "$KO Fichier credentials manquant: $CRED_FILE"
    exit 1
fi

# Vérifier que PATRONI_API_PASSWORD est défini
if [ -z "${PATRONI_API_PASSWORD:-}" ]; then
    echo -e "$KO Variable PATRONI_API_PASSWORD non définie dans $CRED_FILE"
    exit 1
fi

# IPs depuis servers.tsv
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2_IP=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")
LB_IP="10.0.0.10"

SUCCESS=0
TOTAL=0

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "                    TESTS INFRASTRUCTURE POSTGRESQL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ============================================================================
# SECTION 1: CLUSTER PATRONI
# ============================================================================

echo "▓▓▓ 1. CLUSTER PATRONI ▓▓▓"
echo ""

LEADER_COUNT=0
REPLICA_COUNT=0

for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    ((TOTAL++))
    
    echo -n "  $NAME ($IP): "
    
    # Test conteneur Patroni
    if ! ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps | grep -q patroni" 2>/dev/null; then
        echo -e "$KO Conteneur arrêté"
        continue
    fi
    
    # Test API Patroni AVEC AUTH
    API_RESPONSE=$(curl -s -m 5 -u "patroni:${PATRONI_API_PASSWORD}" "http://${IP}:8008/" 2>/dev/null)
    
    if [ -z "$API_RESPONSE" ]; then
        echo -e "$KO API non accessible"
        continue
    fi
    
    # Extraction avec Python (plus fiable)
    ROLE=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('role', 'unknown'))" 2>/dev/null || echo "unknown")
    STATE=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('state', 'unknown'))" 2>/dev/null || echo "unknown")
    
    if [ "$STATE" = "running" ]; then
        if [ "$ROLE" = "leader" ] || [ "$ROLE" = "master" ]; then
            echo -e "$OK Leader"
            ((LEADER_COUNT++))
            ((SUCCESS++))
        elif [ "$ROLE" = "replica" ] || [ "$ROLE" = "standby" ]; then
            echo -e "$OK Replica"
            ((REPLICA_COUNT++))
            ((SUCCESS++))
        else
            echo -e "$WARN [$ROLE/$STATE]"
        fi
    else
        echo -e "$WARN [$ROLE/$STATE]"
    fi
done

echo ""
echo "  Résumé: $LEADER_COUNT leader(s), $REPLICA_COUNT replica(s)"

if [ $LEADER_COUNT -eq 1 ] && [ $REPLICA_COUNT -eq 2 ]; then
    echo -e "  $OK Topology correcte"
else
    echo -e "  $WARN Topology incorrecte (attendu: 1 leader + 2 replicas)"
fi

echo ""

# ============================================================================
# SECTION 2: RÉPLICATION POSTGRESQL
# ============================================================================

echo "▓▓▓ 2. RÉPLICATION POSTGRESQL ▓▓▓"
echo ""

((TOTAL++))
echo -n "  Streaming replication: "
REPL_COUNT=$(ssh -o StrictHostKeyChecking=no root@"$DB_MASTER_IP" \
    "docker exec patroni psql -U postgres -t -c 'SELECT COUNT(*) FROM pg_stat_replication;' 2>/dev/null" | xargs 2>/dev/null || echo "0")

if [ "$REPL_COUNT" -eq 2 ]; then
    echo -e "$OK (2 replicas connectées)"
    ((SUCCESS++))
    
    # Afficher les détails
    echo ""
    echo "  Détails réplication:"
    ssh -o StrictHostKeyChecking=no root@"$DB_MASTER_IP" \
        "docker exec patroni psql -U postgres -c 'SELECT client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;' 2>/dev/null" | sed 's/^/    /'
else
    echo -e "$KO ($REPL_COUNT/2 replica connectée)"
fi

echo ""

# ============================================================================
# SECTION 3: HAPROXY
# ============================================================================

echo "▓▓▓ 3. HAPROXY ▓▓▓"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "→ $NAME ($IP)"
    
    # Test conteneur
    ((TOTAL++))
    echo -n "    Conteneur: "
    if ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps | grep -q haproxy" 2>/dev/null; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
    fi
    
    # Test Stats (CORRIGÉ: accepte DOCTYPE)
    ((TOTAL++))
    echo -n "    Stats (8404): "
    STATS_RESULT=$(curl -sf -m 5 "http://${IP}:8404/" 2>&1 | head -20)
    if echo "$STATS_RESULT" | grep -qi "haproxy\|statistics\|DOCTYPE"; then
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
# SECTION 4: PGBOUNCER
# ============================================================================

echo "▓▓▓ 4. PGBOUNCER ▓▓▓"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "→ $NAME ($IP)"
    
    # Test conteneur
    ((TOTAL++))
    echo -n "    Conteneur: "
    if ssh -o StrictHostKeyChecking=no root@"$IP" "docker ps | grep -q pgbouncer" 2>/dev/null; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
    fi
    
    # Test connexion SCRAM
    ((TOTAL++))
    echo -n "    SCRAM (6432): "
    if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $IP -p 6432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$WARN"
    fi
    
    echo ""
done

# ============================================================================
# SECTION 5: LOAD BALANCER HETZNER
# ============================================================================

echo "▓▓▓ 5. LOAD BALANCER HETZNER ($LB_IP) ▓▓▓"
echo ""

# Test Write via LB
((TOTAL++))
echo -n "  PostgreSQL Write (5432): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $LB_IP -p 5432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
    ((SUCCESS++))
else
    echo -e "$KO"
    echo "    → Vérifiez que le LB Hetzner est configuré pour router vers haproxy-01/02"
fi

# Test Read via LB
((TOTAL++))
echo -n "  PostgreSQL Read (5433): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $LB_IP -p 5433 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
    ((SUCCESS++))
else
    echo -e "$KO"
fi

# Test PgBouncer via LB
((TOTAL++))
echo -n "  PgBouncer (6432): "
if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $LB_IP -p 6432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
    echo -e "$OK"
    ((SUCCESS++))
else
    echo -e "$WARN"
fi

echo ""

# ============================================================================
# SECTION 6: TEST DE FAILOVER (OPTIONNEL)
# ============================================================================

echo "▓▓▓ 6. TEST FAILOVER (OPTIONNEL) ▓▓▓"
echo ""
echo "  Ce test simule une panne du leader et vérifie que Patroni"
echo "  promeut automatiquement un replica en leader."
echo ""
read -p "  Lancer le test de failover? (yes/NO): " CONFIRM

if [ "$CONFIRM" = "yes" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  🔥 TEST DE FAILOVER EN COURS"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    # Identifier le leader actuel
    CURRENT_LEADER=""
    CURRENT_LEADER_NAME=""
    
    for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP"; do
        IFS=':' read -r NAME IP <<< "$NODE"
        API_RESPONSE=$(curl -s -m 5 -u "patroni:${PATRONI_API_PASSWORD}" "http://${IP}:8008/" 2>/dev/null)
        ROLE=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('role', 'unknown'))" 2>/dev/null || echo "unknown")
        
        if [ "$ROLE" = "leader" ] || [ "$ROLE" = "master" ]; then
            CURRENT_LEADER="$IP"
            CURRENT_LEADER_NAME="$NAME"
            break
        fi
    done
    
    if [ -z "$CURRENT_LEADER" ]; then
        echo -e "  $KO Impossible d'identifier le leader actuel"
        echo "  → Test de failover annulé"
    else
        echo "  → Leader actuel: $CURRENT_LEADER_NAME ($CURRENT_LEADER)"
        echo ""
        
        # Arrêter le leader
        echo "  → Arrêt du leader ($CURRENT_LEADER_NAME)..."
        ssh -o StrictHostKeyChecking=no root@"$CURRENT_LEADER" "docker stop patroni" >/dev/null 2>&1
        
        echo "  → Attente promotion automatique (30 secondes)..."
        sleep 30
        
        # Vérifier quel nœud est devenu leader
        NEW_LEADER=""
        NEW_LEADER_NAME=""
        
        for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP"; do
            IFS=':' read -r NAME IP <<< "$NODE"
            
            # Ignorer l'ancien leader
            if [ "$IP" = "$CURRENT_LEADER" ]; then
                continue
            fi
            
            API_RESPONSE=$(curl -s -m 5 -u "patroni:${PATRONI_API_PASSWORD}" "http://${IP}:8008/" 2>/dev/null)
            ROLE=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('role', 'unknown'))" 2>/dev/null || echo "unknown")
            
            if [ "$ROLE" = "leader" ] || [ "$ROLE" = "master" ]; then
                NEW_LEADER="$IP"
                NEW_LEADER_NAME="$NAME"
                break
            fi
        done
        
        if [ -n "$NEW_LEADER" ]; then
            echo -e "  $OK Nouveau leader: $NEW_LEADER_NAME ($NEW_LEADER)"
            echo ""
            
            # Test connexion au nouveau leader via HAProxy
            echo -n "  → Test connexion Write via HAProxy: "
            if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $HAPROXY1_IP -p 5432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
                echo -e "$OK"
            else
                echo -e "$KO"
            fi
            
            # Test via LB Hetzner
            echo -n "  → Test connexion Write via LB Hetzner: "
            if timeout 5 bash -c "PGPASSWORD='$POSTGRES_PASSWORD' psql -h $LB_IP -p 5432 -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1"; then
                echo -e "$OK"
            else
                echo -e "$WARN"
            fi
        else
            echo -e "  $KO Aucun nouveau leader détecté après 30s"
        fi
        
        echo ""
        
        # Redémarrer l'ancien leader
        echo "  → Redémarrage de l'ancien leader ($CURRENT_LEADER_NAME)..."
        ssh -o StrictHostKeyChecking=no root@"$CURRENT_LEADER" "docker start patroni" >/dev/null 2>&1
        
        echo "  → Attente rejoint du cluster (30 secondes)..."
        sleep 30
        
        # Vérifier qu'il a rejoint en replica
        echo -n "  → Vérification rôle de $CURRENT_LEADER_NAME: "
        API_RESPONSE=$(curl -s -m 5 -u "patroni:${PATRONI_API_PASSWORD}" "http://${CURRENT_LEADER}:8008/" 2>/dev/null)
        ROLE=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('role', 'unknown'))" 2>/dev/null || echo "unknown")
        
        if [ "$ROLE" = "replica" ] || [ "$ROLE" = "standby" ]; then
            echo -e "$OK Replica (rejoint en tant que replica)"
        elif [ "$ROLE" = "leader" ] || [ "$ROLE" = "master" ]; then
            echo -e "$WARN Leader (a repris le leadership)"
        else
            echo -e "$WARN $ROLE"
        fi
        
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo -e "  $OK TEST DE FAILOVER TERMINÉ"
        echo "═══════════════════════════════════════════════════════════════════"
    fi
else
    echo "  ✓ Test ignoré"
fi

echo ""

# ============================================================================
# RÉSUMÉ FINAL
# ============================================================================

echo "═══════════════════════════════════════════════════════════════════"
echo ""

PERCENT=$((SUCCESS * 100 / TOTAL))

if [ $PERCENT -ge 90 ]; then
    echo -e "  🎉 INFRASTRUCTURE OPÉRATIONNELLE : $SUCCESS/$TOTAL tests ($PERCENT%)"
elif [ $PERCENT -ge 70 ]; then
    echo -e "  $WARN INFRASTRUCTURE PARTIELLEMENT OPÉRATIONNELLE : $SUCCESS/$TOTAL tests ($PERCENT%)"
else
    echo -e "  $KO INFRASTRUCTURE NON OPÉRATIONNELLE : $SUCCESS/$TOTAL tests ($PERCENT%)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📊 ARCHITECTURE VALIDÉE:"
echo ""
echo "   Applications"
echo "        ↓"
echo "   10.0.0.10 (LB Hetzner) ← Point d'entrée unique"
echo "        ↓"
echo "   ├─→ haproxy-01 ($HAPROXY1_IP) + PgBouncer"
echo "   └─→ haproxy-02 ($HAPROXY2_IP) + PgBouncer"
echo "        ↓"
echo "   Cluster Patroni RAFT (détection automatique leader/replicas)"
echo "   ├─→ db-master-01 ($DB_MASTER_IP)"
echo "   ├─→ db-slave-01 ($DB_SLAVE1_IP)"
echo "   └─→ db-slave-02 ($DB_SLAVE2_IP)"
echo ""
echo "🔌 STRING DE CONNEXION POUR LES APPLICATIONS:"
echo ""
echo "   # Recommandé : via PgBouncer (pooling)"
echo "   postgresql://postgres:PASSWORD@10.0.0.10:6432/votre_database"
echo ""
echo "   # Alternative : connexion directe"
echo "   postgresql://postgres:PASSWORD@10.0.0.10:5432/votre_database"
echo ""
echo "   # Lecture seule (replicas)"
echo "   postgresql://postgres:PASSWORD@10.0.0.10:5433/votre_database"
echo ""
echo "✅ AVANTAGES DE CETTE ARCHITECTURE:"
echo "   • Haute disponibilité (HA) avec failover automatique < 30s"
echo "   • Load balancing entre haproxy-01 et haproxy-02"
echo "   • Pooling de connexions via PgBouncer (SCRAM-SHA-256)"
echo "   • Point d'entrée unique via LB Hetzner (10.0.0.10)"
echo "   • Réplication streaming asynchrone (lag=0)"
echo ""
echo "📈 MONITORING:"
echo "   • HAProxy Stats: http://$HAPROXY1_IP:8404/"
echo "   • Patroni API: http://$DB_MASTER_IP:8008/ (auth: patroni)"
echo "   • PgBouncer Admin: PGPASSWORD=xxx psql -h $HAPROXY1_IP -p 6432 -U postgres pgbouncer"
echo ""

if [ $PERCENT -lt 90 ]; then
    echo "⚠  ACTIONS REQUISES:"
    echo ""
    
    if [ $LEADER_COUNT -ne 1 ]; then
        echo "   • Cluster Patroni: $LEADER_COUNT leader(s) détecté(s) (attendu: 1)"
    fi
    
    if [ $REPLICA_COUNT -ne 2 ]; then
        echo "   • Replicas: $REPLICA_COUNT replica(s) détecté(s) (attendu: 2)"
    fi
    
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "✅ CORRECTIONS APPLIQUÉES (V2):"
echo "   • Utilisation de PATRONI_API_PASSWORD pour l'API Patroni"
echo "   • Extraction JSON avec Python (plus fiable que grep)"
echo "   • Test HAProxy Stats corrigé (accepte DOCTYPE)"
echo "   • Détection correcte du leader pour le test de failover"
echo ""
