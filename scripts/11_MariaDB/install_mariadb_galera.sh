#!/bin/bash
set -euo pipefail

INSTALL_HOST="91.98.128.153"
ENV_PATH="/opt/keybuzz-installer/credentials/mariadb.env"
SSH_FLAGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH="ssh $SSH_FLAGS"
SCP="scp $SSH_FLAGS"

declare -A NODES=(
  ["maria-01"]=10.0.0.170
  ["maria-02"]=10.0.0.171
  ["maria-03"]=10.0.0.172
)

PACKAGES="mariadb-server mariadb-client galera-4 mariadb-backup socat"
SST_USER="sstuser"
ERP_USER="erpnext"

CONFIG_TEMPLATE='[mysqld]
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
bind-address=0.0.0.0

wsrep_on=ON
wsrep_provider=/usr/lib/galera/libgalera_smm.so
wsrep_cluster_name="keybuzz-mariadb"
wsrep_cluster_address="gcomm://10.0.0.170,10.0.0.171,10.0.0.172"
wsrep_node_name="{NODE_NAME}"
wsrep_node_address="{NODE_IP}"
wsrep_sst_method=mariabackup
wsrep_sst_auth="{SST_USER}:{SST_PASSWORD}"
wsrep_provider_options="gcache.size=1G;gcache.page_size=128M"

innodb_flush_log_at_trx_commit=2
wsrep_slave_threads=4
wsrep_load_data_splitting=ON

wsrep_certification_rules=STRICT
wsrep_retry_autocommit=3

skip-name-resolve=1
max_connections=500
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

datadir=/opt/keybuzz/mariadb/data
'

random_password() {
  local length=${1:-24}
  tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length"
}

run_remote() {
  local ip=$1; shift
  $SSH root@"$ip" "$@"
}

