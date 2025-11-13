#!/usr/bin/env bash
set -u
set -o pipefail
OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; INF='\033[1;33mINFO\033[0m'

SCRIPT_NAME="pg_auth_probe_and_userlist_refresh"
LOG_DIR="/opt/keybuzz-installer/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

get_ip(){ awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }
say_ok(){ echo -e "$OK $*"; }
say_ko(){ echo -e "$KO $*"; }
say_inf(){ echo -e "$INF $*"; }

P1="$(get_ip 'haproxy-01')"; P2="$(get_ip 'haproxy-02')"
DB1="$(get_ip 'db-master-01')"; DB2="$(get_ip 'db-slave-01')"; DB3="$(get_ip 'db-slave-02')"
[ -n "$P1" ] && [ -n "$P2" ] && [ -n "$DB1" ] && [ -n "$DB2" ] && [ -n "$DB3" ] || { say_ko "Inventaire incomplet ($SERVERS_TSV)"; exit 1; }

# Leader Patroni
LEADER_IP=""
[ -f "${KB_PATRONI_LEADER_FILE}" ] && LEADER_IP="$(cat "${KB_PATRONI_LEADER_FILE}" 2>/dev/null || true)"
if [ -z "$LEADER_IP" ]; then
  for ip in "$DB1" "$DB2" "$DB3"; do
    out="$(ssh -o StrictHostKeyChecking=no root@"$ip" "curl -s --max-time 2 http://127.0.0.1:${KB_PATRONI_PORT:-8008}/patroni" 2>/dev/null || true)"
    echo "$out" | grep -q '"role"[[:space:]]*:[[:space:]]*"leader"' && { LEADER_IP="$ip"; break; }
  done
fi
[ -n "$LEADER_IP" ] || { say_ko "Leader Patroni introuvable"; exit 1; }
say_ok "Leader Patroni: $LEADER_IP"

# Helper psql (client éphémère docker)
psql_run(){ # host sql -> RC / prints stdout
  local host="$1" sql="$2"; ssh -o StrictHostKeyChecking=no root@"$host" \
   "docker run --rm --network host -e PGPASSWORD='${KB_PG_SUPERPASS}' postgres:16-alpine psql -h 127.0.0.1 -p ${KB_PG_NATIVE_PORT:-5432} -U ${KB_PG_SUPERUSER:-postgres} -d postgres -At -v ON_ERROR_STOP=1 -c \"$sql\"" 2>>"$LOG"
}

# 1) Tests directs Postgres (sans PgBouncer)
SQL_PING="select current_user || ' ' || now();"
if psql_run "$LEADER_IP" "$SQL_PING" >/dev/null; then say_ok "Direct leader SQL OK (auth superuser)"; DIRECT_OK=1; else say_ko "Direct leader SQL KO (auth ?)"; DIRECT_OK=0; fi

VIP_RW_OK=0
if nc -z -w 2 "$P1" 5432 && PSQL_VIA_P1="$(ssh -o StrictHostKeyChecking=no root@"$P1" "docker run --rm --network host -e PGPASSWORD='${KB_PG_SUPERPASS}' postgres:16-alpine psql -h ${P1} -p 5432 -U ${KB_PG_SUPERUSER:-postgres} -d postgres -At -c \"$SQL_PING\"" 2>>"$LOG")"; then
  say_ok "HAProxy RW $P1:5432 OK"
  VIP_RW_OK=1
else
  say_ko "HAProxy RW $P1:5432 KO"
fi
if nc -z -w 2 "$P2" 5432 && PSQL_VIA_P2="$(ssh -o StrictHostKeyChecking=no root@"$P2" "docker run --rm --network host -e PGPASSWORD='${KB_PG_SUPERPASS}' postgres:16-alpine psql -h ${P2} -p 5432 -U ${KB_PG_SUPERUSER:-postgres} -d postgres -At -c \"$SQL_PING\"" 2>>"$LOG")"; then
  say_ok "HAProxy RW $P2:5432 OK"
  VIP_RW_OK=$((VIP_RW_OK+1))
else
  say_ko "HAProxy RW $P2:5432 KO"
fi

if [ "$DIRECT_OK" -eq 0 ]; then
  say_ko "Auth superuser KO en direct → invalidera forcément PgBouncer. Vérifie le secret superuser dans .env."
  exit 1
fi

