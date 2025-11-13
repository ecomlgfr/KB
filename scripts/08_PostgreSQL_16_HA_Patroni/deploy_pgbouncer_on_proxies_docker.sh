#!/usr/bin/env bash
# pas de -e
set -uo pipefail
cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

echo "╔════════════════════════════════════════════════════╗"
echo "║  DEPLOY_PGBOUNCER_ON_PROXIES (Docker, autonome)   ║"
echo "╚════════════════════════════════════════════════════╝"
echo "Auth     : ${KB_PGB_AUTH_MODE} | DB=${KB_PG_SUPERUSER}@${KB_PG_DBNAME}"
[ -n "${KB_PG_SUPERPASS}" ] || echo -e "  \033[1;33m! Alerte:\033[0m mot de passe superuser non déduit (SCRAM via auth_query peut échouer si verifiers non prêts)"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
get_ip(){ awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }

P1="$(get_ip 'haproxy-01')"; P2="$(get_ip 'haproxy-02')"
[ -n "$P1" ] && [ -n "$P2" ] || { echo -e "\033[0;31mKO\033[0m IP proxies introuvables dans servers.tsv"; exit 1; }

PROXIES=("$P1" "$P2")
SERVICE_NAME="pgbouncer"
REMOTE_BASE="/opt/keybuzz/pgbouncer"

make_remote_file(){ local host="$1" path="$2" content="$3"; printf "%s" "$content" | base64 -w0 | ssh -o StrictHostKeyChecking=no root@"$host" "mkdir -p \"\$(dirname \"$path\")\" && base64 -d > \"$path\""; }

select_pgbouncer_image_on_host(){ local host="$1" img; for img in "${IMG_PGBOUNCER_CANDIDATES[@]}"; do ssh -o StrictHostKeyChecking=no root@"$host" "docker pull ${img} >/dev/null 2>&1" && { echo "$img"; return 0; }; done; echo ""; return 1; }

