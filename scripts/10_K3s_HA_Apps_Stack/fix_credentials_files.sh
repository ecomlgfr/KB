#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    VÉRIFICATION & CRÉATION FICHIERS CREDENTIALS                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✅ OK\033[0m'
KO='\033[0;31m❌ KO\033[0m'
WARN='\033[0;33m⚠️ WARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

# Créer le répertoire s'il n'existe pas
if [ ! -d "$CREDENTIALS_DIR" ]; then
    echo -e "$WARN Création du répertoire $CREDENTIALS_DIR..."
    mkdir -p "$CREDENTIALS_DIR"
    chmod 700 "$CREDENTIALS_DIR"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. VÉRIFICATION FICHIER servers.tsv ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ ! -f "$SERVERS_TSV" ]; then
    echo -e "$KO servers.tsv introuvable : $SERVERS_TSV"
    echo ""
    echo "💡 Le fichier servers.tsv doit contenir les IP des serveurs"
    echo "   Format : hostname    TAB    nom    TAB    ip_privée"
    exit 1
else
    echo -e "$OK servers.tsv trouvé"
    echo "   Nombre de serveurs : $(wc -l < "$SERVERS_TSV")"
fi

# Fonction pour générer un mot de passe sécurisé
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. VÉRIFICATION postgres.env ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

POSTGRES_ENV="$CREDENTIALS_DIR/postgres.env"

if [ -f "$POSTGRES_ENV" ]; then
    echo -e "$OK postgres.env existe"
    
    # Vérifier les variables
    source "$POSTGRES_ENV" 2>/dev/null || true
    
    if [ -z "${POSTGRES_USER:-}" ]; then
        echo -e "$WARN POSTGRES_USER manquant"
        NEED_FIX_POSTGRES=true
    else
        echo "   POSTGRES_USER: $POSTGRES_USER"
    fi
    
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        echo -e "$WARN POSTGRES_PASSWORD manquant"
        NEED_FIX_POSTGRES=true
    else
        echo "   POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:0:4}***"
    fi
else
    echo -e "$KO postgres.env n'existe pas"
    NEED_FIX_POSTGRES=true
fi

if [ "${NEED_FIX_POSTGRES:-false}" = "true" ]; then
    echo ""
    echo "🔧 Création/correction de postgres.env..."
    
    # Demander les informations ou utiliser des valeurs par défaut
    echo ""
    read -p "Nom d'utilisateur PostgreSQL [postgres] : " INPUT_POSTGRES_USER
    POSTGRES_USER=${INPUT_POSTGRES_USER:-postgres}
    
    echo ""
    read -sp "Mot de passe PostgreSQL [générer aléatoire] : " INPUT_POSTGRES_PASSWORD
    echo ""
    
    if [ -z "$INPUT_POSTGRES_PASSWORD" ]; then
        POSTGRES_PASSWORD=$(generate_password)
        echo "   → Mot de passe généré automatiquement"
    else
        POSTGRES_PASSWORD="$INPUT_POSTGRES_PASSWORD"
    fi
    
    # Créer le fichier
    cat > "$POSTGRES_ENV" <<EOF
# Credentials PostgreSQL - Généré le $(date)
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=postgres
POSTGRES_HOST=10.0.0.10
POSTGRES_PORT=5432
EOF
    
    chmod 600 "$POSTGRES_ENV"
    echo -e "$OK postgres.env créé/mis à jour"
    echo "   POSTGRES_USER: $POSTGRES_USER"
    echo "   POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:0:4}***"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. VÉRIFICATION redis.env ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

REDIS_ENV="$CREDENTIALS_DIR/redis.env"

if [ -f "$REDIS_ENV" ]; then
    echo -e "$OK redis.env existe"
    source "$REDIS_ENV" 2>/dev/null || true
    
    if [ -z "${REDIS_PASSWORD:-}" ]; then
        echo -e "$WARN REDIS_PASSWORD manquant"
        NEED_FIX_REDIS=true
    else
        echo "   REDIS_PASSWORD: ${REDIS_PASSWORD:0:4}***"
    fi
else
    echo -e "$KO redis.env n'existe pas"
    NEED_FIX_REDIS=true
fi

if [ "${NEED_FIX_REDIS:-false}" = "true" ]; then
    echo ""
    echo "🔧 Création/correction de redis.env..."
    
    REDIS_PASSWORD=$(generate_password)
    
    cat > "$REDIS_ENV" <<EOF
# Credentials Redis - Généré le $(date)
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_HOST=10.0.0.10
REDIS_PORT=6379
EOF
    
    chmod 600 "$REDIS_ENV"
    echo -e "$OK redis.env créé"
    echo "   REDIS_PASSWORD: ${REDIS_PASSWORD:0:4}***"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. VÉRIFICATION rabbitmq.env ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

