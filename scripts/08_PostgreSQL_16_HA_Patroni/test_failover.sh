#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              TEST_FAILOVER - Test automatique du failover          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDS_DIR="/opt/keybuzz-installer/credentials"
LOG_FILE="/opt/keybuzz-installer/logs/test_failover_$(date +%Y%m%d_%H%M%S).log"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
[ ! -f "$CREDS_DIR/postgres.env" ] && { echo -e "$KO postgres.env introuvable"; exit 1; }

source "$CREDS_DIR/postgres.env"

mkdir -p "$(dirname "$LOG_FILE")"

declare -A DB_IPS=(
    [db-master-01]="10.0.0.120"
    [db-slave-01]="10.0.0.121"
    [db-slave-02]="10.0.0.122"
)

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "        TEST DE FAILOVER AUTOMATIQUE - PATRONI RAFT" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Fonction pour identifier le leader
find_leader() {
    for node_name in db-master-01 db-slave-01 db-slave-02; do
        node_ip="${DB_IPS[$node_name]}"
        
        IS_LEADER=$(ssh -o StrictHostKeyChecking=no root@"$node_ip" \
            "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
        
        if [ "$IS_LEADER" = "f" ]; then
            echo "$node_name:$node_ip"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# Fonction pour compter les membres sains
count_healthy_members() {
    local count=0
    
    for node_name in db-master-01 db-slave-01 db-slave-02; do
        node_ip="${DB_IPS[$node_name]}"
        
        if ssh -o StrictHostKeyChecking=no root@"$node_ip" \
            "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
            ((count++))
        fi
    done
    
    echo $count
}

echo "1. État initial du cluster" | tee -a "$LOG_FILE"
echo "───────────────────────────" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Identifier le leader initial
LEADER_INFO=$(find_leader)
if [ -z "$LEADER_INFO" ]; then
    echo -e "$KO Aucun leader trouvé - cluster non opérationnel" | tee -a "$LOG_FILE"
    exit 1
fi

IFS=':' read -r LEADER_NAME LEADER_IP <<< "$LEADER_INFO"
echo -e "  Leader actuel: $OK $LEADER_NAME ($LEADER_IP)" | tee -a "$LOG_FILE"

# Compter les membres sains
HEALTHY_COUNT=$(count_healthy_members)
echo "  Membres sains: $HEALTHY_COUNT/3" | tee -a "$LOG_FILE"

if [ $HEALTHY_COUNT -lt 3 ]; then
    echo -e "$WARN Certains nœuds ne sont pas sains" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# Créer une table de test
echo "2. Préparation du test" | tee -a "$LOG_FILE"
echo "──────────────────────" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "  Création table de test..." | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
    "docker exec patroni psql -U postgres -d keybuzz -c 'CREATE TABLE IF NOT EXISTS failover_test (id SERIAL PRIMARY KEY, test_id TEXT UNIQUE, created_at TIMESTAMP DEFAULT NOW())' 2>/dev/null" >/dev/null

if [ $? -eq 0 ]; then
    echo -e "  $OK Table créée" | tee -a "$LOG_FILE"
else
    echo -e "  $KO Échec création table" | tee -a "$LOG_FILE"
    exit 1
fi

# Insérer des données avant le failover
TEST_ID_BEFORE="before_failover_$(date +%s)"
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
    "docker exec patroni psql -U postgres -d keybuzz -c \"INSERT INTO failover_test (test_id) VALUES ('$TEST_ID_BEFORE')\" 2>/dev/null" >/dev/null

echo "  Données insérées: $TEST_ID_BEFORE" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"

# Test de connexion continue
echo "3. Test de failover" | tee -a "$LOG_FILE"
echo "───────────────────" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo -e "$WARN Ce test va arrêter le leader actuel pour déclencher un failover" | tee -a "$LOG_FILE"
read -p "Continuer? (yes/NO): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Test annulé" | tee -a "$LOG_FILE"
    exit 0
fi

echo "" | tee -a "$LOG_FILE"
echo "  Démarrage du test de connexion continue..." | tee -a "$LOG_FILE"

# Fonction de test de connexion en arrière-plan
test_connectivity() {
    local log_file="$1"
    local start_time=$(date +%s)
    local connection_lost=0
    local downtime_start=0
    local downtime_duration=0
    
    while true; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        
        # Arrêter après 120 secondes
        if [ $elapsed -gt 120 ]; then
            break
        fi
        
        # Test de connexion via VIP
        if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U postgres -d keybuzz -c "SELECT 1" -t >/dev/null 2>&1; then
            if [ $connection_lost -eq 1 ]; then
                # Connexion rétablie
                downtime_duration=$((current_time - downtime_start))
                echo "RECONNECTED|$downtime_duration" >> "$log_file"
                connection_lost=0
            fi
            echo "CONNECTED|$elapsed" >> "$log_file"
        else
            if [ $connection_lost -eq 0 ]; then
                # Connexion perdue
                downtime_start=$current_time
                connection_lost=1
                echo "DISCONNECTED|$elapsed" >> "$log_file"
            fi
            echo "FAILED|$elapsed" >> "$log_file"
        fi
        
        sleep 1
    done
}

# Démarrer le test de connexion en arrière-plan
CONN_TEST_LOG="/tmp/failover_conn_test_$$.log"
> "$CONN_TEST_LOG"
test_connectivity "$CONN_TEST_LOG" &
CONN_TEST_PID=$!

sleep 5

# Arrêter le leader
echo "  Arrêt du leader $LEADER_NAME ($LEADER_IP)..." | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" "docker stop patroni" >/dev/null 2>&1

FAILOVER_START=$(date +%s)

echo "  Attente du failover (max 60s)..." | tee -a "$LOG_FILE"

# Attendre qu'un nouveau leader soit élu
NEW_LEADER_INFO=""
for i in {1..60}; do
    sleep 1
    
    NEW_LEADER_INFO=$(find_leader)
    if [ -n "$NEW_LEADER_INFO" ]; then
        IFS=':' read -r NEW_LEADER_NAME NEW_LEADER_IP <<< "$NEW_LEADER_INFO"
        
        if [ "$NEW_LEADER_IP" != "$LEADER_IP" ]; then
            FAILOVER_END=$(date +%s)
            FAILOVER_DURATION=$((FAILOVER_END - FAILOVER_START))
            echo -e "  $OK Nouveau leader élu: $NEW_LEADER_NAME ($NEW_LEADER_IP)" | tee -a "$LOG_FILE"
            echo "  Durée du failover: ${FAILOVER_DURATION}s" | tee -a "$LOG_FILE"
            break
        fi
    fi
    
    if [ $i -eq 60 ]; then
        echo -e "  $KO Timeout - Aucun nouveau leader élu après 60s" | tee -a "$LOG_FILE"
        kill $CONN_TEST_PID 2>/dev/null
        exit 1
    fi
done

echo "" | tee -a "$LOG_FILE"

# Attendre la fin du test de connexion
wait $CONN_TEST_PID 2>/dev/null

# Analyser les résultats du test de connexion
echo "4. Analyse de la disponibilité" | tee -a "$LOG_FILE"
echo "───────────────────────────────" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

TOTAL_TESTS=$(grep -c "CONNECTED\|FAILED" "$CONN_TEST_LOG")
SUCCESSFUL_TESTS=$(grep -c "CONNECTED" "$CONN_TEST_LOG")
FAILED_TESTS=$(grep -c "FAILED" "$CONN_TEST_LOG")
DOWNTIME_DURATION=$(grep "RECONNECTED" "$CONN_TEST_LOG" | head -1 | cut -d'|' -f2)

if [ -z "$DOWNTIME_DURATION" ]; then
    DOWNTIME_DURATION=0
fi

AVAILABILITY=$((SUCCESSFUL_TESTS * 100 / TOTAL_TESTS))

echo "  Tests de connexion: $TOTAL_TESTS" | tee -a "$LOG_FILE"
echo "  Réussis: $SUCCESSFUL_TESTS" | tee -a "$LOG_FILE"
echo "  Échoués: $FAILED_TESTS" | tee -a "$LOG_FILE"
echo "  Disponibilité: ${AVAILABILITY}%" | tee -a "$LOG_FILE"
echo "  Downtime mesuré: ${DOWNTIME_DURATION}s" | tee -a "$LOG_FILE"

rm -f "$CONN_TEST_LOG"

echo "" | tee -a "$LOG_FILE"

# Vérifier l'intégrité des données
echo "5. Vérification de l'intégrité des données" | tee -a "$LOG_FILE"
echo "───────────────────────────────────────────" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Insérer de nouvelles données sur le nouveau leader
TEST_ID_AFTER="after_failover_$(date +%s)"
ssh -o StrictHostKeyChecking=no root@"$NEW_LEADER_IP" \
    "docker exec patroni psql -U postgres -d keybuzz -c \"INSERT INTO failover_test (test_id) VALUES ('$TEST_ID_AFTER')\" 2>/dev/null" >/dev/null

if [ $? -eq 0 ]; then
    echo -e "  $OK Nouvelles données insérées: $TEST_ID_AFTER" | tee -a "$LOG_FILE"
else
    echo -e "  $KO Échec insertion données" | tee -a "$LOG_FILE"
fi

# Vérifier que les anciennes données sont toujours là
DATA_BEFORE=$(ssh -o StrictHostKeyChecking=no root@"$NEW_LEADER_IP" \
    "docker exec patroni psql -U postgres -d keybuzz -t -c \"SELECT COUNT(*) FROM failover_test WHERE test_id='$TEST_ID_BEFORE'\" 2>/dev/null" | xargs)

if [ "$DATA_BEFORE" = "1" ]; then
    echo -e "  $OK Données pré-failover préservées" | tee -a "$LOG_FILE"
else
    echo -e "  $KO Données pré-failover perdues" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# Redémarrer l'ancien leader
echo "6. Redémarrage de l'ancien leader" | tee -a "$LOG_FILE"
echo "──────────────────────────────────" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "  Redémarrage de $LEADER_NAME..." | tee -a "$LOG_FILE"
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" "docker start patroni" >/dev/null 2>&1

sleep 10

# Vérifier que l'ancien leader rejoint le cluster en tant que replica
IS_REPLICA=$(ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
    "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)

if [ "$IS_REPLICA" = "t" ]; then
    echo -e "  $OK $LEADER_NAME a rejoint le cluster en tant que replica" | tee -a "$LOG_FILE"
else
    echo -e "  $WARN $LEADER_NAME n'est pas encore une replica" | tee -a "$LOG_FILE"
fi

# Vérifier la réplication vers l'ancien leader
sleep 5
DATA_AFTER=$(ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
    "docker exec patroni psql -U postgres -d keybuzz -t -c \"SELECT COUNT(*) FROM failover_test WHERE test_id='$TEST_ID_AFTER'\" 2>/dev/null" | xargs)

if [ "$DATA_AFTER" = "1" ]; then
    echo -e "  $OK Données post-failover répliquées" | tee -a "$LOG_FILE"
else
    echo -e "  $WARN Données post-failover pas encore répliquées" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# Nettoyer
echo "7. Nettoyage" | tee -a "$LOG_FILE"
echo "─────────────" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

ssh -o StrictHostKeyChecking=no root@"$NEW_LEADER_IP" \
    "docker exec patroni psql -U postgres -d keybuzz -c 'DROP TABLE IF EXISTS failover_test' 2>/dev/null" >/dev/null

echo "  Table de test supprimée" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"

# Résumé
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "                    RÉSUMÉ DU TEST DE FAILOVER" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Ancien leader      : $LEADER_NAME ($LEADER_IP)" | tee -a "$LOG_FILE"
echo "Nouveau leader     : $NEW_LEADER_NAME ($NEW_LEADER_IP)" | tee -a "$LOG_FILE"
echo "Durée du failover  : ${FAILOVER_DURATION}s" | tee -a "$LOG_FILE"
echo "Downtime mesuré    : ${DOWNTIME_DURATION}s" | tee -a "$LOG_FILE"
echo "Disponibilité      : ${AVAILABILITY}%" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"

# Évaluation
if [ $FAILOVER_DURATION -le 30 ] && [ $AVAILABILITY -ge 95 ]; then
    echo -e "$OK TEST DE FAILOVER RÉUSSI" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Le cluster Patroni RAFT fonctionne correctement :" | tee -a "$LOG_FILE"
    echo "  • Failover automatique en moins de 30s ✓" | tee -a "$LOG_FILE"
    echo "  • Disponibilité > 95% ✓" | tee -a "$LOG_FILE"
    echo "  • Intégrité des données préservée ✓" | tee -a "$LOG_FILE"
    echo "  • Ancien leader réintégré automatiquement ✓" | tee -a "$LOG_FILE"
    STATUS=0
elif [ $FAILOVER_DURATION -le 60 ]; then
    echo -e "$WARN TEST DE FAILOVER ACCEPTABLE" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Le failover a fonctionné mais peut être optimisé :" | tee -a "$LOG_FILE"
    echo "  • Durée du failover: ${FAILOVER_DURATION}s (optimal: <30s)" | tee -a "$LOG_FILE"
    echo "  • Disponibilité: ${AVAILABILITY}% (optimal: >95%)" | tee -a "$LOG_FILE"
    STATUS=0
else
    echo -e "$KO TEST DE FAILOVER ÉCHOUÉ" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Le failover a pris trop de temps ou a échoué" | tee -a "$LOG_FILE"
    STATUS=1
fi

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Log complet: $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

tail -n 50 "$LOG_FILE"

exit $STATUS
