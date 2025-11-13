#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         DIAGNOSTIC PGBOUNCER DÉTAILLÉ                              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
HAPROXY1_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY2_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for NODE in "haproxy-01:$HAPROXY1_IP" "haproxy-02:$HAPROXY2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "▓▓▓ $NAME ($IP) ▓▓▓"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'DIAG'
    set -e
    
    echo "→ Test 1: Conteneurs pgbouncer (tous, actifs et arrêtés)"
    docker ps -a --filter name=pgbouncer --format "  ID: {{.ID}}\n  Nom: {{.Names}}\n  Image: {{.Image}}\n  Créé: {{.CreatedAt}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"
    echo ""
    
    CONTAINER_COUNT=$(docker ps -a --filter name=pgbouncer -q | wc -l)
    echo "  Nombre total de conteneurs pgbouncer: $CONTAINER_COUNT"
    
    RUNNING_COUNT=$(docker ps --filter name=pgbouncer -q | wc -l)
    echo "  Nombre de conteneurs actifs: $RUNNING_COUNT"
    echo ""
    
    echo "→ Test 2: Port 6432 (qui l'utilise ?)"
    ss -tlnp | grep ":6432" || echo "  (Port non utilisé)"
    echo ""
    
    echo "→ Test 3: Processus pgbouncer"
    ps aux | grep pgbouncer | grep -v grep || echo "  (Aucun processus pgbouncer)"
    echo ""
    
    echo "→ Test 4: Logs du conteneur pgbouncer (20 dernières lignes)"
    docker logs pgbouncer 2>&1 | tail -20 || echo "  (Pas de logs ou conteneur inexistant)"
    echo ""
    
    echo "→ Test 5: Inspection du conteneur"
    CONTAINER_ID=$(docker ps -a --filter name=^/pgbouncer$ -q | head -1)
    if [ -n "$CONTAINER_ID" ]; then
        echo "  Container ID: $CONTAINER_ID"
        docker inspect $CONTAINER_ID --format '  RestartCount: {{.RestartCount}}' 2>/dev/null || true
        docker inspect $CONTAINER_ID --format '  State: {{.State.Status}}' 2>/dev/null || true
        docker inspect $CONTAINER_ID --format '  Error: {{.State.Error}}' 2>/dev/null || true
        docker inspect $CONTAINER_ID --format '  ExitCode: {{.State.ExitCode}}' 2>/dev/null || true
    else
        echo "  Aucun conteneur pgbouncer trouvé"
    fi
DIAG
    
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ DIAGNOSTIC TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
