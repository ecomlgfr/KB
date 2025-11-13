#!/usr/bin/env bash
set -u
set -o pipefail
OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; INF='\033[1;33mINFO\033[0m'

SCRIPT_NAME="pgbouncer_scram_doctor"
LOG_DIR="/opt/keybuzz-installer/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
STATUS_DIR="/opt/keybuzz/pgbouncer/status"; mkdir -p "$STATUS_DIR"

cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                     PGBOUNCER_SCRAM_DOCTOR                         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

get_ip(){ awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }
say_ok(){ echo -e "$OK $*"; }; say_ko(){ echo -e "$KO $*"; }; say_inf(){ echo -e "$INF $*"; }

P1="$(get_ip 'haproxy-01')"; P2="$(get_ip 'haproxy-02')"
DB1="$(get_ip 'db-master-01')"; DB2="$(get_ip 'db-slave-01')"; DB3="$(get_ip 'db-slave-02')"
[ -n "$P1" ] && [ -n "$P2" ] && [ -n "$DB1" ] && [ -n "$DB2" ] && [ -n "$DB3" ] || { say_ko "Inventaire incomplet"; echo "KO" > "$STATUS_DIR/STATE"; exit 1; }

# Leader Patroni
LEADER_IP=""
[ -f "${KB_PATRONI_LEADER_FILE}" ] && LEADER_IP="$(cat "${KB_PATRONI_LEADER_FILE}" 2>/dev/null || true)"
if [ -z "$LEADER_IP" ]; then
  for ip in "$DB1" "$DB2" "$DB3"; do
    out="$(ssh -o StrictHostKeyChecking=no root@"$ip" "curl -s --max-time 2 http://127.0.0.1:${KB_PATRONI_PORT:-8008}/patroni" 2>/dev/null || true)"
    echo "$out" | grep -q '"role"[[:space:]]*:[[:space:]]*"leader"' && { LEADER_IP="$ip"; break; }
  done
fi
[ -n "$LEADER_IP" ] || { say_ko "Leader Patroni introuvable"; echo "KO" > "$STATUS_DIR/STATE"; exit 1; }
say_ok "Leader Patroni: $LEADER_IP"

# Vérifs écoute actuelles
for host in "$P1" "$P2"; do
  if ssh -o StrictHostKeyChecking=no root@"$host" "ss -ltnH | grep -q \":${KB_PGB_LOCAL_PORT}\""; then
    say_ok "PgBouncer écoute (quelque part) sur $host:${KB_PGB_LOCAL_PORT}"
  else
    say_ko "PgBouncer n'écoute pas sur $host:${KB_PGB_LOCAL_PORT}"
  fi
done

# Récup verifiers SCRAM via client éphémère si besoin
psql_on_leader(){ local sql="$1" host="$2"; ssh -o StrictHostKeyChecking=no root@"$host" "docker run --rm --network host -e PGPASSWORD='${KB_PG_SUPERPASS}' postgres:16-alpine psql -h 127.0.0.1 -p ${KB_PG_NATIVE_PORT:-5432} -U ${KB_PG_SUPERUSER:-postgres} -d postgres -At -v ON_ERROR_STOP=1 -c \"$sql\"" 2>>"$LOG"; }

SQL_VERIFIERS=$'WITH u AS (\n SELECT rolname AS usename, rolpassword AS passwd FROM pg_authid WHERE rolcanlogin AND rolpassword LIKE \'SCRAM-SHA-256%\' ) SELECT usename, passwd FROM u WHERE usename IN (\'postgres\',\'pgbouncer\',\'n8n\',\'chatwoot\');'
VERIFIERS="$(psql_on_leader "$SQL_VERIFIERS" "$LEADER_IP" || true)"
[ -n "$VERIFIERS" ] || { say_ko "Aucun verifier SCRAM récupéré (migration SCRAM requise)"; echo "KO" > "$STATUS_DIR/STATE"; exit 1; }
say_ok "SCRAM verifiers récupérés."

USERLIST="$(printf "%s\n" "$VERIFIERS" | awk -F'|' 'NF==2{gsub(/^ +| +$/,"",$1);gsub(/^ +| +$/,"",$2);print "\""$1"\" \""$2"\""}')"

