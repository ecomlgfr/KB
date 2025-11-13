#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# INSTALLATION MARIADB GALERA CLUSTER - KeyBuzz Standards (NON-INTERACTIVE)
###############################################################################
# Auteur: Claude AI Assistant
# Date: 2025-11-13
# Version: 2.1 (Automated)
#
# Description:
#   Installation automatique d'un cluster MariaDB Galera 3 noeuds
#   Mode non-interactif pour orchestration depuis install-01
#
# Usage:
#   ENV_FILE=/path/to/.env NODE_NAME=DB01 ./install_mariadb_galera_auto.sh
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

    # Si NODE_NAME est passé en variable d'environnement, l'utiliser
    if [[ -n "${NODE_NAME:-}" ]]; then
        log "${INFO} Node forcé: $NODE_NAME"
        case "$NODE_NAME" in
            DB01) NODE_IP="$DB01_IP" ;;
            DB02) NODE_IP="$DB02_IP" ;;
            DB03) NODE_IP="$DB03_IP" ;;
            *) error_exit "NODE_NAME invalide: $NODE_NAME" ;;
        esac
        return 0
    fi

    # Sinon, détecter automatiquement
    if [[ "$ip" == "$DB01_IP" ]]; then
        NODE_NAME="DB01"
        NODE_IP="$DB01_IP"
    elif [[ "$ip" == "$DB02_IP" ]]; then
        NODE_NAME="DB02"
        NODE_IP="$DB02_IP"
    elif [[ "$ip" == "$DB03_IP" ]]; then
        NODE_NAME="DB03"
        NODE_IP="$DB03_IP"
    else
        error_exit "IP actuelle ($ip) ne correspond à aucun noeud MariaDB"
    fi

    log "${OK} Noeud détecté: $NODE_NAME ($NODE_IP)"
}

###############################################################################
# SETUP DIRECTORIES
###############################################################################

setup_directories() {
    log "${INFO} Configuration des répertoires..."

    mkdir -p "$MARIADB_DATA_DIR" "$MARIADB_LOG_DIR" "$MARIADB_BACKUP_DIR"

    # Si le volume est déjà monté et contient des données, ne pas écraser
    if [[ "$SKIP_XFS_FORMAT" == "true" ]] && [[ -d "$MARIADB_DATA_DIR" ]]; then
        log "${WARN} SKIP_XFS_FORMAT=true - Utilisation du volume existant"
        if [[ -d "$MARIADB_DATA_DIR/mysql" ]]; then
            log "${WARN} Datadir existant détecté - backup avant écrasement"
            BACKUP_NAME="datadir_backup_$(date +%Y%m%d_%H%M%S)"
            mv "$MARIADB_DATA_DIR" "${MARIADB_BACKUP_DIR}/${BACKUP_NAME}" || true
            mkdir -p "$MARIADB_DATA_DIR"
        fi
    fi

    log "${OK} Répertoires configurés"
}

###############################################################################
# CONFIGURE FIREWALL
###############################################################################

configure_ufw() {
    log "${INFO} Configuration du pare-feu UFW..."

    # Installation UFW si nécessaire
    if ! command -v ufw &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ufw
    fi

    # Configuration UFW
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Ports TCP
    for port in 22 3306 4444 4567 4568 9104; do
        ufw allow "$port/tcp" comment "MariaDB Galera" >/dev/null 2>&1
    done

    # Ports UDP
    ufw allow 4567/udp comment "MariaDB Galera" >/dev/null 2>&1

    # Réseau privé Hetzner
    ufw allow from 10.0.0.0/16 comment "Hetzner Private Network" >/dev/null 2>&1

    # Activation
    ufw --force enable

    log "${OK} UFW configuré"
}

###############################################################################
# INSTALL MARIADB
###############################################################################

install_mariadb() {
    log "${INFO} Installation de MariaDB $MARIADB_VERSION..."

    export DEBIAN_FRONTEND=noninteractive

    # Ajout du dépôt MariaDB
    apt-get update -qq
    apt-get install -y -qq software-properties-common curl gnupg2

    curl -sS https://r.mariadb.com/downloads/mariadb_repo_setup | \
        bash -s -- --mariadb-server-version="mariadb-$MARIADB_VERSION" >/dev/null 2>&1

    # Installation des paquets
    apt-get update -qq
    apt-get install -y -qq \
        mariadb-server \
        mariadb-client \
        mariadb-backup \
        galera-4 \
        rsync \
        socat \
        percona-xtrabackup-80 \
        qpress

    # Arrêter MariaDB
    systemctl stop mariadb || true

    log "${OK} MariaDB installé"
}

###############################################################################
# INITIALIZE DATADIR
###############################################################################

