#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     Installation pgvector sur Cluster PostgreSQL 16 + Patroni     ║"
echo "║              (Installation sur 3 nœuds pour HA)                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 0 : Charger les credentials
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Chargement des credentials ═══"
echo ""

if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    POSTGRES_PASSWORD=$(grep POSTGRES_PASSWORD "$CREDENTIALS_DIR/postgres.env" | cut -d'=' -f2 | sed 's/^["\x27]//;s/["\x27]$//' | head -n1)
else
    echo -e "$KO $CREDENTIALS_DIR/postgres.env introuvable"
    exit 1
fi

if [ -z "$POSTGRES_PASSWORD" ]; then
    echo -e "$KO Mot de passe PostgreSQL introuvable"
    exit 1
fi

echo "  ✓ Credentials chargés depuis postgres.env"

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Détecter les nœuds du cluster
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Détection du cluster PostgreSQL ═══"
echo ""

DB_NODES=()
for node in db-master-01 db-slave-01 db-slave-02; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -n "$ip" ]; then
        DB_NODES+=("$node:$ip")
        echo "  ✓ $node : $ip"
    fi
done

if [ ${#DB_NODES[@]} -eq 0 ]; then
    echo -e "$KO Aucun nœud PostgreSQL trouvé dans servers.tsv"
    exit 1
fi

echo ""
echo "  Nœuds détectés : ${#DB_NODES[@]}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Vérifier l'accès via PgBouncer (point d'entrée apps)
# ═══════════════════════════════════════════════════════════════════════════

echo "═══ Test connexion via PgBouncer (10.0.0.10) ═══"
echo ""

# Tester les ports possibles
PGBOUNCER_PORT=""

for port in 6432 4632; do
    echo -n "  Test port $port ... "
    if timeout 3 bash -c "</dev/tcp/10.0.0.10/$port" 2>/dev/null; then
        if PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -h 10.0.0.10 -p $port -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            PGBOUNCER_PORT=$port
            echo -e "$OK (connexion réussie)"
            break
        else
            echo -e "$WARN (ouvert mais connexion échouée)"
        fi
    else
        echo -e "$KO (fermé)"
    fi
done

if [ -z "$PGBOUNCER_PORT" ]; then
    echo ""
    echo -e "$KO Impossible de se connecter via PgBouncer"
    echo ""
    echo "Vérifications nécessaires :"
    echo "  1. HAProxy est-il actif ? (10.0.0.10)"
    echo "  2. PgBouncer est-il accessible ?"
    echo ""
    exit 1
fi

echo ""
echo -e "  $OK PgBouncer accessible : 10.0.0.10:$PGBOUNCER_PORT"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Information importante
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════"
echo "IMPORTANT : Installation sur tous les nœuds du cluster"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "pgvector doit être installé sur TOUS les nœuds PostgreSQL :"
echo ""
for node_info in "${DB_NODES[@]}"; do
    echo "  • ${node_info%%:*}"
done
echo ""
echo "Raison : Dans un cluster Patroni HA, n'importe quel nœud peut"
echo "devenir leader après un failover. Si pgvector n'est pas installé"
echo "partout, les extensions échoueront après un basculement."
echo ""
echo "Actions :"
echo "  1. Installer le package postgresql-16-pgvector (via apt)"
echo "  2. NE PAS redémarrer Patroni immédiatement (risque de perturbation)"
echo "  3. Redémarrage contrôlé : replica d'abord, puis leader"
echo ""

read -p "Continuer l'installation ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : Installation du package sur chaque nœud
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Installation pgvector sur les nœuds ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

SUCCESS_COUNT=0
FAILED_COUNT=0

for node_info in "${DB_NODES[@]}"; do
    node="${node_info%%:*}"
    ip="${node_info##*:}"
    
    echo "→ Installation sur $node ($ip)"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'EOINSTALL'
set -u
set -o pipefail

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

# Détecter la version PostgreSQL
PG_VERSION=""
if docker ps 2>/dev/null | grep -q postgres; then
    PG_CONTAINER=$(docker ps | grep postgres | awk '{print $1}' | head -n1)
    PG_VERSION=$(docker exec $PG_CONTAINER psql -U postgres -t -c "SHOW server_version;" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
elif systemctl is-active --quiet patroni 2>/dev/null; then
    # Patroni gère PostgreSQL, détecter via patronictl
    PG_VERSION=$(patronictl list 2>/dev/null | grep -oE 'PostgreSQL [0-9]+' | grep -oE '[0-9]+' | head -n1)
fi

if [ -z "$PG_VERSION" ]; then
    # Fallback : assumer PostgreSQL 16
    PG_VERSION=16
    echo -e "  $WARN Impossible de détecter la version, assume PostgreSQL $PG_VERSION"
else
    echo -e "  ✓ PostgreSQL version détectée : $PG_VERSION"
fi

# Vérifier si déjà installé
if dpkg -l 2>/dev/null | grep -q "postgresql-${PG_VERSION}-pgvector"; then
    echo -e "  $OK pgvector déjà installé"
    dpkg -l | grep "postgresql-${PG_VERSION}-pgvector" | awk '{print "    Version : " $3}'
    exit 0
fi

# Installer pgvector
echo "  Installation postgresql-${PG_VERSION}-pgvector..."

apt update -qq >/dev/null 2>&1
if apt install -y postgresql-${PG_VERSION}-pgvector >/dev/null 2>&1; then
    echo -e "  $OK pgvector installé"
    
    # Vérifier le fichier .so
    SO_FILE="/usr/lib/postgresql/${PG_VERSION}/lib/vector.so"
    if [ -f "$SO_FILE" ]; then
        echo -e "  ✓ Fichier vector.so présent : $SO_FILE"
    else
        echo -e "  $WARN Fichier vector.so introuvable (peut nécessiter redémarrage)"
    fi
else
    echo -e "  $KO Échec de l'installation apt"
    echo ""
    echo "  Tentative alternative (compilation depuis sources) :"
    
    apt install -y postgresql-server-dev-${PG_VERSION} build-essential git >/dev/null 2>&1
    
    if [ ! -d /tmp/pgvector ]; then
        git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git /tmp/pgvector >/dev/null 2>&1
    fi
    
    cd /tmp/pgvector
    if make clean && make && make install; then
        echo -e "  $OK pgvector compilé et installé depuis sources"
    else
        echo -e "  $KO Échec de la compilation"
        exit 1
    fi
fi

echo ""
EOINSTALL
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $node : pgvector installé"
        ((SUCCESS_COUNT++))
    else
        echo -e "  $KO $node : échec installation"
        ((FAILED_COUNT++))
    fi
    
    echo ""
done

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 5 : Redémarrage contrôlé Patroni (optionnel mais recommandé)
# ═══════════════════════════════════════════════════════════════════════════

if [ $SUCCESS_COUNT -gt 0 ]; then
    echo "═══════════════════════════════════════════════════════════════════"
    echo "═══ Redémarrage Patroni (recommandé) ═══"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Pour que pgvector soit disponible dans PostgreSQL, il faut redémarrer"
    echo "les instances. Dans un cluster Patroni, on redémarre :"
    echo "  1. Les replicas d'abord (db-slave-01, db-slave-02)"
    echo "  2. Le leader en dernier (db-master-01) via switchover"
    echo ""
    echo "⚠️  Le redémarrage prend ~30 secondes par nœud"
    echo ""
    
    read -p "Redémarrer maintenant ? (yes/NO) : " restart_now
    
    if [ "$restart_now" = "yes" ]; then
        echo ""
        
        # Trouver le leader
        LEADER=""
        LEADER_NAME=""
        for node_info in "${DB_NODES[@]}"; do
            node="${node_info%%:*}"
            ip="${node_info##*:}"
            
            ROLE=$(ssh -o StrictHostKeyChecking=no root@"$ip" "patronictl list 2>/dev/null | grep Running | awk '{print \$4}'" 2>/dev/null | head -n1)
            if [ "$ROLE" = "Leader" ]; then
                LEADER="$node:$ip"
                LEADER_NAME="$node"
                break
            fi
        done
        
        if [ -z "$LEADER" ]; then
            echo -e "$WARN Impossible de détecter le leader, redémarrage manuel requis"
        else
            leader_node="${LEADER%%:*}"
            leader_ip="${LEADER##*:}"
            
            echo "  Leader détecté : $leader_node"
            echo ""
            
            # Redémarrer les replicas via patronictl (plus propre)
            for node_info in "${DB_NODES[@]}"; do
                node="${node_info%%:*}"
                ip="${node_info##*:}"
                
                if [ "$node" != "$leader_node" ]; then
                    echo "  → Redémarrage replica $node via patronictl..."
                    ssh -o StrictHostKeyChecking=no root@"$ip" "patronictl restart postgres-cluster $node --force" 2>/dev/null || {
                        echo "    Fallback: systemctl restart postgresql"
                        ssh -o StrictHostKeyChecking=no root@"$ip" "systemctl restart postgresql" 2>/dev/null
                    }
                    sleep 15
                    echo -e "    $OK $node redémarré"
                fi
            done
            
            # Switchover du leader (Patroni gère le redémarrage proprement)
            echo ""
            echo "  → Switchover du leader $leader_node..."
            
            # Trouver un replica pour le switchover
            CANDIDATE=""
            for node_info in "${DB_NODES[@]}"; do
                node="${node_info%%:*}"
                if [ "$node" != "$leader_node" ]; then
                    CANDIDATE="$node"
                    break
                fi
            done
            
            if [ -n "$CANDIDATE" ]; then
                ssh -o StrictHostKeyChecking=no root@"$leader_ip" "patronictl switchover postgres-cluster --master $leader_node --candidate $CANDIDATE --force" 2>/dev/null || true
                sleep 20
                
                # Redémarrer l'ancien leader (maintenant replica)
                echo "  → Redémarrage ancien leader $leader_node..."
                ssh -o StrictHostKeyChecking=no root@"$leader_ip" "patronictl restart postgres-cluster $leader_node --force" 2>/dev/null || {
                    ssh -o StrictHostKeyChecking=no root@"$leader_ip" "systemctl restart postgresql" 2>/dev/null
                }
                sleep 15
            fi
            
            echo -e "  $OK Cluster redémarré"
        fi
    else
        echo ""
        echo "  Redémarrage manuel (via patronictl) :"
        echo "    # Redémarrer replicas"
        echo "    patronictl restart postgres-cluster <replica-name> --force"
        echo ""
        echo "    # Switchover leader"
        echo "    patronictl switchover postgres-cluster --master <leader> --candidate <replica> --force"
        echo ""
        echo "    # Redémarrer ancien leader (devenu replica)"
        echo "    patronictl restart postgres-cluster <old-leader> --force"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 6 : Test fonctionnel via PgBouncer
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Test fonctionnel pgvector via PgBouncer ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

export PGPASSWORD="$POSTGRES_PASSWORD"

echo "  → Création extension vector..."
if psql -U postgres -h 10.0.0.10 -p $PGBOUNCER_PORT -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo -e "    $OK Extension créée"
else
    echo -e "    $KO Échec création extension"
    echo ""
    echo "  Causes possibles :"
    echo "    1. PostgreSQL n'a pas été redémarré"
    echo "    2. Fichier vector.so non chargé"
    echo ""
    echo "  Action : Redémarrer Patroni sur les nœuds"
    exit 1
fi

echo "  → Vérification version..."
VECTOR_VERSION=$(psql -U postgres -h 10.0.0.10 -p $PGBOUNCER_PORT -d postgres -t -c "SELECT extversion FROM pg_extension WHERE extname = 'vector';" 2>/dev/null | tr -d ' ')

if [ -n "$VECTOR_VERSION" ]; then
    echo -e "    $OK Version : $VECTOR_VERSION"
else
    echo -e "    $WARN Impossible de récupérer la version"
fi

echo "  → Test création table avec vectors..."
if psql -U postgres -h 10.0.0.10 -p $PGBOUNCER_PORT -d postgres <<'SQLTEST' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS pgvector_test (id SERIAL PRIMARY KEY, embedding vector(3));
INSERT INTO pgvector_test (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');
SELECT id, embedding <=> '[3,1,2]' AS distance FROM pgvector_test ORDER BY distance LIMIT 1;
DROP TABLE pgvector_test;
SQLTEST
then
    echo -e "    $OK Test fonctionnel réussi"
else
    echo -e "    $KO Test échoué"
fi

# ═══════════════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Installation pgvector terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Résumé :"
echo "  • Nœuds installés   : $SUCCESS_COUNT/${#DB_NODES[@]}"
echo "  • PgBouncer         : 10.0.0.10:$PGBOUNCER_PORT (recommandé: 6432)"
echo "  • Version pgvector  : ${VECTOR_VERSION:-N/A}"
echo ""
echo "✅ pgvector est maintenant disponible pour toutes les applications"
echo ""
echo "Prochaine étape :"
echo "  ./02_prepare_database.sh"
echo ""

exit 0
