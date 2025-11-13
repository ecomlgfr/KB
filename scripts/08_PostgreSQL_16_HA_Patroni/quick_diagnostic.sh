#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                 QUICK_DIAGNOSTIC - Diagnostic rapide               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. État des containers..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo "  $hostname ($ip):"
    
    # Patroni
    PATRONI_STATUS=$(ssh root@"$ip" "docker ps | grep patroni" 2>/dev/null | awk '{print $7,$8}' || echo "NOT RUNNING")
    echo "    Patroni: $PATRONI_STATUS"
    
    # PgBouncer
    PGBOUNCER_STATUS=$(ssh root@"$ip" "docker ps | grep pgbouncer" 2>/dev/null | awk '{print $7,$8}' || echo "NOT RUNNING")
    echo "    PgBouncer: $PGBOUNCER_STATUS"
done

echo ""
echo "2. Test API Patroni..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  $ip: "
    STATUS=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f'{d.get(\"state\")}/{d.get(\"role\")}')
except:
    print('API ERROR')
" 2>/dev/null || echo "UNREACHABLE")
    
    if [[ "$STATUS" == *"running"* ]]; then
        echo -e "$OK $STATUS"
    else
        echo -e "$KO $STATUS"
    fi
done

echo ""
echo "3. Identification du leader..."
echo ""

LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    ROLE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('role',''))
except:
    pass
" 2>/dev/null)
    
    if [ "$ROLE" = "master" ] || [ "$ROLE" = "leader" ]; then
        LEADER_IP="$ip"
        echo -e "  Leader: $ip $OK"
        break
    fi
done

if [ -z "$LEADER_IP" ]; then
    echo -e "  $KO Aucun leader trouvé!"
    
    echo ""
    echo "4. Logs d'erreur Patroni..."
    echo ""
    
    for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
        echo "  Erreurs sur $ip:"
        ssh root@"$ip" "docker logs patroni 2>&1 | grep -E 'ERROR|FATAL|Failed' | tail -3" 2>/dev/null | sed 's/^/    /'
    done
else
    echo ""
    echo "4. Test connexion directe au leader..."
    echo ""
    
    # Test depuis le serveur lui-même
    echo -n "  Test local sur $LEADER_IP: "
    TEST_LOCAL=$(ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c 'SELECT 1' -t 2>&1")
    if echo "$TEST_LOCAL" | grep -q "1"; then
        echo -e "$OK"
    else
        echo -e "$KO"
        echo "    Erreur: $(echo "$TEST_LOCAL" | head -1)"
    fi
    
    # Test avec le nouveau mot de passe
    echo -n "  Test distant avec nouveau password: "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1; then
        echo -e "$OK"
    else
        echo -e "$KO"
        
        # Essayer de comprendre pourquoi
        ERROR=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres -c "SELECT 1" 2>&1 | head -1)
        echo "    Erreur: $ERROR"
    fi
fi

echo ""
echo "5. Vérification réseau..."
echo ""

echo -n "  Port 5432 ouvert sur 10.0.0.120: "
nc -zv 10.0.0.120 5432 2>&1 | grep -q "succeeded\|Connected" && echo -e "$OK" || echo -e "$KO"

echo -n "  Port 6432 ouvert sur 10.0.0.120: "
nc -zv 10.0.0.120 6432 2>&1 | grep -q "succeeded\|Connected" && echo -e "$OK" || echo -e "$KO"

echo ""
echo "6. Configuration actuelle..."
echo ""

echo "  Password actuel: $POSTGRES_PASSWORD"
echo "  Leader IP: ${LEADER_IP:-NON TROUVÉ}"

if [ -n "$LEADER_IP" ]; then
    echo ""
    echo "7. Tentative de réparation..."
    echo ""
    
    echo "  Réinitialisation du mot de passe postgres dans la base..."
    ssh root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" <<'FIX_PASSWORD'
NEW_PASSWORD="$1"

docker exec patroni psql -U postgres <<SQL
ALTER USER postgres PASSWORD '$NEW_PASSWORD';
ALTER USER replicator PASSWORD '$NEW_PASSWORD';
\q
SQL

echo "  Mot de passe mis à jour"
FIX_PASSWORD
    
    # Retest
    echo -n "  Test après correction: "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres -c "SELECT 'OK'" -t 2>/dev/null | grep -q OK; then
        echo -e "$OK Connexion réussie!"
    else
        echo -e "$KO Échec persistant"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -n "$LEADER_IP" ]; then
    echo "Commande pour tester manuellement:"
    echo "  PGPASSWORD='$POSTGRES_PASSWORD' psql -h $LEADER_IP -p 5432 -U postgres -d postgres"
else
    echo "Le cluster n'a pas de leader actif. Vérifiez les logs."
fi

echo "═══════════════════════════════════════════════════════════════════"
