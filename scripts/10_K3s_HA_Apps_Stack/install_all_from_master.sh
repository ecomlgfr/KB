#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ORCHESTRATION COMPLÈTE - MariaDB Galera + ProxySQL + ERPNext
###############################################################################
# Auteur: Claude AI Assistant
# Date: 2025-11-13
# Version: 2.1 (Automated)
#
# Description:
#   Script d'orchestration maître pour installer automatiquement toute la stack
#   depuis le serveur install-01
#
# Usage:
#   ./install_all_from_master.sh
###############################################################################

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

###############################################################################
# CONFIGURATION
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.mariadb_proxysql_erpnext"

# Charger la configuration
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERREUR: Fichier $ENV_FILE introuvable!"
    echo "Créer le fichier .env d'abord ou copier .env.mariadb_proxysql_erpnext"
    exit 1
fi

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

###############################################################################
# GENERATE CREDENTIALS IF MISSING
###############################################################################

generate_credentials() {
    log "${INFO} Vérification des credentials..."

    # Vérifier si des passwords sont vides
    if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]] || \
       [[ -z "${SST_PASSWORD:-}" ]] || \
       [[ -z "${PROXYSQL_MONITOR_PASSWORD:-}" ]] || \
       [[ -z "${ERPNEXT_DB_PASSWORD:-}" ]] || \
       [[ -z "${MYSQLD_EXPORTER_PASSWORD:-}" ]] || \
       [[ -z "${PROXYSQL_ADMIN_PASSWORD:-}" ]] || \
       [[ -z "${ERPNEXT_ADMIN_PASSWORD:-}" ]]; then

        log "${WARN} Credentials manquants - génération automatique..."

        # Générer les credentials
        bash "$SCRIPT_DIR/generate_credentials.sh"

        # Recharger le .env
        set -a
        source "$ENV_FILE"
        set +a

        log "${OK} Credentials générés"
    else
        log "${OK} Credentials déjà configurés"
    fi
}

###############################################################################
# SSH TEST
###############################################################################

test_ssh_connectivity() {
    log "${INFO} Test de connectivité SSH..."

    local all_ok=true

    for host in "$DB01_IP" "$DB02_IP" "$DB03_IP" "$PROXY01_IP" "$PROXY02_IP"; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -i "$SSH_KEY_PATH" "${SSH_USER}@${host}" "echo OK" &>/dev/null; then
            log "  ${OK} $host accessible"
        else
            log "  ${KO} $host INACCESSIBLE"
            all_ok=false
        fi
    done

    if [[ "$all_ok" == "false" ]]; then
        error_exit "Certains serveurs ne sont pas accessibles via SSH"
    fi

    log "${OK} Tous les serveurs accessibles"
}

###############################################################################
# COPY FILES TO REMOTE SERVERS
###############################################################################

