#!/usr/bin/env bash
# KeyBuzz - Orchestrateur SCRAM pour PgBouncer (Docker + LB Hetzner)
# Règles: set -u + pipefail, IPs depuis servers.tsv, pas de secrets en clair
set -u
set -o pipefail

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
INF='\033[1;33mINFO\033[0m'

SCRIPT_NAME="pgbouncer_scram_orchestrator"
LOG_DIR="/opt/keybuzz-installer/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
STATUS_DIR="/opt/keybuzz/pgbouncer/status"; mkdir -p "$STATUS_DIR"

cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║             PGBOUNCER_SCRAM_ORCHESTRATOR  (Docker)                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

# -- helpers --
get_ip() { awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }

PROXY1_IP="$(get_ip 'haproxy-01')"
PROXY2_IP="$(get_ip 'haproxy-02')"
DB1_IP="$(get_ip 'db-master-01')"
DB2_IP="$(get_ip 'db-slave-01')"
DB3_IP="$(get_ip 'db-slave-02')"

if [ -z "${PROXY1_IP}" ] || [ -z "${PROXY2_IP}" ] || [ -z "${DB1_IP}" ] || [ -z "${DB2_IP}" ] || [ -z "${DB3_IP}" ]; then
  echo -e "$KO Inventaire incomplet dans $SERVERS_TSV" | tee -a "$LOG"
  echo "KO" > "$STATUS_DIR/STATE"; tail -n 50 "$LOG" || true; exit 1
fi

# ---- 1) Détecter le leader Patroni ----
LEADER_IP=""
if [ -f "${KB_PATRONI_LEADER_FILE}" ]; then
  LEADER_IP="$(cat "${KB_PATRONI_LEADER_FILE}" 2>/dev/null || true)"
fi
if [ -z "${LEADER_IP}" ]; then
  for ip in "$DB1_IP" "$DB2_IP" "$DB3_IP"; do
    out="$(ssh -o StrictHostKeyChecking=no root@"$ip" "curl -s --max-time 2 http://127.0.0.1:${KB_PATRONI_PORT:-8008}/patroni" 2>/dev/null || true)"
    echo "$out" | grep -q '"role"[[:space:]]*:[[:space:]]*"leader"' && { LEADER_IP="$ip"; break; }
  done
fi
if [ -z "${LEADER_IP}" ]; then
  echo -e "$KO Leader Patroni introuvable" | tee -a "$LOG"
  echo "KO" > "$STATUS_DIR/STATE"; tail -n 50 "$LOG" || true; exit 1
fi
echo -e "$OK Leader Patroni: $LEADER_IP" | tee -a "$LOG"

# ---- 2) Extraire les verifiers SCRAM depuis le leader (sans afficher PGPASSWORD) ----
# on ne garde que les rôles utiles et les verifiers SCRAM
SQL_USERS=$'WITH u AS (\n  SELECT rolname AS usename, rolpassword AS passwd\n  FROM pg_authid\n  WHERE rolcanlogin\n    AND rolpassword LIKE \'SCRAM-SHA-256%\'\n    AND rolname IN (\'postgres\',\'pgbouncer\',\'n8n\',\'chatwoot\')\n)\nSELECT usename, passwd FROM u;'

TMP_VERIFIERS="$(mktemp)"
# passage explicite des variables au remote; aucune impression de secret dans les logs
if ! ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" \
  "LC_ALL=C PGPASSWORD='${KB_PG_SUPERPASS}' psql -h 127.0.0.1 -p ${KB_PG_NATIVE_PORT:-5432} -U ${KB_PG_SUPERUSER:-postgres} -d postgres -At -v ON_ERROR_STOP=1 -c \"${SQL_USERS}\"" \
  >"$TMP_VERIFIERS" 2>>"$LOG"; then
  echo -e "$KO Échec psql sur le leader (auth ou droits). Voir log." | tee -a "$LOG"
  echo "KO" > "$STATUS_DIR/STATE"; tail -n 50 "$LOG" || true; rm -f "$TMP_VERIFIERS"; exit 1
fi