initialize_datadir() {
    log "${INFO} Initialisation du répertoire de données..."

    # Si le datadir existe déjà, skip
    if [[ -d "$MARIADB_DATA_DIR/mysql" ]]; then
        log "${WARN} Datadir déjà initialisé - skip"
        chown -R mysql:mysql "$MARIADB_DATA_DIR"
        return 0
    fi

    # Initialisation MySQL
    mysql_install_db \
        --user=mysql \
        --datadir="$MARIADB_DATA_DIR" \
        --skip-test-db >/dev/null 2>&1

    chown -R mysql:mysql "$MARIADB_DATA_DIR" "$MARIADB_LOG_DIR" "$MARIADB_BACKUP_DIR"
    chmod 750 "$MARIADB_DATA_DIR"

    log "${OK} Datadir initialisé"
}

###############################################################################
# CONFIGURE GALERA
###############################################################################

configure_galera() {
    log "${INFO} Configuration de Galera Cluster..."

    # Backup config existante
    if [[ -f /etc/mysql/mariadb.conf.d/60-galera.cnf ]]; then
        cp /etc/mysql/mariadb.conf.d/60-galera.cnf \
           /etc/mysql/mariadb.conf.d/60-galera.cnf.bak.$(date +%Y%m%d_%H%M%S)
    fi

    # Déterminer le server-id
    SERVER_ID="${NODE_IP##*.}"

    # Création de la configuration Galera
    cat > /etc/mysql/mariadb.conf.d/60-galera.cnf <<EOF
# Galera Cluster Configuration - $NODE_NAME
# Generated: $(date)

[mysqld]
# Basic Settings
server-id = $SERVER_ID
bind-address = 0.0.0.0
port = 3306

# Data Directory
datadir = $MARIADB_DATA_DIR

# Logging
log_error = $MARIADB_LOG_DIR/mariadb_error.log
slow_query_log = 1
slow_query_log_file = $MARIADB_LOG_DIR/mariadb_slow.log
long_query_time = 2

# Binary Logging
log_bin = $MARIADB_LOG_DIR/mariadb-bin
binlog_format = ROW
expire_logs_days = 7

# InnoDB Settings
innodb_buffer_pool_size = 2G
innodb_log_file_size = 512M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
innodb_autoinc_lock_mode = 2

# Character Set
character_set_server = utf8mb4
collation_server = utf8mb4_unicode_ci

# Connection Settings
max_connections = 500
max_connect_errors = 1000000
max_allowed_packet = 256M

# Query Cache (disabled for Galera)
query_cache_size = 0
query_cache_type = 0

# GALERA CLUSTER SETTINGS
wsrep_on = ON
wsrep_provider = /usr/lib/galera/libgalera_smm.so
wsrep_cluster_name = "$CLUSTER_NAME"
wsrep_cluster_address = "gcomm://$DB01_IP,$DB02_IP,$DB03_IP"
wsrep_node_name = "$NODE_NAME"
wsrep_node_address = "$NODE_IP"
wsrep_sst_method = xtrabackup-v2
wsrep_sst_auth = "$SST_USER:$SST_PASSWORD"
wsrep_slave_threads = 4
wsrep_provider_options = "gcache.size=2G"

# Performance Schema
performance_schema = ON
EOF

    log "${OK} Configuration Galera créée"
}

###############################################################################
# CONFIGURE SYSTEMD
###############################################################################

configure_systemd() {
    log "${INFO} Configuration systemd..."

    mkdir -p /etc/systemd/system/mariadb.service.d/

    cat > /etc/systemd/system/mariadb.service.d/override.conf <<EOF
[Service]
LimitNOFILE=65535
LimitNPROC=65535
Restart=on-failure
RestartSec=10s
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$MARIADB_DATA_DIR $MARIADB_LOG_DIR $MARIADB_BACKUP_DIR
EOF

    systemctl daemon-reload

    log "${OK} Systemd configuré"
}

###############################################################################
# CREATE USERS
###############################################################################

create_galera_users() {
    log "${INFO} Création des utilisateurs MariaDB..."

    # Démarrage temporaire en mode bootstrap pour configuration
    if [[ ! -S /var/run/mysqld/mysqld.sock ]]; then
        log "Démarrage temporaire de MariaDB..."
        mysqld_safe --skip-networking --skip-grant-tables --datadir="$MARIADB_DATA_DIR" &
        MYSQLD_PID=$!

        # Attendre que MySQL soit prêt
        for i in {1..30}; do
            if mysqladmin ping --silent 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi

    # Configuration root password
    mysql --connect-expired-password 2>/dev/null <<EOF || mysql <<EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF

    # Création des utilisateurs
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
-- SST User
CREATE USER IF NOT EXISTS '$SST_USER'@'localhost' IDENTIFIED BY '$SST_PASSWORD';
GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO '$SST_USER'@'localhost';

-- ProxySQL Monitor User
CREATE USER IF NOT EXISTS '$PROXYSQL_MONITOR_USER'@'%' IDENTIFIED BY '$PROXYSQL_MONITOR_PASSWORD';
GRANT USAGE, REPLICATION CLIENT ON *.* TO '$PROXYSQL_MONITOR_USER'@'%';

-- mysqld_exporter User
CREATE USER IF NOT EXISTS '$MYSQLD_EXPORTER_USER'@'localhost' IDENTIFIED BY '$MYSQLD_EXPORTER_PASSWORD';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '$MYSQLD_EXPORTER_USER'@'localhost';

-- ERPNext Database and User
CREATE DATABASE IF NOT EXISTS $ERPNEXT_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$ERPNEXT_DB_USER'@'%' IDENTIFIED BY '$ERPNEXT_DB_PASSWORD';
GRANT ALL PRIVILEGES ON ${ERPNEXT_DB_NAME}.* TO '$ERPNEXT_DB_USER'@'%';

FLUSH PRIVILEGES;
EOF

    # Arrêt du mysqld temporaire
    if [[ -n "${MYSQLD_PID:-}" ]]; then
        kill "$MYSQLD_PID" 2>/dev/null || true
        wait "$MYSQLD_PID" 2>/dev/null || true
    fi

    log "${OK} Utilisateurs créés"
}

