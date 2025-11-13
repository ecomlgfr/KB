#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        Création des bases de données PostgreSQL pour Apps         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

echo ""
echo "═══ Chargement des credentials ═══"
echo ""

# Charger postgres.env (contient export)
if [ ! -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "$KO $CREDENTIALS_DIR/postgres.env introuvable"
    exit 1
fi

# Source le fichier pour récupérer les variables
source "$CREDENTIALS_DIR/postgres.env"

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "$KO POSTGRES_PASSWORD non défini dans postgres.env"
    exit 1
fi

echo "  ✓ Mot de passe PostgreSQL chargé"
echo ""

echo "═══ Configuration ═══"
echo "  Load Balancer    : 10.0.0.10:5432 (Hetzner LB)"
echo "  Backend          : PostgreSQL/Patroni Cluster"
echo "                     - db-master-01 (10.0.0.120)"
echo "                     - db-slave-01  (10.0.0.121)"
echo "                     - db-slave-02  (10.0.0.122)"
echo "  User             : postgres"
echo "  Password         : ${POSTGRES_PASSWORD:0:10}***"
echo ""

echo "Bases de données à créer :"
echo "  1. n8n"
echo "  2. chatwoot"
echo "  3. litellm"
echo "  4. superset"
echo "  5. erpnext"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Installation client PostgreSQL si nécessaire ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if ! command -v psql &>/dev/null; then
    echo "Installation de postgresql-client..."
    apt-get update -qq
    apt-get install -y postgresql-client -qq
    echo "  ✓ postgresql-client installé"
else
    echo "  ✓ postgresql-client déjà installé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Test de connexion au Load Balancer ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

export PGPASSWORD="$POSTGRES_PASSWORD"

echo "[$(date '+%F %T')] Test de connexion à 10.0.0.10..."

if ! psql -h 10.0.0.10 -U postgres -c "SELECT version();" >/dev/null 2>&1; then
    echo -e "$KO Impossible de se connecter à PostgreSQL via 10.0.0.10"
    echo ""
    echo "Vérifications à faire :"
    echo "  1. Le Load Balancer Hetzner est-il configuré ?"
    echo "  2. Le cluster Patroni est-il démarré ?"
    echo "  3. Le port 5432 est-il ouvert ?"
    echo ""
    echo "Test de connectivité :"
    nc -zv 10.0.0.10 5432 2>&1
    echo ""
    exit 1
fi

echo "  ✓ Connexion PostgreSQL OK via Load Balancer"
echo ""

# Afficher le nœud actuel (leader)
CURRENT_LEADER=$(psql -h 10.0.0.10 -U postgres -t -c "SELECT inet_server_addr();" 2>/dev/null | tr -d ' ')
echo "  → Connecté au nœud : $CURRENT_LEADER"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Création des bases de données ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "[$(date '+%F %T')] Création des bases de données..."
echo ""

# Fonction pour créer une base (ignore si existe)
create_db() {
    local dbname=$1
    echo -n "  Base $dbname... "
    
    # Vérifier si la base existe déjà
    if psql -h 10.0.0.10 -U postgres -lqt | cut -d \| -f 1 | grep -qw "$dbname"; then
        echo "existe déjà ✓"
    else
        # Créer la base
        if psql -h 10.0.0.10 -U postgres -c "CREATE DATABASE $dbname;" >/dev/null 2>&1; then
            echo "créée ✓"
        else
            echo "erreur ✗"
        fi
    fi
}

create_db "n8n"
create_db "chatwoot"
create_db "litellm"
create_db "superset"
create_db "erpnext"

echo ""
echo "[$(date '+%F %T')] Création des utilisateurs et permissions..."
echo ""

psql -h 10.0.0.10 -U postgres <<SQL

-- Créer les utilisateurs avec le mot de passe depuis postgres.env
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'n8n') THEN
        CREATE USER n8n WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User n8n created';
    ELSE
        ALTER USER n8n WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User n8n password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'chatwoot') THEN
        CREATE USER chatwoot WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User chatwoot created';
    ELSE
        ALTER USER chatwoot WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User chatwoot password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'litellm') THEN
        CREATE USER litellm WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User litellm created';
    ELSE
        ALTER USER litellm WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User litellm password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'superset') THEN
        CREATE USER superset WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User superset created';
    ELSE
        ALTER USER superset WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User superset password updated';
    END IF;
    
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'erpnext') THEN
        CREATE USER erpnext WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User erpnext created';
    ELSE
        ALTER USER erpnext WITH PASSWORD '$POSTGRES_PASSWORD';
        RAISE NOTICE 'User erpnext password updated';
    END IF;
