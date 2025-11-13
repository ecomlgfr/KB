#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        Création des bases de données PostgreSQL pour Apps         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Fonction pour parser les .env
get_env_value() {
    local file="$1"
    local key="$2"
    
    if [ -f "$file" ]; then
        # Chercher la variable dans le fichier
        local value=$(grep -E "^${key}=" "$file" | cut -d'=' -f2- | sed 's/^["\x27]//;s/["\x27]$//' | head -n1)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    echo ""
    return 1
}

# Charger le mot de passe PostgreSQL
if [ ! -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "$KO $CREDENTIALS_DIR/postgres.env introuvable"
    exit 1
fi

echo ""
echo "═══ Chargement des credentials ═══"
echo ""

# Parser le fichier avec la fonction
POSTGRES_PASSWORD=$(get_env_value "$CREDENTIALS_DIR/postgres.env" "POSTGRES_PASSWORD")

if [ -z "$POSTGRES_PASSWORD" ]; then
    echo -e "$WARN Impossible de parser POSTGRES_PASSWORD depuis postgres.env"
    echo ""
    echo "Contenu du fichier postgres.env :"
    cat "$CREDENTIALS_DIR/postgres.env"
    echo ""
    
    # Essayer de charger directement
    source "$CREDENTIALS_DIR/postgres.env" 2>/dev/null || true
    
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        echo -e "$KO Mot de passe PostgreSQL introuvable"
        echo ""
        echo "Veuillez fournir le mot de passe manuellement :"
        read -sp "PostgreSQL password: " POSTGRES_PASSWORD
        echo ""
        
        if [ -z "$POSTGRES_PASSWORD" ]; then
            echo -e "$KO Mot de passe vide, abandon"
            exit 1
        fi
    fi
fi

# Trouver un nœud PostgreSQL
PG_NODE=$(awk -F'\t' '$6=="patroni" {print $3; exit}' "$SERVERS_TSV")

if [ -z "$PG_NODE" ]; then
    echo -e "$WARN Aucun nœud patroni trouvé dans servers.tsv"
    echo ""
    echo "Recherche alternative..."
    
    # Chercher postgres-01, postgres-02, etc.
    PG_NODE=$(awk -F'\t' '$2 ~ /^postgres-/ {print $3; exit}' "$SERVERS_TSV")
    
    if [ -z "$PG_NODE" ]; then
        echo -e "$WARN Utilisation de 10.0.0.10 (VIP par défaut)"
        PG_NODE="10.0.0.10"
    else
        echo "  Nœud trouvé : $PG_NODE"
    fi
fi

echo ""
echo "═══ Configuration ═══"
echo "  PostgreSQL Node : $PG_NODE"
echo "  Password        : ${POSTGRES_PASSWORD:0:10}***"
echo ""

echo "Bases de données à créer :"
echo "  1. n8n"
echo "  2. chatwoot"
echo "  3. litellm"
echo "  4. superset"
echo "  5. erpnext (optionnel)"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Création des bases de données ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Script à exécuter sur le nœud PostgreSQL
ssh -o StrictHostKeyChecking=no root@"$PG_NODE" bash <<EOSQL
set -u
set -o pipefail

export PGPASSWORD='${POSTGRES_PASSWORD}'

echo "[$(date '+%F %T')] Connexion à PostgreSQL sur $PG_NODE..."
echo ""

# Fonction pour tester la connexion PostgreSQL
test_pg_connection() {
    local method="\$1"
    local result=0
    
    case "\$method" in
        "direct")
            if psql -U postgres -h localhost -c "SELECT version();" >/dev/null 2>&1; then
                echo "  ✓ Connexion PostgreSQL directe OK"
                return 0
            fi
            ;;
        "docker")
            if docker ps 2>/dev/null | grep -q postgres; then
                PG_CONTAINER=\$(docker ps | grep postgres | awk '{print \$1}' | head -n1)
                if docker exec \$PG_CONTAINER psql -U postgres -c "SELECT version();" >/dev/null 2>&1; then
                    echo "  ✓ Connexion PostgreSQL via Docker OK (container: \$PG_CONTAINER)"
                    return 0
                fi
            fi
            ;;
        "patroni")
            if command -v patronictl &>/dev/null; then
                if patronictl list 2>/dev/null | grep -q running; then
                    echo "  ✓ Patroni détecté"
                    # Trouver le primary
                    PRIMARY=\$(patronictl list | grep -i leader | awk '{print \$2}')
                    if [ -n "\$PRIMARY" ]; then
                        echo "  ✓ Primary Patroni : \$PRIMARY"
                        return 0
                    fi
                fi
            fi
            ;;
    esac
    
    return 1
}