###############################################################################
# INSTALL MYSQLD_EXPORTER
###############################################################################

install_mysqld_exporter() {
    log "${INFO} Installation de mysqld_exporter..."

    EXPORTER_VERSION="0.15.1"
    EXPORTER_URL="https://github.com/prometheus/mysqld_exporter/releases/download/v${EXPORTER_VERSION}/mysqld_exporter-${EXPORTER_VERSION}.linux-amd64.tar.gz"

    cd /tmp
    curl -sL "$EXPORTER_URL" | tar xz
    mv "mysqld_exporter-${EXPORTER_VERSION}.linux-amd64/mysqld_exporter" /usr/local/bin/
    chmod +x /usr/local/bin/mysqld_exporter
    rm -rf "/tmp/mysqld_exporter-${EXPORTER_VERSION}.linux-amd64"*

    # Config
    cat > /etc/.mysqld_exporter.cnf <<EOF
[client]
user=$MYSQLD_EXPORTER_USER
password=$MYSQLD_EXPORTER_PASSWORD
host=localhost
port=3306
EOF
    chmod 600 /etc/.mysqld_exporter.cnf

    # Service systemd
    cat > /etc/systemd/system/mysqld_exporter.service <<EOF
[Unit]
Description=MySQL Exporter for Prometheus
After=mariadb.service
Wants=mariadb.service

[Service]
Type=simple
User=mysql
Group=mysql
ExecStart=/usr/local/bin/mysqld_exporter \
    --config.my-cnf=/etc/.mysqld_exporter.cnf \
    --web.listen-address=0.0.0.0:9104
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mysqld_exporter

    log "${OK} mysqld_exporter installé"
}

###############################################################################
# SAVE CREDENTIALS
###############################################################################

save_credentials() {
    log "${INFO} Sauvegarde des credentials..."

    CRED_FILE="/opt/keybuzz/mariadb/credentials_${NODE_NAME}.sh"

    cat > "$CRED_FILE" <<EOF
#!/usr/bin/env bash
# CREDENTIALS MARIADB GALERA - $NODE_NAME
# Généré: $(date)

export NODE_NAME="$NODE_NAME"
export NODE_IP="$NODE_IP"
export MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"
export SST_USER="$SST_USER"
export SST_PASSWORD="$SST_PASSWORD"
export PROXYSQL_MONITOR_USER="$PROXYSQL_MONITOR_USER"
export PROXYSQL_MONITOR_PASSWORD="$PROXYSQL_MONITOR_PASSWORD"
export ERPNEXT_DB_USER="$ERPNEXT_DB_USER"
export ERPNEXT_DB_PASSWORD="$ERPNEXT_DB_PASSWORD"
export ERPNEXT_DB_NAME="$ERPNEXT_DB_NAME"
export MYSQLD_EXPORTER_USER="$MYSQLD_EXPORTER_USER"
export MYSQLD_EXPORTER_PASSWORD="$MYSQLD_EXPORTER_PASSWORD"
EOF

    chmod 600 "$CRED_FILE"

    log "${OK} Credentials sauvegardés: $CRED_FILE"
}

###############################################################################
# MAIN
###############################################################################

main() {
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║  INSTALLATION MARIADB GALERA - $NODE_NAME (Automated)         ║"
    log "╚═══════════════════════════════════════════════════════════════╝"

    check_root
    detect_node

    log "${INFO} Début de l'installation automatique..."

    setup_directories
    configure_ufw
    install_mariadb
    initialize_datadir
    configure_galera
    configure_systemd
    create_galera_users
    install_mysqld_exporter
    save_credentials

    log "${OK} Installation terminée sur $NODE_NAME"
    log "${WARN} NE PAS démarrer MariaDB maintenant!"
    log "${INFO} Attendre les instructions d'orchestration pour le bootstrap"
}

main "$@"
