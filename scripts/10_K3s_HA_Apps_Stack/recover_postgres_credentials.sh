#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    RÉCUPÉRATION CREDENTIALS POSTGRESQL DEPUIS PATRONI             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✅ OK\033[0m'
KO='\033[0;31m❌ KO\033[0m'
WARN='\033[0;33m⚠️ WARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

if [ ! -f "$SERVERS_TSV" ]; then
    echo -e "$KO servers.tsv introuvable"
    exit 1
fi

mkdir -p "$CREDENTIALS_DIR"
chmod 700 "$CREDENTIALS_DIR"

# Récupérer l'IP du master DB
IP_DB_MASTER=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
IP_HAPROXY01=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
IP_HAPROXY02=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

if [ -z "$IP_DB_MASTER" ]; then
    echo -e "$KO IP db-master-01 introuvable dans servers.tsv"
    exit 1
fi

echo ""
echo "🎯 Serveurs cibles :"
echo "   • DB Master  : $IP_DB_MASTER"
echo "   • HAProxy 01 : $IP_HAPROXY01"
echo "   • HAProxy 02 : $IP_HAPROXY02"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. RECHERCHE CREDENTIALS DANS PATRONI ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Connexion à db-master-01 ($IP_DB_MASTER)..."

# Essayer de récupérer les credentials depuis la config Patroni
PATRONI_CONFIG=$(ssh -o StrictHostKeyChecking=no root@"$IP_DB_MASTER" "cat /etc/patroni/patroni.yml 2>/dev/null" || echo "")

if [ -z "$PATRONI_CONFIG" ]; then
    echo -e "$KO Impossible de lire /etc/patroni/patroni.yml"
    echo "   Patroni n'est peut-être pas installé ou configuré"