gen_ini(){ # listen 0.0.0.0 (dans le conteneur), bind IP se fait côté host via ports: IP:6432:6432
  if [ "${KB_PGB_AUTH_MODE}" = "scram" ]; then
    cat <<EOF
[databases]
pg_rw = host=\${PROXY_HOST_IP} port=5432 dbname=${KB_PG_DBNAME}
[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${KB_PGB_LOCAL_PORT}
auth_type = scram-sha-256
auth_user = ${KB_PG_SUPERUSER}
auth_query = SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=\$1
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
  else
    cat <<EOF
[databases]
pg_rw = host=\${PROXY_HOST_IP} port=5432 dbname=${KB_PG_DBNAME}
[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${KB_PGB_LOCAL_PORT}
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
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
  fi
}

compose_for_image(){ # image host_ip -> compose YAML (ports: "IP:6432:6432")
  local image="$1" host_ip="$2" volumes_str env_str cmd_str cont_conf_dir cont_ini cont_userlist
  if echo "$image" | grep -qi "bitnami/pgbouncer"; then
    cont_conf_dir="/opt/bitnami/pgbouncer/conf"
    cont_ini="${cont_conf_dir}/pgbouncer.ini"
    cont_userlist="${cont_conf_dir}/userlist.txt"
    volumes_str="- ${REMOTE_BASE}/pgbouncer.ini:${cont_ini}:ro"
    [ "${KB_PGB_AUTH_MODE}" = "md5" ] && volumes_str="${volumes_str}
      - ${REMOTE_BASE}/userlist.txt:${cont_userlist}:ro"
    env_str="- PGBOUNCER_CONF_FILE=${cont_ini}
      - BITNAMI_DEBUG=true"
    cmd_str=""
  else
    cont_conf_dir="/etc/pgbouncer"
    cont_ini="${cont_conf_dir}/pgbouncer.ini"
    cont_userlist="${cont_conf_dir}/userlist.txt"
    volumes_str="- ${REMOTE_BASE}/pgbouncer.ini:${cont_ini}:ro"
    [ "${KB_PGB_AUTH_MODE}" = "md5" ] && volumes_str="${volumes_str}
      - ${REMOTE_BASE}/userlist.txt:${cont_userlist}:ro"
    env_str="- LOGFILE=/dev/stdout"
    cmd_str="command: [\"pgbouncer\",\"${cont_ini}\"]"
  fi
  cat <<EOF
services:
  ${SERVICE_NAME}:
    image: ${image}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    ports:
      - "${host_ip}:${KB_PGB_LOCAL_PORT}:${KB_PGB_LOCAL_PORT}"
    volumes:
      ${volumes_str}
    environment:
      ${env_str}
    ${cmd_str}
EOF
}

try_up_with_image(){ # host image host_ip
  local host="$1" image="$2" host_ip="$3"
  local ini; ini="$(gen_ini)"; ini="${ini//\$\{PROXY_HOST_IP\}/$host_ip}"
  make_remote_file "$host" "${REMOTE_BASE}/pgbouncer.ini" "$ini"
  if [ "${KB_PGB_AUTH_MODE}" = "md5" ]; then
    local stats_pass; stats_pass="${KB_PG_SUPERPASS:-changeme-stats}"
    make_remote_file "$host" "${REMOTE_BASE}/userlist.txt" "\"${KB_PG_SUPERUSER}\" \"${KB_PG_SUPERPASS}\"\n\"pgbouncer\" \"${stats_pass}\""
  else
    make_remote_file "$host" "${REMOTE_BASE}/userlist.txt" ""
  fi
  make_remote_file "$host" "${REMOTE_BASE}/docker-compose.yml" "$(compose_for_image "$image" "$host_ip")"

  ssh -o StrictHostKeyChecking=no root@"$host" "docker rm -f ${SERVICE_NAME} >/dev/null 2>&1 || true; sleep 0.5; docker compose -f ${REMOTE_BASE}/docker-compose.yml up -d >/dev/null 2>&1" || return 1
  ssh -o StrictHostKeyChecking=no root@"$host" "sleep 0.8; ss -ltnH | grep -q \"${host_ip}:${KB_PGB_LOCAL_PORT}\"" || return 1
  return 0
}

for px in "${PROXIES[@]}"; do
  echo "--- Proxy ${px} ---"
  IMG="$(select_pgbouncer_image_on_host "$px")"
  [ -n "$IMG" ] || { echo -e "  \033[0;31mKO\033[0m pull impossible pour toutes les images candidates"; exit 1; }
  echo -e "  \033[0;32mImage initiale:\033[0m ${IMG}"
  if try_up_with_image "$px" "$IMG" "$px"; then
    echo -e "  \033[0;32m✅ OK:\033[0m ${px} écoute sur :${KB_PGB_LOCAL_PORT}"
    continue
  fi
  echo -e "  \033[1;33m🟡 retry:\033[0m changement d'image…"
  ok=0
  for alt in "${IMG_PGBOUNCER_CANDIDATES[@]}"; do
    [ "$alt" = "$IMG" ] && continue
    echo "    → tentative avec ${alt}"
    if ssh -o StrictHostKeyChecking=no root@"$px" "docker pull ${alt} >/dev/null 2>&1"; then
      if try_up_with_image "$px" "$alt" "$px"; then
        echo -e "  \033[0;32m✅ OK:\033[0m ${px} écoute sur :${KB_PGB_LOCAL_PORT}"; ok=1; break
      fi
    else
      echo -e "    \033[1;33m(info)\033[0m pull impossible pour ${alt}"
    fi
  done
  [ "$ok" -eq 1 ] || { echo -e "  \033[0;31m❌ KO:\033[0m aucun déploiement PgBouncer fonctionnel sur ${px}"; exit 1; }
done

echo -e "\033[0;32m✅ OK:\033[0m PgBouncer (Docker) déployé et lié à l’IP privée de chaque proxy."
