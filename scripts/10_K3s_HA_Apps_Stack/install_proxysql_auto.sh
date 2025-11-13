#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# INSTALLATION PROXYSQL - KeyBuzz Standards (NON-INTERACTIVE)
###############################################################################
# Auteur: Claude AI Assistant
# Date: 2025-11-13
# Version: 2.1 (Automated)
#
# Description:
#   Installation automatique de ProxySQL
#   Mode non-interactif pour orchestration depuis install-01
#
# Usage:
#   ENV_FILE=/path/to/.env NODE_NAME=PROXY01 ./install_proxysql_auto.sh
###############################################################################

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

###############################################################################
# LOAD CONFIGURATION
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.mariadb_proxysql_erpnext}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERREUR: Fichier $ENV_FILE introuvable!"
    exit 1
fi

# Load environment
set -a
source "$ENV_FILE"
set +a

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "${KO} ERREUR: $1"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Ce script doit être exécuté en tant que root"
    fi
}

###############################################################################
# DETECT NODE
###############################################################################

detect_node() {
    local ip=$(hostname -I | awk '{print $1}')

    # Si NODE_NAME est passé en variable d'environnement
    if [[ -n "${NODE_NAME:-}" ]]; then
        log "${INFO} Node forcé: $NODE_NAME"
        case "$NODE_NAME" in
            PROXY01) NODE_IP="$PROXY01_IP" ;;
            PROXY02) NODE_IP="$PROXY02_IP" ;;
            *) error_exit "NODE_NAME invalide: $NODE_NAME" ;;
        esac
        return 0
    fi

    # Sinon, détecter automatiquement
    if [[ "$ip" == "$PROXY01_IP" ]]; then
        NODE_NAME="PROXY01"
        NODE_IP="$PROXY01_IP"
    elif [[ "$ip" == "$PROXY02_IP" ]]; then
        NODE_NAME="PROXY02"
        NODE_IP="$PROXY02_IP"
    else
        error_exit "IP actuelle ($ip) ne correspond à aucun noeud ProxySQL"
    fi

    log "${OK} Noeud détecté: $NODE_NAME ($NODE_IP)"
}

###############################################################################
# CONFIGURE UFW
###############################################################################

configure_ufw() {
    log "${INFO} Configuration du pare-feu UFW..."

    if ! command -v ufw &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ufw
    fi

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Ports ProxySQL
    ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
    ufw allow "$PROXYSQL_MYSQL_PORT/tcp" comment "ProxySQL MySQL" >/dev/null 2>&1
    ufw allow "$PROXYSQL_ADMIN_PORT/tcp" comment "ProxySQL Admin" >/dev/null 2>&1

    # Réseau privé
    ufw allow from 10.0.0.0/16 comment "Hetzner Private Network" >/dev/null 2>&1

    ufw --force enable

    log "${OK} UFW configuré"
}

###############################################################################
# INSTALL PROXYSQL
###############################################################################

install_proxysql() {
    log "${INFO} Installation de ProxySQL $PROXYSQL_VERSION..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq lsb-release wget gnupg2 mysql-client

    wget -qO - 'https://repo.proxysql.com/ProxySQL/proxysql-2.5.x/repo_pub_key' | apt-key add -

    echo "deb https://repo.proxysql.com/ProxySQL/proxysql-2.5.x/$(lsb_release -sc)/ ./" | \
        tee /etc/apt/sources.list.d/proxysql.list >/dev/null

    apt-get update -qq
    apt-get install -y -qq proxysql

    systemctl stop proxysql || true

    log "${OK} ProxySQL installé"
}

###############################################################################
# CONFIGURE PROXYSQL
###############################################################################

