#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           HEALTH CHECK - Vérification rapide infrastructure        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

declare -A DB_IPS=(
    [db-master-01]="10.0.0.120"
    [db-slave-01]="10.0.0.121"
    [db-slave-02]="10.0.0.122"
)

declare -A PROXY_IPS=(
    [haproxy-01]="10.0.0.11"
    [haproxy-02]="10.0.0.12"
)

echo ""
echo "1. NŒUDS DB"
echo "───────────"

for node in db-master-01 db-slave-01 db-slave-02; do
    ip="${DB_IPS[$node]}"
    echo -n "  $node ($ip): "
    
    if ssh -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "docker ps | grep -q patroni" 2>/dev/null; then
        IS_LEADER=$(ssh -o BatchMode=yes root@"$ip" \
            "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
        
        if [ "$IS_LEADER" = "f" ]; then
            echo -e "$OK LEADER"
        elif [ "$IS_LEADER" = "t" ]; then
            echo -e "$OK REPLICA"
        else
            echo -e "$WARN Running (status inconnu)"
        fi
    else
        echo -e "$KO Conteneur arrêté ou inaccessible"
    fi
done

echo ""
echo "2. NŒUDS PROXY"
echo "──────────────"

for node in haproxy-01 haproxy-02; do
    ip="${PROXY_IPS[$node]}"
    echo -n "  $node ($ip): "
    
    haproxy_ok=false
    pgbouncer_ok=false
    
    if ssh -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "docker ps | grep -q haproxy" 2>/dev/null; then
        haproxy_ok=true
    fi
    
    if ssh -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "docker ps | grep -q pgbouncer" 2>/dev/null; then
        pgbouncer_ok=true
    fi
    
    if $haproxy_ok && $pgbouncer_ok; then
        echo -e "$OK HAProxy + PgBouncer"
    elif $haproxy_ok; then
        echo -e "$WARN HAProxy OK, PgBouncer KO"
    elif $pgbouncer_ok; then
        echo -e "$WARN HAProxy KO, PgBouncer OK"
    else
        echo -e "$KO Tous services arrêtés"
    fi
done

echo ""
echo "3. CONNECTIVITÉ"
echo "───────────────"

# Test VIP
echo -n "  VIP (10.0.0.10:5432): "
if timeout 3 nc -zv 10.0.0.10 5432 2>/dev/null | grep -q succeeded; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test HAProxy write
echo -n "  HAProxy Write (10.0.0.11:5432): "
if timeout 3 nc -zv 10.0.0.11 5432 2>/dev/null | grep -q succeeded; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test HAProxy read
echo -n "  HAProxy Read (10.0.0.11:5433): "
if timeout 3 nc -zv 10.0.0.11 5433 2>/dev/null | grep -q succeeded; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

# Test PgBouncer
echo -n "  PgBouncer (10.0.0.11:6432): "
if timeout 3 nc -zv 10.0.0.11 6432 2>/dev/null | grep -q succeeded; then
    echo -e "$OK"
else
    echo -e "$KO"
fi

echo ""
echo "4. SERVICES SYSTÈME"
echo "───────────────────"

for node in haproxy-01 haproxy-02; do
    ip="${PROXY_IPS[$node]}"
    echo -n "  Keepalived sur $node: "
    
    if ssh -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "systemctl is-active --quiet keepalived" 2>/dev/null; then
        STATE=$(ssh -o BatchMode=yes root@"$ip" "cat /var/run/keepalived-state 2>/dev/null || echo 'UNKNOWN'")
        echo -e "$OK ($STATE)"
    else
        echo -e "$KO Arrêté"
    fi
done

echo ""
echo "5. API PATRONI"
echo "──────────────"

LEADER_FOUND=false
for node in db-master-01 db-slave-01 db-slave-02; do
    ip="${DB_IPS[$node]}"
    
    if curl -s --connect-timeout 3 "http://$ip:8008/health" 2>/dev/null | grep -q "200"; then
        if curl -s --connect-timeout 3 "http://$ip:8008/master" 2>/dev/null | grep -q "200"; then
            echo -e "  $OK $node est le LEADER (API: http://$ip:8008)"
            LEADER_FOUND=true
            break
        fi
    fi
done

if ! $LEADER_FOUND; then
    echo -e "  $KO Aucun leader détecté"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Compter les problèmes
ISSUES=0

for node in db-master-01 db-slave-01 db-slave-02; do
    ip="${DB_IPS[$node]}"
    if ! ssh -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "docker ps | grep -q patroni" 2>/dev/null; then
        ((ISSUES++))
    fi
done

for node in haproxy-01 haproxy-02; do
    ip="${PROXY_IPS[$node]}"
    if ! ssh -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "docker ps | grep -q haproxy" 2>/dev/null; then
        ((ISSUES++))
    fi
done

if [ $ISSUES -eq 0 ]; then
    echo -e "$OK INFRASTRUCTURE OPÉRATIONNELLE"
elif [ $ISSUES -le 2 ]; then
    echo -e "$WARN INFRASTRUCTURE PARTIELLEMENT OPÉRATIONNELLE ($ISSUES problème(s))"
else
    echo -e "$KO INFRASTRUCTURE NON OPÉRATIONNELLE ($ISSUES problèmes)"
fi

echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ $ISSUES -gt 0 ]; then
    echo "Commandes de diagnostic:"
    echo "  • Tests complets     : ./08_test_infrastructure.sh"
    echo "  • Logs Patroni       : ssh root@10.0.0.120 'docker logs patroni --tail 50'"
    echo "  • Cluster status     : curl -s http://10.0.0.120:8008/cluster | jq"
    echo "  • HAProxy stats      : curl -s http://10.0.0.11:8404/stats"
    echo ""
fi

exit $ISSUES
