#!/usr/bin/env bash
set -u
set -o pipefail
OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; INF='\033[1;33mINFO\033[0m'

cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

echo "╔═════════════════════════════════════════════════╗"
echo "║     PGBOUNCER END-TO-END DEBUG (LB Hetzner)     ║"
echo "╚═════════════════════════════════════════════════╝"
echo "LB VIP : ${KB_VIP_IP}:${KB_PGB_VIP_PORT}  (Hetzner)"
echo "Backends: haproxy-01:${KB_PGB_LOCAL_PORT} ; haproxy-02:${KB_PGB_LOCAL_PORT}"
echo "DB/name : ${KB_PG_SUPERUSER}@${KB_PG_DBNAME}"

# IPs privées depuis servers.tsv
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
get_ip(){ awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }
P1="$(get_ip 'haproxy-01')"; P2="$(get_ip 'haproxy-02')"

# 1) Backends TCP
for host in "$P1" "$P2"; do
  if nc -z -w 2 "$host" "${KB_PGB_LOCAL_PORT}"; then
    echo -e "  $OK Backend TCP : $host:${KB_PGB_LOCAL_PORT}"
  else
    echo -e "  $KO Backend TCP : $host:${KB_PGB_LOCAL_PORT}"
  fi
done

for host in "$P1" "$P2"; do
  if nc -z -w 2 "$host" 5432; then
    echo -e "  \033[0;32mOK\033[0m HAProxy RW : $host:5432"
  else
    echo -e "  \033[0;31mKO\033[0m HAProxy RW : $host:5432"
  fi
done

# 2) LB TCP
if nc -z -w 2 "${KB_VIP_IP}" "${KB_PGB_VIP_PORT}"; then
  echo -e "  $OK LB TCP : ${KB_VIP_IP}:${KB_PGB_VIP_PORT}"
else
  echo -e "  $KO LB TCP : ${KB_VIP_IP}:${KB_PGB_VIP_PORT}"; exit 2
fi

# 3) SQL via LB
TMPPASS="$(mktemp)"; chmod 600 "$TMPPASS"
printf "%s:%s:%s:%s:%s\n" "${KB_VIP_IP}" "${KB_PGB_VIP_PORT}" "${KB_PG_DBNAME}" "${KB_PG_SUPERUSER}" "${KB_PG_SUPERPASS}" > "$TMPPASS"
export PGPASSFILE="$TMPPASS"

psql "host=${KB_VIP_IP} port=${KB_PGB_VIP_PORT} dbname=${KB_PG_DBNAME} user=${KB_PG_SUPERUSER} sslmode=disable" -t -A -c "select now(), current_user;" >/dev/null 2>&1 \
  && echo -e "  $OK SQL via LB" || echo -e "  $KO SQL via LB"

# 4) SQL direct via chaque backend PgBouncer (pour isoler auth/confs)
for host in "$P1" "$P2"; do
  psql "host=${host} port=${KB_PGB_LOCAL_PORT} dbname=${KB_PG_DBNAME} user=${KB_PG_SUPERUSER} sslmode=disable" -t -A -c "select 1;" >/dev/null 2>&1 \
    && echo -e "  $OK SQL via $host:${KB_PGB_LOCAL_PORT}" \
    || echo -e "  $KO SQL via $host:${KB_PGB_LOCAL_PORT}"
done

rm -f "$TMPPASS"
echo "Fin debug."