configure_proxysql() {
    log "${INFO} Configuration de ProxySQL..."

    # Backup config
    if [[ -f /etc/proxysql.cnf ]]; then
        cp /etc/proxysql.cnf /etc/proxysql.cnf.bak.$(date +%Y%m%d_%H%M%S)
    fi

    # Création de la configuration
    cat > /etc/proxysql.cnf <<EOF
# ProxySQL Configuration - $NODE_NAME
# Generated: $(date)

datadir="/var/lib/proxysql"

admin_variables=
{
    admin_credentials="$PROXYSQL_ADMIN_USER:$PROXYSQL_ADMIN_PASSWORD"
    mysql_ifaces="0.0.0.0:$PROXYSQL_ADMIN_PORT"
    refresh_interval=2000
}

mysql_variables=
{
    threads=4
    max_connections=2048
    default_query_delay=0
    default_query_timeout=36000000
    interfaces="0.0.0.0:$PROXYSQL_MYSQL_PORT"
    default_schema="information_schema"
    server_version="8.0.30"
    connect_timeout_server=3000
    monitor_username="$PROXYSQL_MONITOR_USER"
    monitor_password="$PROXYSQL_MONITOR_PASSWORD"
    monitor_history=600000
    monitor_connect_interval=60000
    monitor_ping_interval=10000
    monitor_read_only_interval=1500
    ping_interval_server_msec=120000
    commands_stats=true
    sessions_sort=true
    connect_retries_on_failure=10
}

# MySQL Servers (backends MariaDB Galera)
mysql_servers=
(
    {
        address="$DB01_IP"
        port=3306
        hostgroup=$WRITER_HOSTGROUP
        max_connections=500
        comment="DB01 - Writer"
    },
    {
        address="$DB01_IP"
        port=3306
        hostgroup=$READER_HOSTGROUP
        max_connections=1000
        comment="DB01 - Reader"
    },
    {
        address="$DB02_IP"
        port=3306
        hostgroup=$WRITER_HOSTGROUP
        max_connections=500
        comment="DB02 - Writer"
    },
    {
        address="$DB02_IP"
        port=3306
        hostgroup=$READER_HOSTGROUP
        max_connections=1000
        comment="DB02 - Reader"
    },
    {
        address="$DB03_IP"
        port=3306
        hostgroup=$WRITER_HOSTGROUP
        max_connections=500
        comment="DB03 - Writer"
    },
    {
        address="$DB03_IP"
        port=3306
        hostgroup=$READER_HOSTGROUP
        max_connections=1000
        comment="DB03 - Reader"
    }
)

# MySQL Users
mysql_users=
(
    {
        username="$ERPNEXT_DB_USER"
        password="$ERPNEXT_DB_PASSWORD"
        default_hostgroup=$WRITER_HOSTGROUP
        max_connections=200
        active=1
        comment="ERPNext Application User"
    }
)

# Query Rules (read/write split)
mysql_query_rules=
(
    {
        rule_id=100
        active=1
        match_pattern="^SELECT.*FOR UPDATE"
        destination_hostgroup=$WRITER_HOSTGROUP
        apply=1
    },
    {
        rule_id=200
        active=1
        match_pattern="^SELECT"
        destination_hostgroup=$READER_HOSTGROUP
        apply=1
    },
    {
        rule_id=300
        active=1
        match_pattern=".*"
        destination_hostgroup=$WRITER_HOSTGROUP
        apply=1
    }
)

# Galera Hostgroups
mysql_galera_hostgroups=
(
    {
        writer_hostgroup=$WRITER_HOSTGROUP
        backup_writer_hostgroup=$WRITER_HOSTGROUP
        reader_hostgroup=$READER_HOSTGROUP
        offline_hostgroup=$OFFLINE_HOSTGROUP
        max_writers=3
        writer_is_also_reader=1
        max_transactions_behind=30
        active=1
    }
)
EOF

    log "${OK} Configuration ProxySQL créée"
}

###############################################################################
# START PROXYSQL
###############################################################################

start_proxysql() {
    log "${INFO} Démarrage de ProxySQL..."

    # Nettoyage
    rm -f /var/lib/proxysql/proxysql.db

    systemctl enable proxysql
    systemctl restart proxysql

    # Attendre que ProxySQL soit prêt
    for i in {1..30}; do
        if mysql -h 127.0.0.1 -P "$PROXYSQL_ADMIN_PORT" -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \
            -e "SELECT 1" &>/dev/null; then
            log "${OK} ProxySQL démarré"
            return 0
        fi
        sleep 1
    done

    error_exit "ProxySQL n'a pas démarré correctement"
}