copy_files_to_servers() {
    log "${INFO} Copie des fichiers sur les serveurs distants..."

    local remote_dir="/root/mariadb_proxysql_install"

    # Fichiers à copier
    local files=(
        "$ENV_FILE"
        "$SCRIPT_DIR/install_mariadb_galera_auto.sh"
        "$SCRIPT_DIR/install_proxysql_auto.sh"
    )

    # Copier sur les serveurs MariaDB
    for host in "$DB01_IP" "$DB02_IP" "$DB03_IP"; do
        log "  Copie vers $host..."
        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${host}" "mkdir -p $remote_dir" 2>/dev/null

        for file in "${files[@]}"; do
            scp -i "$SSH_KEY_PATH" "$file" "${SSH_USER}@${host}:${remote_dir}/" >/dev/null 2>&1
        done

        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${host}" "chmod +x $remote_dir/*.sh" 2>/dev/null
    done

    # Copier sur les serveurs ProxySQL
    for host in "$PROXY01_IP" "$PROXY02_IP"; do
        log "  Copie vers $host..."
        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${host}" "mkdir -p $remote_dir" 2>/dev/null

        for file in "${files[@]}"; do
            scp -i "$SSH_KEY_PATH" "$file" "${SSH_USER}@${host}:${remote_dir}/" >/dev/null 2>&1
        done

        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${host}" "chmod +x $remote_dir/*.sh" 2>/dev/null
    done

    log "${OK} Fichiers copiés sur tous les serveurs"
}

###############################################################################
# INSTALL MARIADB GALERA
###############################################################################

install_mariadb_cluster() {
    log "═══════════════════════════════════════════════════════════════"
    log "  INSTALLATION MARIADB GALERA CLUSTER"
    log "═══════════════════════════════════════════════════════════════"

    local remote_dir="/root/mariadb_proxysql_install"

    # Installer sur les 3 nœuds en parallèle
    log "${INFO} Installation de MariaDB sur DB01, DB02, DB03 en parallèle..."

    for node in DB01 DB02 DB03; do
        local ip_var="${node}_IP"
        local ip="${!ip_var}"

        log "  Lancement installation sur $node ($ip)..."

        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${ip}" "
            cd $remote_dir && \
            NODE_NAME=$node ENV_FILE=$remote_dir/.env.mariadb_proxysql_erpnext \
            bash install_mariadb_galera_auto.sh
        " &
    done

    # Attendre la fin des 3 installations
    wait

    log "${OK} MariaDB installé sur les 3 nœuds"
}

###############################################################################
# BOOTSTRAP GALERA CLUSTER
###############################################################################

bootstrap_galera_cluster() {
    log "${INFO} Bootstrap du cluster Galera sur DB01..."

    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${DB01_IP}" "
        systemctl stop mariadb 2>/dev/null || true
        galera_new_cluster
        systemctl start mysqld_exporter
    "

    log "${OK} DB01 bootstrappé"
    log "${INFO} Attente de ${WAIT_AFTER_BOOTSTRAP}s..."
    sleep "$WAIT_AFTER_BOOTSTRAP"

    # Démarrer DB02
    log "${INFO} Démarrage de MariaDB sur DB02..."
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${DB02_IP}" "
        systemctl start mariadb
        systemctl start mysqld_exporter
    "

    sleep 10

    # Démarrer DB03
    log "${INFO} Démarrage de MariaDB sur DB03..."
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${DB03_IP}" "
        systemctl start mariadb
        systemctl start mysqld_exporter
    "

    log "${INFO} Attente de synchronisation du cluster (${WAIT_CLUSTER_SYNC}s)..."
    sleep "$WAIT_CLUSTER_SYNC"

    # Vérifier le cluster
    verify_galera_cluster
}

###############################################################################
# VERIFY GALERA CLUSTER
###############################################################################

verify_galera_cluster() {
    log "${INFO} Vérification du cluster Galera..."

    local cluster_size=$(ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${DB01_IP}" \
        "mysql -u root -p'${MYSQL_ROOT_PASSWORD}' -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\" 2>/dev/null | grep wsrep_cluster_size | awk '{print \$2}'")

    if [[ "$cluster_size" == "3" ]]; then
        log "${OK} Cluster Galera opérationnel (3 nœuds)"
    else
        log "${WARN} Cluster size: $cluster_size (attendu: 3)"
        log "${INFO} Le cluster peut encore être en cours de synchronisation..."
    fi

    # Afficher le statut
    log "${INFO} Statut du cluster:"
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${DB01_IP}" \
        "mysql -u root -p'${MYSQL_ROOT_PASSWORD}' -e \"SHOW STATUS LIKE 'wsrep%';\" 2>/dev/null | grep -E '(cluster_size|cluster_status|connected|ready|local_state_comment)'" || true
}

###############################################################################
# INSTALL PROXYSQL
###############################################################################

install_proxysql_cluster() {
    log "═══════════════════════════════════════════════════════════════"
    log "  INSTALLATION PROXYSQL"
    log "═══════════════════════════════════════════════════════════════"

    local remote_dir="/root/mariadb_proxysql_install"

    # Installer sur les 2 nœuds ProxySQL en parallèle
    log "${INFO} Installation de ProxySQL sur PROXY01 et PROXY02 en parallèle..."

    for node in PROXY01 PROXY02; do
        local ip_var="${node}_IP"
        local ip="${!ip_var}"

        log "  Lancement installation sur $node ($ip)..."

        ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${ip}" "
            cd $remote_dir && \
            NODE_NAME=$node ENV_FILE=$remote_dir/.env.mariadb_proxysql_erpnext \
            bash install_proxysql_auto.sh
        " &
    done

    # Attendre la fin des 2 installations
    wait

    log "${OK} ProxySQL installé sur les 2 nœuds"

    log "${INFO} Attente de démarrage de ProxySQL (${WAIT_PROXYSQL_START}s)..."
    sleep "$WAIT_PROXYSQL_START"

    # Vérifier ProxySQL
    verify_proxysql()
}

###############################################################################
# VERIFY PROXYSQL
###############################################################################

verify_proxysql() {
    log "${INFO} Vérification de ProxySQL..."

    log "${INFO} État des backends sur PROXY01:"
    ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${PROXY01_IP}" \
        "mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u$PROXYSQL_ADMIN_USER -p'$PROXYSQL_ADMIN_PASSWORD' \
        -e 'SELECT hostgroup_id, hostname, port, status FROM stats_mysql_connection_pool ORDER BY hostgroup_id, hostname;' 2>/dev/null" || \
        log "${WARN} Impossible de vérifier ProxySQL (peut être encore en train de se connecter aux backends)"
}

###############################################################################
# TEST HETZNER LB
###############################################################################

test_hetzner_lb() {
    log "${INFO} Test de connexion via Hetzner LB..."

    # Test depuis DB01 (qui a mysql-client)
    if ssh -i "$SSH_KEY_PATH" "${SSH_USER}@${DB01_IP}" \
        "mysql -h $HETZNER_LB_IP -P $HETZNER_LB_PORT -u$ERPNEXT_DB_USER -p'$ERPNEXT_DB_PASSWORD' $ERPNEXT_DB_NAME -e 'SELECT 1;' 2>/dev/null" >/dev/null; then
        log "${OK} Hetzner LB opérationnel"
    else
        log "${WARN} Hetzner LB non accessible - vérifier la configuration"
        log "${INFO} Configuration requise:"
        log "  - Frontend: $HETZNER_LB_IP:$HETZNER_LB_PORT (TCP)"
        log "  - Backends: $PROXY01_IP:$PROXYSQL_MYSQL_PORT, $PROXY02_IP:$PROXYSQL_MYSQL_PORT"
        log "  - Health Check: TCP port $PROXYSQL_MYSQL_PORT"
    fi
}

###############################################################################
# DEPLOY ERPNEXT
###############################################################################

deploy_erpnext() {
    log "═══════════════════════════════════════════════════════════════"
    log "  DÉPLOIEMENT ERPNEXT SUR K3S"
    log "═══════════════════════════════════════════════════════════════"

    # Exécuter localement (sur install-01 qui a accès au cluster K3s)
    log "${INFO} Déploiement de ERPNext..."

    ENV_FILE="$ENV_FILE" bash "$SCRIPT_DIR/deploy_erpnext_auto.sh"

    log "${OK} ERPNext déployé"
}

###############################################################################
# DISPLAY SUMMARY
###############################################################################

display_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "          INSTALLATION COMPLÈTE TERMINÉE !"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    log "${OK} Stack complète installée et opérationnelle"
    echo ""

    echo "📊 RÉSUMÉ:"
    echo ""

    echo "  🗄️  MariaDB Galera Cluster"
    echo "     • DB01: $DB01_IP"
    echo "     • DB02: $DB02_IP"
    echo "     • DB03: $DB03_IP"
    echo "     • Port: 3306"
    echo "     • Monitoring: port 9104 (mysqld_exporter)"
    echo ""

    echo "  🔀 ProxySQL"
    echo "     • PROXY01: $PROXY01_IP"
    echo "     • PROXY02: $PROXY02_IP"
    echo "     • MySQL Port: $PROXYSQL_MYSQL_PORT"
    echo "     • Admin Port: $PROXYSQL_ADMIN_PORT"
    echo ""

    echo "  ⚖️  Hetzner Load Balancer"
    echo "     • IP: $HETZNER_LB_IP:$HETZNER_LB_PORT"
    echo "     • Backends: PROXY01, PROXY02"
    echo ""

    echo "  💼 ERPNext"
    echo "     • Site: https://$ERPNEXT_SITE_NAME"
    echo "     • Admin: Administrator"
    echo "     • Password: $ERPNEXT_ADMIN_PASSWORD"
    echo "     • Namespace: $ERPNEXT_NAMESPACE"
    echo ""

    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    echo "📁 CREDENTIALS:"
    echo ""
    echo "  MariaDB:"
    echo "    • DB01: /opt/keybuzz/mariadb/credentials_DB01.sh"
    echo "    • DB02: /opt/keybuzz/mariadb/credentials_DB02.sh"
    echo "    • DB03: /opt/keybuzz/mariadb/credentials_DB03.sh"
    echo ""
    echo "  ProxySQL:"
    echo "    • PROXY01: /opt/keybuzz/proxysql/credentials_PROXY01.sh"
    echo "    • PROXY02: /opt/keybuzz/proxysql/credentials_PROXY02.sh"
    echo ""
    echo "  ERPNext:"
    echo "    • Local: /opt/keybuzz/erpnext/credentials_erpnext.sh"
    echo ""

    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    echo "🔍 VÉRIFICATIONS:"
    echo ""
    echo "  Cluster Galera:"
    echo "    ssh root@$DB01_IP \"mysql -u root -p'$MYSQL_ROOT_PASSWORD' -e 'SHOW STATUS LIKE \\\"wsrep_cluster_size\\\";'\""
    echo ""
    echo "  ProxySQL:"
    echo "    ssh root@$PROXY01_IP \"mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u$PROXYSQL_ADMIN_USER -p'$PROXYSQL_ADMIN_PASSWORD' -e 'SELECT * FROM mysql_servers;'\""
    echo ""
    echo "  ERPNext:"
    echo "    kubectl get pods -n $ERPNEXT_NAMESPACE"
    echo ""

    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    log "${OK} Installation terminée avec succès!"
}

###############################################################################
# MAIN
###############################################################################

main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                   ║"
    echo "║     ORCHESTRATION COMPLÈTE - MARIADB + PROXYSQL + ERPNEXT       ║"
    echo "║                        (Automated)                                ║"
    echo "║                                                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    log "${INFO} Début de l'orchestration complète..."
    echo ""

    # Étapes d'installation
    generate_credentials
    test_ssh_connectivity
    copy_files_to_servers
    install_mariadb_cluster
    bootstrap_galera_cluster
    install_proxysql_cluster
    test_hetzner_lb
    deploy_erpnext

    display_summary
}

# Exécution
main "$@"