gen_ini(){
  local proxy_ip="$1"
  cat <<EOF
[databases]
* = host=${proxy_ip} port=5432
[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${KB_PGB_LOCAL_PORT}
auth_type = scram-sha-256
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
}

fix_compose_binding(){
  local host="$1" ip="$2" base="/opt/keybuzz/pgbouncer"
  # Remplace toute entrée 'ports:' non qualifiée par "IP:port:port"
  ssh -o StrictHostKeyChecking=no root@"$host" bash <<EOS >>"$LOG" 2>&1
set -u; set -o pipefail
f="${base}/docker-compose.yml"
if [ -f "\$f" ]; then
  # Si une ligne ' - "6432:6432"' existe, on la remplace par ' - "${ip}:${KB_PGB_LOCAL_PORT}:${KB_PGB_LOCAL_PORT}"'
  sed -i 's#- *\"\{0,1\}[0-9]\{4,5\}:[0-9]\{4,5\}\"#- "${ip}:${KB_PGB_LOCAL_PORT}:${KB_PGB_LOCAL_PORT}"#g' "\$f"
fi
EOS
}

apply_proxy(){
  local host="$1" ip="$2" base="/opt/keybuzz/pgbouncer" ts; ts="$(date +%Y%m%d_%H%M%S)"
  ssh -o StrictHostKeyChecking=no root@"$host" "mkdir -p ${base}; [ -f ${base}/pgbouncer.ini ] && cp -f ${base}/pgbouncer.ini ${base}/pgbouncer.ini.bak.${ts} || true; [ -f ${base}/userlist.txt ] && cp -f ${base}/userlist.txt ${base}/userlist.txt.bak.${ts} || true" >>"$LOG" 2>&1
  printf "%s" "$(gen_ini "$ip")" | base64 -w0 | ssh -o StrictHostKeyChecking=no root@"$host" "base64 -d > ${base}/pgbouncer.ini"
  printf "%s" "$USERLIST" | base64 -w0 | ssh -o StrictHostKeyChecking=no root@"$host" "base64 -d > ${base}/userlist.txt"
  ssh -o StrictHostKeyChecking=no root@"$host" "chmod 640 ${base}/pgbouncer.ini; chmod 600 ${base}/userlist.txt" >>"$LOG" 2>&1

  fix_compose_binding "$host" "$ip"

  ssh -o StrictHostKeyChecking=no root@"$host" "docker compose -f ${base}/docker-compose.yml up -d" >>"$LOG" 2>&1
  if ssh -o StrictHostKeyChecking=no root@"$host" "ss -ltnH | grep -q \"${ip}:${KB_PGB_LOCAL_PORT}\""; then
    say_ok "PgBouncer écoute sur ${ip}:${KB_PGB_LOCAL_PORT}"
  else
    # Aide au diagnostic si bind 0.0.0.0 détecté
    if ssh -o StrictHostKeyChecking=no root@"$host" "ss -ltnH | grep -q \"0.0.0.0:${KB_PGB_LOCAL_PORT}\""; then
      say_ko "Bind host sur 0.0.0.0:${KB_PGB_LOCAL_PORT} (compose non IP-qualifié). Compose corrigé, relance en cours."
      ssh -o StrictHostKeyChecking=no root@"$host" "docker compose -f ${base}/docker-compose.yml up -d" >>"$LOG" 2>&1
      ssh -o StrictHostKeyChecking=no root@"$host" "sleep 0.8; ss -ltnH | grep -q \"${ip}:${KB_PGB_LOCAL_PORT}\"" && say_ok "PgBouncer écoute OK après correction" || { say_ko "Toujours pas d'écoute IP-spécifique"; tail -n 50 "$LOG" || true; echo "KO" > "$STATUS_DIR/STATE"; exit 1; }
    else
      say_ko "PgBouncer n'écoute pas sur ${ip}:${KB_PGB_LOCAL_PORT}"
      tail -n 50 "$LOG" || true; echo "KO" > "$STATUS_DIR/STATE"; exit 1
    fi
  fi
}

# --- Appliquer proxies ---
apply_proxy "$P1" "$P1"
apply_proxy "$P2" "$P2"

# --- Rappel LB ---
nc -z -w 2 "${KB_VIP_IP}" "${KB_PGB_VIP_PORT}" >/dev/null 2>&1 && say_ok "LB TCP ${KB_VIP_IP}:${KB_PGB_VIP_PORT}" || say_ko "LB ${KB_VIP_IP}:${KB_PGB_VIP_PORT} indisponible"

echo "OK" > "$STATUS_DIR/STATE"
say_ok "Doctor terminé."
tail -n 50 "$LOG" || true
