#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || true
# shellcheck source=./00_lib_env.sh
. "./00_lib_env.sh"
load_keybuzz_env

echo "╔════════════════════════════════════════════════════╗"
echo "║     DEPLOY_PGBOUNCER_ON_PROXIES (autonome)        ║"
echo "╚════════════════════════════════════════════════════╝"
echo "Proxies  : ${KB_PROXY1_IP} / ${KB_PROXY2_IP}"
echo "VIP:port : ${KB_VIP_IP}:${KB_PG_NATIVE_PORT}"
echo "Mode auth: ${KB_PGB_AUTH_MODE}"
echo "DB/name  : ${KB_PG_SUPERUSER}@${KB_PG_DBNAME}"
[ -n "${KB_PG_SUPERPASS}" ] || echo "  ! Alerte: mot de passe superuser non découvert (je continue: MD5 userlist OK, SCRAM via auth_query peut échouer)."

PROXIES=("${KB_PROXY1_IP}" "${KB_PROXY2_IP}")
DEBIAN_FRONTEND=noninteractive

for px in "${PROXIES[@]}"; do
  echo "--- Proxy ${px} ---"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"${px}" "apt-get update -yq && apt-get install -yq pgbouncer jq"

  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"${px}" "mkdir -p /etc/pgbouncer && chown -R postgres:postgres /etc/pgbouncer"

  # userlist.txt — utile en md5, et sert pour admin
  # Met la même valeur pour stats si aucun pass connu (ne sera pas utilisé si SCRAM+auth_query)
  _stats_pass="${KB_PG_SUPERPASS}"
  [ -n "${_stats_pass}" ] || _stats_pass="changeme-stats"  # valeur innocente si vraiment rien trouvé

  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"${px}" "bash -lc 'cat >/etc/pgbouncer/userlist.txt <<EOF
\"${KB_PG_SUPERUSER}\" \"${KB_PG_SUPERPASS}\"
\"pgbouncer\" \"${_stats_pass}\"
EOF
chown postgres:postgres /etc/pgbouncer/userlist.txt
chmod 600 /etc/pgbouncer/userlist.txt'"

  if [ "${KB_PGB_AUTH_MODE}" = "scram" ]; then
    AUTH_TYPE="scram-sha-256"
    AUTH_EXTRA="auth_query = SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=\$1"
  else
    AUTH_TYPE="md5"
    AUTH_EXTRA="; auth_query inactif en md5"
  fi

  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"${px}" "bash -lc 'cat >/etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
pg_rw = host=${KB_VIP_IP} port=${KB_PG_NATIVE_PORT} dbname=${KB_PG_DBNAME}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${KB_PGB_LOCAL_PORT}
auth_type = ${AUTH_TYPE}
auth_file = /etc/pgbouncer/userlist.txt
${AUTH_EXTRA}
pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = 5000
default_pool_size = 100
ignore_startup_parameters = extra_float_digits,options,search_path
admin_users = ${KB_PG_SUPERUSER}
stats_users = pgbouncer
log_disconnections = 1
log_connections = 1
EOF
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
chmod 640 /etc/pgbouncer/pgbouncer.ini'"

  # Service systemd (sans interaction)
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"${px}" "bash -lc 'cat >/etc/systemd/system/pgbouncer.service <<EOF
[Unit]
Description=PgBouncer
After=network.target

[Service]
User=postgres
ExecStart=/usr/bin/pgbouncer -u postgres /etc/pgbouncer/pgbouncer.ini
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pgbouncer
systemctl restart pgbouncer
sleep 1
systemctl --no-pager -l status pgbouncer || true
ss -ltnp | grep :${KB_PGB_LOCAL_PORT} || (echo \"KO: rien n\\'écoute sur ${KB_PGB_LOCAL_PORT}\" && exit 1)'"

  echo "OK: PgBouncer écoute sur ${px}:${KB_PGB_LOCAL_PORT}"
done

echo "OK: Déploiement PgBouncer (mode=${KB_PGB_AUTH_MODE}) terminé."