else
    echo -e "$OK Config Patroni récupérée"
    
    # Extraire le username
    POSTGRES_USER=$(echo "$PATRONI_CONFIG" | grep -A10 "^postgresql:" | grep "username:" | head -1 | awk '{print $2}' | tr -d "'\"")
    
    # Extraire le password
    POSTGRES_PASSWORD=$(echo "$PATRONI_CONFIG" | grep -A10 "^postgresql:" | grep "password:" | head -1 | awk '{print $2}' | tr -d "'\"")
    
    if [ -n "$POSTGRES_USER" ] && [ -n "$POSTGRES_PASSWORD" ]; then
        echo -e "$OK Credentials trouvés dans Patroni !"
        echo "   Username: $POSTGRES_USER"
        echo "   Password: ${POSTGRES_PASSWORD:0:4}***"
    else
        echo -e "$WARN Credentials non trouvés dans /etc/patroni/patroni.yml"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. RECHERCHE CREDENTIALS DANS VARIABLES D'ENVIRONNEMENT ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -z "${POSTGRES_USER:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo "🔍 Recherche dans les variables d'environnement PostgreSQL..."
    
    ENV_VARS=$(ssh -o StrictHostKeyChecking=no root@"$IP_DB_MASTER" "cat /etc/environment 2>/dev/null | grep POSTGRES" || echo "")
    
    if [ -n "$ENV_VARS" ]; then
        echo -e "$OK Variables trouvées :"
        echo "$ENV_VARS"
        
        # Extraire les valeurs
        if [ -z "${POSTGRES_USER:-}" ]; then
            POSTGRES_USER=$(echo "$ENV_VARS" | grep POSTGRES_USER | cut -d= -f2 | tr -d "'\"")
        fi
        
        if [ -z "${POSTGRES_PASSWORD:-}" ]; then
            POSTGRES_PASSWORD=$(echo "$ENV_VARS" | grep POSTGRES_PASSWORD | cut -d= -f2 | tr -d "'\"")
        fi
    else
        echo -e "$WARN Aucune variable POSTGRES trouvée dans /etc/environment"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. RECHERCHE DANS LES SCRIPTS D'INSTALLATION ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -z "${POSTGRES_USER:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo "🔍 Recherche dans les scripts d'installation..."
    
    SCRIPT_DIR="/opt/keybuzz-installer/scripts"
    if [ -d "$SCRIPT_DIR" ]; then
        # Chercher dans les scripts Postgres
        PASSWORD_FROM_SCRIPT=$(grep -h "POSTGRES_PASSWORD=" "$SCRIPT_DIR"/*.sh 2>/dev/null | grep -v "^#" | head -1 | cut -d= -f2 | tr -d "'\"")
        USER_FROM_SCRIPT=$(grep -h "POSTGRES_USER=" "$SCRIPT_DIR"/*.sh 2>/dev/null | grep -v "^#" | head -1 | cut -d= -f2 | tr -d "'\"")
        
        if [ -n "$PASSWORD_FROM_SCRIPT" ]; then
            echo -e "$OK Mot de passe trouvé dans les scripts"
            if [ -z "${POSTGRES_PASSWORD:-}" ]; then
                POSTGRES_PASSWORD="$PASSWORD_FROM_SCRIPT"
            fi
        fi
        
        if [ -n "$USER_FROM_SCRIPT" ]; then
            echo -e "$OK Utilisateur trouvé dans les scripts"
            if [ -z "${POSTGRES_USER:-}" ]; then
                POSTGRES_USER="$USER_FROM_SCRIPT"
            fi
        fi
    else
        echo -e "$WARN Répertoire scripts non trouvé : $SCRIPT_DIR"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. RÉSUMÉ DES CREDENTIALS TROUVÉS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -n "${POSTGRES_USER:-}" ] && [ -n "${POSTGRES_PASSWORD:-}" ]; then
    echo -e "$OK Credentials PostgreSQL récupérés !"
    echo "   Username: $POSTGRES_USER"
    echo "   Password: ${POSTGRES_PASSWORD:0:4}***"
    echo ""
    
    # Test de connexion
    echo "🔍 Test de connexion..."
    
    if ! command -v psql &>/dev/null; then
        echo -e "$WARN psql non installé, installation..."
        apt-get update -qq && apt-get install -y -qq postgresql-client
    fi
    
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U "$POSTGRES_USER" -d postgres -c "SELECT version();" &>/dev/null; then
        echo -e "$OK Connexion PostgreSQL réussie !"
        
        PG_VERSION=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.10 -p 5432 -U "$POSTGRES_USER" -d postgres -tAc "SELECT version();" | head -1)
        echo "   Version: $PG_VERSION"
    else
        echo -e "$KO Connexion PostgreSQL ÉCHOUÉE"
        echo "   Les credentials trouvés ne semblent pas fonctionner"
        echo ""
        echo "💡 Vérifications :"
        echo "   1. PostgreSQL est-il démarré ?"
        echo "   2. Le Load Balancer 10.0.0.10 fonctionne-t-il ?"
        echo "   3. Les credentials sont-ils corrects ?"
    fi
else
    echo -e "$KO Impossible de récupérer les credentials PostgreSQL"
    echo ""
    echo "💡 Solutions :"
    echo "   1. Vérifier manuellement la config Patroni :"
    echo "      ssh root@$IP_DB_MASTER 'cat /etc/patroni/patroni.yml'"
    echo ""
    echo "   2. Chercher dans les logs d'installation"
    echo ""
    echo "   3. Créer de nouveaux credentials :"
    echo "      ./fix_credentials_files.sh"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. CRÉATION FICHIER postgres.env ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

POSTGRES_ENV="$CREDENTIALS_DIR/postgres.env"

read -p "Créer/écraser le fichier postgres.env avec ces credentials ? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cat > "$POSTGRES_ENV" <<EOF
# Credentials PostgreSQL - Récupérés depuis Patroni le $(date)
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=postgres
POSTGRES_HOST=10.0.0.10
POSTGRES_PORT=5432
EOF
    
    chmod 600 "$POSTGRES_ENV"
    echo -e "$OK postgres.env créé : $POSTGRES_ENV"
    echo ""
    echo "Contenu :"
    cat "$POSTGRES_ENV"
else
    echo "Fichier non créé."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "═══ PROCHAINES ÉTAPES ═══"
echo "════════════════════════════════════════════════════════════════════"
echo ""

if [ -f "$POSTGRES_ENV" ]; then
    echo -e "$OK Fichier postgres.env prêt !"
    echo ""
    echo "Vous pouvez maintenant :"
    echo "   1. Vérifier l'état : ./verif_rapide_sante.sh"
    echo "   2. Diagnostic complet : ./diagnostic_complet_bdd_apps.sh"
    echo "   3. Réinitialiser les apps : ./reset_apps_bdd_complet.sh"
else
    echo -e "$WARN Fichier postgres.env non créé"
    echo ""
    echo "Exécutez manuellement :"
    echo "   ./fix_credentials_files.sh"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