# 2) Tests via PgBouncer (backends puis LB)
TMPPASS="$(mktemp)"; chmod 600 "$TMPPASS"
printf "%s\n" "${P1}:${KB_PGB_LOCAL_PORT}:${KB_PG_DBNAME}:${KB_PG_SUPERUSER}:${KB_PG_SUPERPASS}" >"$TMPPASS"
printf "%s\n" "${P2}:${KB_PGB_LOCAL_PORT}:${KB_PG_DBNAME}:${KB_PG_SUPERUSER}:${KB_PG_SUPERPASS}" >>"$TMPPASS"
printf "%s\n" "${KB_VIP_IP}:${KB_PGB_VIP_PORT}:${KB_PG_DBNAME}:${KB_PG_SUPERUSER}:${KB_PG_SUPERPASS}" >>"$TMPPASS"
export PGPASSFILE="$TMPPASS"

SQL1="select now();"
VIA_P1=$(psql "host=${P1} port=${KB_PGB_LOCAL_PORT} dbname=${KB_PG_DBNAME} user=${KB_PG_SUPERUSER} sslmode=disable" -At -c "$SQL1" 2>/dev/null || true)
[ -n "$VIA_P1" ] && say_ok "PgBouncer SQL via $P1:${KB_PGB_LOCAL_PORT}" || say_ko "PgBouncer SQL via $P1:${KB_PGB_LOCAL_PORT} KO"

VIA_P2=$(psql "host=${P2} port=${KB_PGB_LOCAL_PORT} dbname=${KB_PG_DBNAME} user=${KB_PG_SUPERUSER} sslmode=disable" -At -c "$SQL1" 2>/dev/null || true)
[ -n "$VIA_P2" ] && say_ok "PgBouncer SQL via $P2:${KB_PGB_LOCAL_PORT}" || say_ko "PgBouncer SQL via $P2:${KB_PGB_LOCAL_PORT} KO"

VIA_LB=$(psql "host=${KB_VIP_IP} port=${KB_PGB_VIP_PORT} dbname=${KB_PG_DBNAME} user=${KB_PG_SUPERUSER} sslmode=disable" -At -c "$SQL1" 2>/dev/null || true)
[ -n "$VIA_LB" ] && say_ok "PgBouncer SQL via LB ${KB_VIP_IP}:${KB_PGB_VIP_PORT}" || say_ko "PgBouncer SQL via LB ${KB_VIP_IP}:${KB_PGB_VIP_PORT} KO"

# 3) Remédiation si direct OK mais PgBouncer KO : reconstruire userlist SCRAM
if [ "$DIRECT_OK" -eq 1 ] && [ -z "$VIA_P1$VIA_P2$VIA_LB" ]; then
  say_inf "Direct OK mais PgBouncer KO → (re)génération userlist SCRAM depuis le leader."
  SQL_VERIFIERS=$'WITH u AS (\n SELECT rolname AS usename, rolpassword AS passwd FROM pg_authid WHERE rolcanlogin AND rolpassword LIKE \'SCRAM-SHA-256%\' ) SELECT usename, passwd FROM u WHERE usename IN (\'postgres\',\'pgbouncer\',\'n8n\',\'chatwoot\');'
  VERIFIERS="$(psql_run "$LEADER_IP" "$SQL_VERIFIERS" || true)"
  if [ -z "$VERIFIERS" ]; then
    say_ko "Aucun verifier SCRAM récupéré (comptes non migrés en SCRAM ?)"
    rm -f "$TMPPASS"; exit 1
  fi
  USERLIST="$(printf "%s\n" "$VERIFIERS" | awk -F'|' 'NF==2{gsub(/^ +| +$/,"",$1);gsub(/^ +| +$/,"",$2);print "\""$1"\" \""$2"\""}')"

  update_proxy(){
    local host="$1" ip="$2" base="/opt/keybuzz/pgbouncer"
    # pgbouncer.ini : écoute conteneur 0.0.0.0, publication IP:6432:6432 déjà faite par deploy_*
    # on ne modifie que userlist + restart
    printf "%s" "$USERLIST" | base64 -w0 | ssh -o StrictHostKeyChecking=no root@"$host" "base64 -d > ${base}/userlist.txt"
    ssh -o StrictHostKeyChecking=no root@"$host" "chmod 600 ${base}/userlist.txt; docker compose -f ${base}/docker-compose.yml up -d" >>"$LOG" 2>&1
    # retest rapide
    psql "host=${host} port=${KB_PGB_LOCAL_PORT} dbname=${KB_PG_DBNAME} user=${KB_PG_SUPERUSER} sslmode=disable" -At -c "$SQL1" >/dev/null 2>&1 \
      && say_ok "PgBouncer SQL OK après refresh sur ${host}" \
      || say_ko "PgBouncer toujours KO après refresh sur ${host} (voir logs conteneur)"
  }
  update_proxy "$P1" "$P1"
  update_proxy "$P2" "$P2"
fi

rm -f "$TMPPASS"
say_ok "Probe terminé."