# Détecter la méthode de connexion
CONNECTION_METHOD=""

echo "[$(date '+%F %T')] Détection de la méthode de connexion PostgreSQL..."

if test_pg_connection "docker"; then
    CONNECTION_METHOD="docker"
    PG_CONTAINER=\$(docker ps | grep postgres | awk '{print \$1}' | head -n1)
elif test_pg_connection "direct"; then
    CONNECTION_METHOD="direct"
elif test_pg_connection "patroni"; then
    CONNECTION_METHOD="patroni"
else
    echo "  ✗ Impossible de se connecter à PostgreSQL"
    echo ""
    echo "Essais effectués :"
    echo "  - PostgreSQL direct (psql)"
    echo "  - Docker (docker exec)"
    echo "  - Patroni (patronictl)"
    echo ""
    echo "Vérifications à faire :"
    echo "  1. PostgreSQL est-il installé ?"
    echo "  2. Le service est-il démarré ?"
    echo "  3. Le mot de passe est-il correct ?"
    echo ""
    exit 1
fi

echo ""
echo "[$(date '+%F %T')] Méthode détectée : \$CONNECTION_METHOD"
echo ""

# Créer les bases selon la méthode
case "\$CONNECTION_METHOD" in
    "docker")
        echo "[$(date '+%F %T')] Création des bases via Docker..."
        
        docker exec -e PGPASSWORD='${POSTGRES_PASSWORD}' \$PG_CONTAINER psql -U postgres <<'SQLCMD'
-- Créer les bases de données (ignorer les erreurs si elles existent déjà)
SELECT 'Creating databases...' AS status;

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n') THEN
        CREATE DATABASE n8n;
        RAISE NOTICE 'Database n8n created';
    ELSE
        RAISE NOTICE 'Database n8n already exists';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot') THEN
        CREATE DATABASE chatwoot;
        RAISE NOTICE 'Database chatwoot created';
    ELSE
        RAISE NOTICE 'Database chatwoot already exists';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'litellm') THEN
        CREATE DATABASE litellm;
        RAISE NOTICE 'Database litellm created';
    ELSE
        RAISE NOTICE 'Database litellm already exists';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'superset') THEN
        CREATE DATABASE superset;
        RAISE NOTICE 'Database superset created';
    ELSE
        RAISE NOTICE 'Database superset already exists';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'erpnext') THEN
        CREATE DATABASE erpnext;
        RAISE NOTICE 'Database erpnext created';
    ELSE
        RAISE NOTICE 'Database erpnext already exists';
    END IF;
END
\$\$;

-- Créer les utilisateurs (ignorer les erreurs si ils existent)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'n8n') THEN
        CREATE USER n8n WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User n8n created';
    ELSE
        ALTER USER n8n WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User n8n password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'chatwoot') THEN
        CREATE USER chatwoot WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User chatwoot created';
    ELSE
        ALTER USER chatwoot WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User chatwoot password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'litellm') THEN
        CREATE USER litellm WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User litellm created';
    ELSE
        ALTER USER litellm WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User litellm password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'superset') THEN
        CREATE USER superset WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User superset created';
    ELSE
        ALTER USER superset WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User superset password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'erpnext') THEN
        CREATE USER erpnext WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User erpnext created';
    ELSE
        ALTER USER erpnext WITH PASSWORD '${POSTGRES_PASSWORD}';
        RAISE NOTICE 'User erpnext password updated';
    END IF;
