#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              Vérification pgvector pour PostgreSQL 16             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Charger le mot de passe PostgreSQL
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

# Trouver le leader Patroni ou nœud PostgreSQL
PG_NODE=""
for node in db-master-01 db-slave-01 db-slave-02; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -n "$ip" ]; then
        if curl -s -m 2 "http://$ip:8008/health" 2>/dev/null | grep -q "running"; then
            PG_NODE="$ip"
            echo "  ✓ Nœud PostgreSQL détecté : $node ($ip)"
            break
        fi
    fi
done

if [ -z "$PG_NODE" ]; then
    PG_NODE=$(awk -F'\t' '$2 ~ /^db-/ {print $3; exit}' "$SERVERS_TSV")
fi

if [ -z "$PG_NODE" ]; then
    echo -e "$KO Impossible de trouver un nœud PostgreSQL"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Test pgvector sur $PG_NODE ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Script de vérification à exécuter sur le nœud PostgreSQL
ssh -o StrictHostKeyChecking=no root@"$PG_NODE" bash <<EOCHK
set -u
set -o pipefail

export PGPASSWORD='${POSTGRES_PASSWORD}'

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

echo "═══ 1. Vérification système ═══"
echo ""

# Détecter la version PostgreSQL
PG_VERSION=\$(psql -U postgres -h localhost -t -c "SHOW server_version;" 2>/dev/null | grep -oE '[0-9]+' | head -n1)

if [ -z "\$PG_VERSION" ]; then
    echo -e "  \$KO Impossible de détecter la version PostgreSQL"
    exit 1
fi

echo -e "  \$INFO PostgreSQL version : \$PG_VERSION"

# Vérifier si pgvector est installé (package système)
echo -n "  → Package pgvector installé ... "
if dpkg -l | grep -q "postgresql-\${PG_VERSION}-pgvector"; then
    echo -e "\$OK"
    PGVECTOR_VERSION=\$(dpkg -l | grep "postgresql-\${PG_VERSION}-pgvector" | awk '{print \$3}')
    echo -e "    Version : \$PGVECTOR_VERSION"
else
    echo -e "\$KO"
    echo ""
    echo -e "  \$WARN pgvector n'est pas installé au niveau système"
    echo ""
    echo "  Installation nécessaire :"
    echo "    apt update"
    echo "    apt install -y postgresql-\${PG_VERSION}-pgvector"
    echo ""
    read -p "  Installer maintenant ? (yes/NO) : " install_now
    
    if [ "\$install_now" = "yes" ]; then
        echo ""
        echo "  Installation en cours..."
        apt update -qq >/dev/null 2>&1
        if apt install -y postgresql-\${PG_VERSION}-pgvector; then
            echo -e "  \$OK pgvector installé"
        else
            echo -e "  \$KO Échec de l'installation"
            echo ""
            echo "  Tentative alternative (depuis sources PostgreSQL) :"
            echo "    apt install -y postgresql-server-dev-\${PG_VERSION} build-essential git"
            echo "    git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git /tmp/pgvector"
            echo "    cd /tmp/pgvector && make && make install"
            exit 1
        fi
    else
        echo ""
        echo -e "  \$KO Installation abandonnée"
        exit 1
    fi
fi

echo ""
echo "═══ 2. Test extension PostgreSQL ═══"
echo ""

# Fonction pour tester la connexion
test_psql() {
    if docker ps 2>/dev/null | grep -q postgres; then
        PG_CONTAINER=\$(docker ps | grep postgres | awk '{print \$1}' | head -n1)
        docker exec -e PGPASSWORD="\$PGPASSWORD" \$PG_CONTAINER psql -U postgres "\$@"
        return \$?
    else
        psql -U postgres -h localhost "\$@"
        return \$?
    fi
}

# Tester la disponibilité de l'extension
echo -n "  → Extension disponible dans PostgreSQL ... "
if test_psql -c "SELECT * FROM pg_available_extensions WHERE name = 'vector';" 2>/dev/null | grep -q vector; then
    echo -e "\$OK"
else
    echo -e "\$KO"
    echo ""
    echo -e "  \$WARN L'extension n'est pas détectée par PostgreSQL"
    echo ""
    echo "  Actions à faire :"
    echo "    1. Redémarrer PostgreSQL : systemctl restart postgresql"
    echo "    2. Ou via Patroni : patronictl restart postgres"
    echo ""
    exit 1
fi

# Tester la création de l'extension dans la base postgres
echo -n "  → Création de l'extension ... "
if test_psql -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null >/dev/null; then
    echo -e "\$OK"
else
    echo -e "\$KO"
    exit 1
fi

# Vérifier la version
VECTOR_VERSION=\$(test_psql -t -c "SELECT extversion FROM pg_extension WHERE extname = 'vector';" 2>/dev/null | tr -d ' ')
if [ -n "\$VECTOR_VERSION" ]; then
    echo -e "    Version active : \$VECTOR_VERSION"
else
    echo -e "  \$WARN Impossible de récupérer la version"
fi

echo ""
echo "═══ 3. Test fonctionnel ═══"
echo ""

# Créer une table de test avec vector
echo -n "  → Création table avec vector ... "
if test_psql <<'SQLTEST' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS pgvector_test (
    id SERIAL PRIMARY KEY,
    embedding vector(3)
);
SQLTEST
then
    echo -e "\$OK"
else
    echo -e "\$KO"
    exit 1
fi

# Insérer des données
echo -n "  → Insertion données vectorielles ... "
if test_psql <<'SQLTEST' >/dev/null 2>&1
INSERT INTO pgvector_test (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');
SQLTEST
then
    echo -e "\$OK"
else
    echo -e "\$KO"
    exit 1
fi

# Test recherche par similarité
echo -n "  → Recherche par similarité (cosine) ... "
if test_psql <<'SQLTEST' >/dev/null 2>&1
SELECT id, embedding <=> '[3,1,2]' AS distance 
FROM pgvector_test 
ORDER BY embedding <=> '[3,1,2]' 
LIMIT 1;
SQLTEST
then
    echo -e "\$OK"
else
    echo -e "\$KO"
    exit 1
fi

# Nettoyer
test_psql -c "DROP TABLE IF EXISTS pgvector_test;" >/dev/null 2>&1

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "\$OK pgvector est FONCTIONNEL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Informations :"
echo "  PostgreSQL    : \$PG_VERSION"
echo "  pgvector      : \$VECTOR_VERSION"
echo "  Opérateurs    : <=> (cosine), <-> (L2), <#> (inner product)"
echo ""
echo "✅ Vous pouvez lancer ./02_prepare_database.sh en toute sécurité"
echo ""

exit 0
EOCHK

if [ $? -eq 0 ]; then
    echo ""
    echo -e "$OK Vérification terminée avec succès"
    echo ""
    echo "Prochaine étape :"
    echo "  ./02_prepare_database.sh"
    echo ""
    exit 0
else
    echo ""
    echo -e "$KO Vérification échouée"
    echo ""
    echo "Actions possibles :"
    echo "  1. Installer manuellement :"
    echo "     ssh root@$PG_NODE"
    echo "     apt update && apt install -y postgresql-16-pgvector"
    echo "     systemctl restart postgresql"
    echo ""
    echo "  2. Continuer sans pgvector (fonctionnalités AI limitées)"
    echo ""
    exit 1
fi