if ! [ -s "$TMP_VERIFIERS" ]; then
  echo -e "$KO Aucun verifier SCRAM récupéré (peut-être md5 encore actif ?). Voir log." | tee -a "$LOG"
  echo "KO" > "$STATUS_DIR/STATE"; tail -n 50 "$LOG" || true; rm -f "$TMP_VERIFIERS"; exit 1
fi

# ---- 3) Construire userlist.txt (SCRAM) ----
build_userlist() {
  awk -F'|' 'NF==2 {
    gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$2);
    # on sort "user" "SCRAM-SHA-256$...."
    print "\"" $1 "\" \"" $2 "\""
  }' "$TMP_VERIFIERS"
}
USERLIST_CONTENT="$(build_userlist)"

# ---- 4) Générer pgbouncer.ini par proxy (bind IP privée, cible HAProxy local 5432) ----
generate_pgb_ini_for_proxy() {
  local proxy_ip="$1"
  cat <<EOF
[databases]
* = host=${proxy_ip} port=5432

[pgbouncer]
listen_addr = ${proxy_ip}
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

apply_on_proxy() {
  local host_ip="$1" proxy_ip="$2"
  local remote_base="/opt/keybuzz/pgbouncer"
  local ini_tmp; ini_tmp="$(mktemp)"
  generate_pgb_ini_for_proxy "$proxy_ip" > "$ini_tmp"

  # sauvegardes et push
  ssh -o StrictHostKeyChecking=no root@"$host_ip" bash <<'EOS' >>"$LOG" 2>&1
set -u; set -o pipefail
remote_base="/opt/keybuzz/pgbouncer"
mkdir -p "$remote_base"
ts=$(date +%Y%m%d_%H%M%S)
[ -f "$remote_base/pgbouncer.ini" ]  && cp -f "$remote_base/pgbouncer.ini"  "$remote_base/pgbouncer.ini.bak.$ts"  || true
[ -f "$remote_base/userlist.txt" ]   && cp -f "$remote_base/userlist.txt"   "$remote_base/userlist.txt.bak.$ts"   || true
EOS

  base64 -w0 "$ini_tmp" | ssh -o StrictHostKeyChecking=no root@"$host_ip" "base64 -d > ${remote_base}/pgbouncer.ini"
  base64 -w0 <(printf "%s" "$USERLIST_CONTENT") | ssh -o StrictHostKeyChecking=no root@"$host_ip" "base64 -d > ${remote_base}/userlist.txt"
  ssh -o StrictHostKeyChecking=no root@"$host_ip" "chmod 640 ${remote_base}/pgbouncer.ini; chmod 600 ${remote_base}/userlist.txt" >>"$LOG" 2>&1

  # redémarrage conteneur existant (compose déjà en place via deploy_*)
  ssh -o StrictHostKeyChecking=no root@"$host_ip" "docker compose -f ${remote_base}/docker-compose.yml up -d" >>"$LOG" 2>&1

  # health check: bind IP privée sur :6432
  if ssh -o StrictHostKeyChecking=no root@"$host_ip" "ss -ltnH | grep -q \"${proxy_ip}:${KB_PGB_LOCAL_PORT}\""; then
    echo -e "$OK PgBouncer écoute sur ${proxy_ip}:${KB_PGB_LOCAL_PORT}" | tee -a "$LOG"
  else
    echo -e "$KO PgBouncer n'écoute pas sur ${proxy_ip}:${KB_PGB_LOCAL_PORT}" | tee -a "$LOG"
    tail -n 50 "$LOG" || true
    rm -f "$ini_tmp"; echo "KO" > "$STATUS_DIR/STATE"; exit 1
  fi
  rm -f "$ini_tmp"
}

apply_on_proxy "$PROXY1_IP" "$PROXY1_IP"
apply_on_proxy "$PROXY2_IP" "$PROXY2_IP"

# ---- 5) Nettoyage & état ----
rm -f "$TMP_VERIFIERS"
echo "OK" > "$STATUS_DIR/STATE"
echo -e "$OK Orchestration SCRAM terminée"
tail -n 50 "$LOG" || true