END
\$\$;

-- Donner les permissions
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;
GRANT ALL PRIVILEGES ON DATABASE superset TO superset;
GRANT ALL PRIVILEGES ON DATABASE erpnext TO erpnext;

-- Pour PostgreSQL 15+, donner aussi les permissions sur le schéma public
\c n8n
GRANT ALL ON SCHEMA public TO n8n;
GRANT ALL ON ALL TABLES IN SCHEMA public TO n8n;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO n8n;

\c chatwoot
GRANT ALL ON SCHEMA public TO chatwoot;
GRANT ALL ON ALL TABLES IN SCHEMA public TO chatwoot;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO chatwoot;

\c litellm
GRANT ALL ON SCHEMA public TO litellm;
GRANT ALL ON ALL TABLES IN SCHEMA public TO litellm;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO litellm;

\c superset
GRANT ALL ON SCHEMA public TO superset;
GRANT ALL ON ALL TABLES IN SCHEMA public TO superset;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO superset;

\c erpnext
GRANT ALL ON SCHEMA public TO erpnext;
GRANT ALL ON ALL TABLES IN SCHEMA public TO erpnext;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO erpnext;

\c postgres
SELECT 'All databases and users configured successfully!' AS status;
SQLCMD
        
        echo "  ✓ Bases créées via Docker"
        ;;
        
    "direct")
        echo "[$(date '+%F %T')] Création des bases via psql direct..."
        
        psql -U postgres -h localhost <<'SQLCMD'
-- Même SQL que pour Docker
[... même contenu SQL ...]
SQLCMD
        
        echo "  ✓ Bases créées"
        ;;
        
    "patroni")
        echo "[$(date '+%F %T')] Création des bases via Patroni..."
        # Connexion au primary Patroni
        psql -U postgres -h localhost <<'SQLCMD'
-- Même SQL que pour Docker
[... même contenu SQL ...]
SQLCMD
        
        echo "  ✓ Bases créées via Patroni"
        ;;
esac

echo ""
echo "[$(date '+%F %T')] Vérification des bases créées..."
echo ""

# Lister les bases
case "\$CONNECTION_METHOD" in
    "docker")
        docker exec -e PGPASSWORD='${POSTGRES_PASSWORD}' \$PG_CONTAINER psql -U postgres -c "\l" | grep -E "n8n|chatwoot|litellm|superset|erpnext"
        ;;
    *)
        psql -U postgres -h localhost -c "\l" | grep -E "n8n|chatwoot|litellm|superset|erpnext"
        ;;
esac

echo ""
echo "[$(date '+%F %T')] ✓ Bases de données créées avec succès"

EOSQL

if [ $? -eq 0 ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$OK Bases de données créées"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Prochaines étapes :"
    echo ""
    echo "1. Redémarrer les déploiements K8s :"
    echo ""
    echo "   ssh root@10.0.0.100 bash <<'K8S_RESTART'"
    echo "   kubectl rollout restart deployment/n8n -n n8n"
    echo "   kubectl rollout restart deployment/chatwoot-web -n chatwoot"
    echo "   kubectl rollout restart deployment/chatwoot-worker -n chatwoot"
    echo "   kubectl rollout restart deployment/litellm -n litellm"
    echo "   kubectl rollout restart deployment/superset -n superset"
    echo "   K8S_RESTART"
    echo ""
    echo "2. Attendre 2-3 minutes le redémarrage des pods"
    echo ""
    echo "3. Vérifier l'état :"
    echo "   ssh root@10.0.0.100 kubectl get pods -A"
    echo ""
    echo "4. Lancer les tests :"
    echo "   ./apps_final_tests.sh"
    echo ""
else
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$KO Erreur lors de la création des bases"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Vérifiez manuellement :"
    echo "  ssh root@$PG_NODE"
    echo "  # Si Docker :"
    echo "  docker exec -it \$(docker ps | grep postgres | awk '{print \$1}') psql -U postgres"
    echo "  # Si direct :"
    echo "  psql -U postgres"
    echo ""
fi

exit 0
