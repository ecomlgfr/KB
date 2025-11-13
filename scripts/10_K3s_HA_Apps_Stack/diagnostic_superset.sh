#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC SUPERSET - Architecture KeyBuzz                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État des pods Superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset -o wide"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Événements namespace superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get events -n superset --sort-by='.lastTimestamp' | tail -20"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Logs des pods en CrashLoopBackOff ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

CRASHED_PODS=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n superset --no-headers | grep -E '(CrashLoopBackOff|Error)' | awk '{print \$1}'")

if [ -n "$CRASHED_PODS" ]; then
    for POD in $CRASHED_PODS; do
        echo ""
        echo "▶ Logs du pod : $POD"
        echo "────────────────────────────────────────────────────────────────"
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n superset $POD --tail=50 2>&1 || kubectl logs -n superset $POD -p --tail=50 2>&1"
        echo ""
    done
else
    echo -e "${WARN} Aucun pod en erreur actuellement"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Description DaemonSet Superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get daemonset -n superset 2>/dev/null || echo 'Pas de DaemonSet Superset'"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get deployment -n superset 2>/dev/null || echo 'Pas de Deployment Superset'"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Vérification des secrets ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get secret -n superset"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Test connectivité PostgreSQL et Redis ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test PostgreSQL 10.0.0.10:5432 :"
timeout 3 bash -c "</dev/tcp/10.0.0.10/5432" && echo -e "$OK PostgreSQL accessible" || echo -e "$KO PostgreSQL inaccessible"

echo ""
echo "Test Redis 10.0.0.10:6379 :"
timeout 3 bash -c "</dev/tcp/10.0.0.10/6379" && echo -e "$OK Redis accessible" || echo -e "$KO Redis inaccessible"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Diagnostic terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