copy_config() {
  local node=$1 ip=$2 sst_pwd=$3
  local config=${CONFIG_TEMPLATE//\{NODE_NAME\}/$node}
  config=${config//\{NODE_IP\}/$ip}
  config=${config//\{SST_USER\}/$SST_USER}
  config=${config//\{SST_PASSWORD\}/$sst_pwd}
  run_remote "$ip" "cat <<'EOF' > /etc/mysql/mariadb.conf.d/60-galera.cnf
$config
EOF"
}

bootstrap_cluster() {
  run_remote "${NODES[maria-01]}" "galera_new_cluster"
}

wait_synced() {
  local ip=$1 password=$2 expected=$3 timeout=${4:-300}
  local start=$(date +%s)
  while true; do
    local cmd
    if [[ -n $password ]]; then
      cmd="mysql --batch --skip-column-names -uroot -p$password -e \"SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_ready'; SHOW STATUS LIKE 'wsrep_cluster_size';\" 2>/dev/null | awk '{print \$2}'"
    else
      cmd="mysql --batch --skip-column-names -uroot -e \"SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_ready'; SHOW STATUS LIKE 'wsrep_cluster_size';\" 2>/dev/null | awk '{print \$2}'"
    fi
    local output=$($SSH root@"$ip" "$cmd" || true)
    if [[ -n $output ]]; then
      local state=$(echo "$output" | tail -n3 | head -n1)
      local ready=$(echo "$output" | tail -n2 | head -n1)
      local size=$(echo "$output" | tail -n1)
      echo "[$ip] state=$state ready=$ready size=$size"
      if [[ $state == "Synced" && $ready == "ON" && ${size%.*} -ge $expected ]]; then
        return 0
      fi
    fi
    if (( $(date +%s) - start > timeout )); then
      echo "Timeout en attendant $ip"
      return 1
    fi
    sleep 5
  done
}

initialize_datadir() {
  local ip=$1
  run_remote "$ip" "set -e; systemctl stop mariadb 2>/dev/null || true; pkill -9 mariadbd 2>/dev/null || true; sleep 2; find /opt/keybuzz/mariadb/data -mindepth 1 -maxdepth 1 -exec rm -rf {} +; mariadb-install-db --user=mysql --datadir=/opt/keybuzz/mariadb/data >/tmp/mariadb-install.log 2>&1; rm -f /run/mysqld/mysqld.sock; chown -R mysql:mysql /opt/keybuzz/mariadb/data; chmod 750 /opt/keybuzz/mariadb/data"
}

configure_env() {
  local root_pwd=$1 erp_pwd=$2 sst_pwd=$3
  local temp=$(mktemp)
  cat > "$temp" <<EOF
MARIADB_ROOT_PASSWORD=$root_pwd
MARIADB_KEYBUZZ_USER=$ERP_USER
MARIADB_KEYBUZZ_PASSWORD=$erp_pwd
MARIADB_SST_USER=$SST_USER
MARIADB_SST_PASSWORD=$sst_pwd
EOF
  $SCP "$temp" root@"$INSTALL_HOST":"$ENV_PATH"
  rm -f "$temp"
  run_remote "$INSTALL_HOST" "chmod 600 $ENV_PATH"
}

set_root_password() {
  local password=$1
  run_remote "${NODES[maria-01]}" "mysql -uroot -e \"SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$password'); FLUSH PRIVILEGES;\""
}

configure_accounts() {
  local root_pwd=$1 erp_pwd=$2 sst_pwd=$3
  local sql=(
    "DROP USER IF EXISTS '$SST_USER'@'localhost';"
    "DROP USER IF EXISTS '$SST_USER'@'%';"
    "CREATE USER '$SST_USER'@'localhost' IDENTIFIED BY '$sst_pwd';"
    "CREATE USER '$SST_USER'@'%' IDENTIFIED BY '$sst_pwd';"
    "GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO '$SST_USER'@'localhost';"
    "GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO '$SST_USER'@'%';"
    "DROP USER IF EXISTS '$ERP_USER'@'%';"
    "CREATE USER '$ERP_USER'@'%' IDENTIFIED BY '$erp_pwd';"
    "CREATE DATABASE IF NOT EXISTS $ERP_USER CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    "GRANT ALL PRIVILEGES ON $ERP_USER.* TO '$ERP_USER'@'%';"
    "FLUSH PRIVILEGES;"
  )
  local sql_cmd=$(printf "%s " "${sql[@]}")
  run_remote "${NODES[maria-01]}" "MYSQL_PWD=$root_pwd mysql -uroot -e \"$sql_cmd\""
}

start_node() {
  local ip=$1 root_pwd=$2 expected=$3
  run_remote "$ip" "systemctl start mariadb"
  wait_synced "$ip" "$root_pwd" "$expected"
}

main() {
  echo "=== Installation cluster MariaDB Galera ==="
  local root_pwd=$(random_password 24)
  local erp_pwd=$(random_password 24)
  local sst_pwd=$(random_password 20)

  configure_env "$root_pwd" "$erp_pwd" "$sst_pwd"

  echo "\n=== Installation des paquets ==="
  for node in "${!NODES[@]}"; do
    local ip=${NODES[$node]}
    echo "-- $node ($ip)"
    run_remote "$ip" "DEBIAN_FRONTEND=noninteractive apt-get update -y"
    run_remote "$ip" "DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES"
    copy_config "$node" "$ip" "$sst_pwd"
    initialize_datadir "$ip"
  done

  echo "\n=== Bootstrap maria-01 ==="
  bootstrap_cluster
  wait_synced "${NODES[maria-01]}" "" 1

  echo "\n=== Configuration mots de passe/utilisateurs ==="
  set_root_password "$root_pwd"
  configure_accounts "$root_pwd" "$erp_pwd" "$sst_pwd"

  echo "\n=== Démarrage des nœuds secondaires ==="
  start_node "${NODES[maria-02]}" "$root_pwd" 2
  start_node "${NODES[maria-03]}" "$root_pwd" 3

  echo "\n✅ Installation terminée"
  echo "Identifiants enregistrés dans $ENV_PATH"
  echo "- MARIADB_ROOT_PASSWORD=$root_pwd"
  echo "- MARIADB_KEYBUZZ_USER=$ERP_USER"
  echo "- MARIADB_KEYBUZZ_PASSWORD=$erp_pwd"
  echo "- MARIADB_SST_USER=$SST_USER"
  echo "- MARIADB_SST_PASSWORD=$sst_pwd"
}

main "$@"