RABBITMQ_ENV="$CREDENTIALS_DIR/rabbitmq.env"

if [ -f "$RABBITMQ_ENV" ]; then
    echo -e "$OK rabbitmq.env existe"
    source "$RABBITMQ_ENV" 2>/dev/null || true
    
    if [ -z "${RABBITMQ_USER:-}" ] || [ -z "${RABBITMQ_PASSWORD:-}" ]; then
        echo -e "$WARN Credentials RabbitMQ manquants"
        NEED_FIX_RABBITMQ=true
    else
        echo "   RABBITMQ_USER: $RABBITMQ_USER"
        echo "   RABBITMQ_PASSWORD: ${RABBITMQ_PASSWORD:0:4}***"
    fi
else
    echo -e "$KO rabbitmq.env n'existe pas"
    NEED_FIX_RABBITMQ=true
fi

if [ "${NEED_FIX_RABBITMQ:-false}" = "true" ]; then
    echo ""
    echo "🔧 Création/correction de rabbitmq.env..."
    
    RABBITMQ_USER="admin"
    RABBITMQ_PASSWORD=$(generate_password)
    
    cat > "$RABBITMQ_ENV" <<EOF
# Credentials RabbitMQ - Généré le $(date)
RABBITMQ_USER=$RABBITMQ_USER
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
RABBITMQ_HOST=10.0.0.10
RABBITMQ_PORT=5672
RABBITMQ_MANAGEMENT_PORT=15672
EOF
    
    chmod 600 "$RABBITMQ_ENV"
    echo -e "$OK rabbitmq.env créé"
    echo "   RABBITMQ_USER: $RABBITMQ_USER"
    echo "   RABBITMQ_PASSWORD: ${RABBITMQ_PASSWORD:0:4}***"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. TEST CONNEXION POSTGRESQL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Recharger les credentials
source "$POSTGRES_ENV"

echo "🔍 Test de connexion PostgreSQL..."
echo "   Host: $POSTGRES_HOST"
echo "   Port: $POSTGRES_PORT"
echo "   User: $POSTGRES_USER"
echo ""

if ! command -v psql &>/dev/null; then
    echo -e "$WARN psql non installé, installation..."
    apt-get update -qq && apt-get install -y -qq postgresql-client
fi

if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -c "SELECT version();" &>/dev/null; then
    echo -e "$OK Connexion PostgreSQL réussie !"
    
    # Afficher la version
    PG_VERSION=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -tAc "SELECT version();" 2>/dev/null | head -1)
    echo "   Version: $PG_VERSION"
else
    echo -e "$KO Connexion PostgreSQL ÉCHOUÉE"
    echo ""
    echo "💡 Vérifications à faire :"
    echo "   1. PostgreSQL est-il démarré ?"
    echo "   2. Le Load Balancer 10.0.0.10 fonctionne-t-il ?"
    echo "   3. HAProxy route-t-il correctement le port 5432 ?"
    echo "   4. Le mot de passe est-il correct ?"
    echo ""
    echo "   Testez manuellement :"
    echo "   PGPASSWORD=\"$POSTGRES_PASSWORD\" psql -h 10.0.0.10 -p 5432 -U $POSTGRES_USER -d postgres"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. RÉCAPITULATIF DES FICHIERS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "📁 Fichiers de credentials :"
ls -lh "$CREDENTIALS_DIR"/*.env 2>/dev/null || echo "Aucun fichier .env trouvé"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. PROCHAINES ÉTAPES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -c "SELECT 1;" &>/dev/null; then
    echo -e "$OK Credentials PostgreSQL validés"
    echo ""
    echo "Vous pouvez maintenant :"
    echo "   1. Relancer la vérification : ./verif_rapide_sante.sh"
    echo "   2. Faire un diagnostic : ./diagnostic_complet_bdd_apps.sh"
    echo "   3. Réinitialiser les apps : ./reset_apps_bdd_complet.sh"
else
    echo -e "$KO Les credentials PostgreSQL ne fonctionnent pas"
    echo ""
    echo "Actions recommandées :"
    echo "   1. Vérifier que PostgreSQL est accessible"
    echo "   2. Vérifier les credentials dans Patroni/PostgreSQL"
    echo "   3. Consulter les logs HAProxy et PostgreSQL"
    echo ""
    echo "   Commandes utiles :"
    echo "   ssh root@10.0.0.11 'systemctl status haproxy'"
    echo "   ssh root@10.0.0.120 'systemctl status patroni'"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "Terminé : $(date)"
echo "════════════════════════════════════════════════════════════════════"
