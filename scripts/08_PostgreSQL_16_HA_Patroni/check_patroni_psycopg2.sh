#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           VÉRIFICATION VERSIONS PATRONI & PSYCOPG2                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

# IPs des nœuds DB
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE1_IP=$(awk -F'\t' '$2=="db-slave-01" {print $3}' "$SERVERS_TSV")
DB_SLAVE2_IP=$(awk -F'\t' '$2=="db-slave-02" {print $3}' "$SERVERS_TSV")

echo ""
echo "═══ Vérification sur les nœuds DB ═══"
echo ""

for NODE in "db-master-01:$DB_MASTER_IP" "db-slave-01:$DB_SLAVE1_IP" "db-slave-02:$DB_SLAVE2_IP"; do
    IFS=':' read -r NAME IP <<< "$NODE"
    
    echo "→ $NAME ($IP)"
    
    # Vérifier l'image Docker utilisée
    echo -n "  Image Docker: "
    IMAGE=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker inspect patroni --format='{{.Config.Image}}' 2>/dev/null" || echo "N/A")
    echo "$IMAGE"
    
    # Vérifier la version de Patroni
    echo -n "  Patroni version: "
    PATRONI_VERSION=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec patroni patroni --version 2>/dev/null" || echo "N/A")
    echo "$PATRONI_VERSION"
    
    # Vérifier la version de psycopg2
    echo -n "  psycopg2 version: "
    PSYCOPG2_VERSION=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec patroni python3 -c 'import psycopg2; print(psycopg2.__version__)' 2>/dev/null" || echo "N/A")
    echo "$PSYCOPG2_VERSION"
    
    # Vérifier si psycopg2-binary est installé
    echo -n "  psycopg2-binary: "
    PSYCOPG2_BINARY=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec patroni pip3 list 2>/dev/null | grep psycopg2" || echo "N/A")
    echo "$PSYCOPG2_BINARY"
    
    # Vérifier Python version
    echo -n "  Python version: "
    PYTHON_VERSION=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec patroni python3 --version 2>/dev/null" || echo "N/A")
    echo "$PYTHON_VERSION"
    
    # Vérifier PostgreSQL version
    echo -n "  PostgreSQL version: "
    PG_VERSION=$(ssh -o StrictHostKeyChecking=no root@"$IP" "docker exec postgres psql -U postgres -t -c 'SELECT version()' 2>/dev/null | head -1 | awk '{print \$2}'" || echo "N/A")
    echo "$PG_VERSION"
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📋 ANALYSE:"
echo ""
echo "  psycopg2 est la bibliothèque Python utilisée par Patroni pour"
echo "  communiquer avec PostgreSQL."
echo ""
echo "  Versions recommandées:"
echo "    • psycopg2 >= 2.9.0 (support SCRAM-SHA-256 natif)"
echo "    • psycopg2 >= 3.0.0 (psycopg3, async natif)"
echo ""
echo "  Si psycopg2 < 2.9, Patroni peut avoir des problèmes avec"
echo "  SCRAM-SHA-256 authentification."
echo ""
echo "═══════════════════════════════════════════════════════════════════"