END
\$\$;

-- Donner les permissions sur les bases
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE chatwoot TO chatwoot;
GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;
GRANT ALL PRIVILEGES ON DATABASE superset TO superset;
GRANT ALL PRIVILEGES ON DATABASE erpnext TO erpnext;

-- Pour PostgreSQL 15+, donner les permissions sur le schéma public
\c n8n
GRANT ALL ON SCHEMA public TO n8n;
GRANT ALL ON ALL TABLES IN SCHEMA public TO n8n;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO n8n;

\c chatwoot
GRANT ALL ON SCHEMA public TO chatwoot;
GRANT ALL ON ALL TABLES IN SCHEMA public TO chatwoot;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO chatwoot;

\c litellm
GRANT ALL ON SCHEMA public TO litellm;
GRANT ALL ON ALL TABLES IN SCHEMA public TO litellm;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO litellm;

\c superset
GRANT ALL ON SCHEMA public TO superset;
GRANT ALL ON ALL TABLES IN SCHEMA public TO superset;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO superset;

\c erpnext
GRANT ALL ON SCHEMA public TO erpnext;
GRANT ALL ON ALL TABLES IN SCHEMA public TO erpnext;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO erpnext;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO erpnext;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO erpnext;

\c postgres
SELECT 'All databases and users configured successfully!' AS status;
SQL

if [ $? -eq 0 ]; then
    echo ""
    echo "[$(date '+%F %T')] ✓ Utilisateurs et permissions créés avec succès"
    
    # Vérifier que les bases existent bien
    echo ""
    echo "[$(date '+%F %T')] Vérification finale..."
    if psql -h 10.0.0.10 -U postgres -lqt | cut -d \| -f 1 | grep -qw "n8n"; then
        echo "  ✓ Toutes les bases sont disponibles"
    else
        echo "  ⚠ Certaines bases manquent peut-être"
    fi
else
    echo ""
    echo "[$(date '+%F %T')] ✗ Erreur lors de la création des permissions"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "[$(date '+%F %T')] Bases de données créées :"
echo ""
psql -h 10.0.0.10 -U postgres -c "\l" | grep -E "n8n|chatwoot|litellm|superset|erpnext"

echo ""
echo "[$(date '+%F %T')] Utilisateurs créés :"
echo ""
psql -h 10.0.0.10 -U postgres -c "\du" | grep -E "n8n|chatwoot|litellm|superset|erpnext"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Bases de données créées via Load Balancer Hetzner"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Bases créées :"
echo "  ✓ n8n"
echo "  ✓ chatwoot"
echo "  ✓ litellm"
echo "  ✓ superset"
echo "  ✓ erpnext"
echo ""
echo "Utilisateurs créés (mot de passe depuis postgres.env) :"
echo "  ✓ n8n"
echo "  ✓ chatwoot"
echo "  ✓ litellm"
echo "  ✓ superset"
echo "  ✓ erpnext"
echo ""
echo "Les applications se connectent via :"
echo "  postgresql://<user>:<password>@10.0.0.10:5432/<database>"
echo ""
echo "Exemples :"
echo "  postgresql://n8n:$POSTGRES_PASSWORD@10.0.0.10:5432/n8n"
echo "  postgresql://chatwoot:$POSTGRES_PASSWORD@10.0.0.10:5432/chatwoot"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Prochaines étapes :"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "1. Corriger le secret Superset :"
echo "   ./fix_superset_secret.sh"
echo ""
echo "2. Redémarrer les déploiements K8s :"
echo "   ssh root@10.0.0.100 bash <<'EOF'"
echo "   kubectl rollout restart deployment/n8n -n n8n"
echo "   kubectl rollout restart deployment/chatwoot-web -n chatwoot"
echo "   kubectl rollout restart deployment/chatwoot-worker -n chatwoot"
echo "   kubectl rollout restart deployment/litellm -n litellm"
echo "   kubectl rollout restart deployment/superset -n superset"
echo "   EOF"
echo ""
echo "3. Attendre 2-3 minutes puis vérifier :"
echo "   ssh root@10.0.0.100 kubectl get pods -A"
echo ""
echo "4. Lancer les tests finaux :"
echo "   ./apps_final_tests.sh"
echo ""

exit 0