###############################################################################
# LOAD CONFIG TO RUNTIME
###############################################################################

load_config_to_runtime() {
    log "${INFO} Chargement de la configuration dans le runtime..."

    mysql -h 127.0.0.1 -P "$PROXYSQL_ADMIN_PORT" -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" <<EOF
LOAD MYSQL SERVERS FROM CONFIG;
LOAD MYSQL USERS FROM CONFIG;
LOAD MYSQL QUERY RULES FROM CONFIG;
LOAD MYSQL VARIABLES FROM CONFIG;
LOAD ADMIN VARIABLES FROM CONFIG;

LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL USERS TO RUNTIME;
LOAD MYSQL QUERY RULES TO RUNTIME;
LOAD MYSQL VARIABLES TO RUNTIME;
LOAD ADMIN VARIABLES TO RUNTIME;

SAVE MYSQL SERVERS TO DISK;
SAVE MYSQL USERS TO DISK;
SAVE MYSQL QUERY RULES TO DISK;
SAVE MYSQL VARIABLES TO DISK;
SAVE ADMIN VARIABLES TO DISK;
EOF

    log "${OK} Configuration chargée"
}

###############################################################################
# VERIFY BACKENDS
###############################################################################

verify_backends() {
    log "${INFO} Vérification des backends MariaDB..."

    sleep 5

    mysql -h 127.0.0.1 -P "$PROXYSQL_ADMIN_PORT" -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \
        -e "SELECT hostgroup_id, hostname, port, status FROM stats_mysql_connection_pool ORDER BY hostgroup_id, hostname;" \
        2>/dev/null || log "${WARN} Impossible de vérifier les backends (probablement pas encore connectés)"
}

###############################################################################
# SAVE CREDENTIALS
###############################################################################

save_credentials() {
    log "${INFO} Sauvegarde des credentials..."

    mkdir -p /opt/keybuzz/proxysql
    CRED_FILE="/opt/keybuzz/proxysql/credentials_${NODE_NAME}.sh"

    cat > "$CRED_FILE" <<EOF
#!/usr/bin/env bash
# CREDENTIALS PROXYSQL - $NODE_NAME
# Généré: $(date)

export NODE_NAME="$NODE_NAME"
export NODE_IP="$NODE_IP"
export PROXYSQL_ADMIN_USER="$PROXYSQL_ADMIN_USER"
export PROXYSQL_ADMIN_PASSWORD="$PROXYSQL_ADMIN_PASSWORD"
export PROXYSQL_ADMIN_PORT="$PROXYSQL_ADMIN_PORT"
export PROXYSQL_MYSQL_PORT="$PROXYSQL_MYSQL_PORT"

# Connexion admin
# mysql -h $NODE_IP -P $PROXYSQL_ADMIN_PORT -u$PROXYSQL_ADMIN_USER -p'$PROXYSQL_ADMIN_PASSWORD'

# Connexion application (via Hetzner LB)
# mysql -h $HETZNER_LB_IP -P $HETZNER_LB_PORT -u$ERPNEXT_DB_USER -p'$ERPNEXT_DB_PASSWORD' $ERPNEXT_DB_NAME
EOF

    chmod 600 "$CRED_FILE"

    log "${OK} Credentials sauvegardés: $CRED_FILE"
}

###############################################################################
# MAIN
###############################################################################

main() {
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║  INSTALLATION PROXYSQL - $NODE_NAME (Automated)              ║"
    log "╚═══════════════════════════════════════════════════════════════╝"

    check_root
    detect_node

    log "${INFO} Début de l'installation automatique..."

    configure_ufw
    install_proxysql
    configure_proxysql
    start_proxysql
    load_config_to_runtime
    verify_backends
    save_credentials

    log "${OK} Installation terminée sur $NODE_NAME"
}

main "$@"
