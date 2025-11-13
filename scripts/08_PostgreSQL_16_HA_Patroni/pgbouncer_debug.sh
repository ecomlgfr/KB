#!/usr/bin/env bash
set -u
set -o pipefail
OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'
SERVERS_TSV="${SERVERS_TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
PG_ENV="${PG_ENV:-/opt/keybuzz-installer/credentials/postgres.env}"
LB_VIP="${LB_VIP:-10.0.0.10}"
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                    PGBOUNCER DEBUG - Quick Check                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
[ -f "$SERVERS_TSV" ] || { echo -e "$KO servers.tsv manquant"; exit 2; }
[ -f "$PG_ENV" ] || { echo -e "$KO postgres.env manquant"; exit 2; }
. "$PG_ENV"
get_ip(){ awk -F'\t' -v h="$1" '$2==h {print $3}' "$SERVERS_TSV" | head -1; }
H1="$(get_ip haproxy-01)"; H2="$(get_ip haproxy-02)"

echo "1) LB VIP ..."
nc -z "$LB_VIP" 5432 && echo -e "  VIP $LB_VIP:5432 $OK" || echo -e "  VIP $LB_VIP:5432 $KO"
nc -z "$LB_VIP" 4632 && echo -e "  VIP $LB_VIP:4632 $OK" || echo -e "  VIP $LB_VIP:4632 $KO"

echo "2) HAProxy loopback ..."
for IP in "$H1" "$H2"; do
  echo "  Proxy $IP"
  ssh -o StrictHostKeyChecking=no root@"$IP" "nc -z 127.0.0.1 5432" >/dev/null 2>&1 && echo "    127.0.0.1:5432 $OK" || echo "    127.0.0.1:5432 $WARN"
done

echo "3) Patroni roles ..."
for DB in db-master-01 db-slave-01 db-slave-02; do
  IP="$(get_ip "$DB")"; ROLE="$(curl -s "http://$IP:8008/patroni" | sed -n 's/.*"role":"\([^"]*\)".*/\1/p')"
  echo "  $DB ($IP) : ${ROLE:-?}"
done

echo "4) Users SCRAM ..."
docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 \
  psql -h "$LB_VIP" -p 5432 -U postgres -d postgres -Atc \
  "SELECT rolname, (rolpassword LIKE 'SCRAM-SHA-256%') scram FROM pg_authid WHERE rolname IN ('postgres','n8n','chatwoot','pgbouncer');" \
  | sed 's/t/YES/;s/f/NO/' | awk '{printf "  %-10s : %s\n",$1,$2}'

echo "5) Tests psql ..."
docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 psql -h "$LB_VIP" -p 5432 -U postgres -d postgres -Atc "select 1" >/dev/null 2>&1 && echo -e "  VIP 5432 : $OK" || echo -e "  VIP 5432 : $KO"
docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 psql -h "$H1" -p 6432 -U postgres -d postgres -Atc "select 1" >/dev/null 2>&1 && echo -e "  $H1:6432 : $OK" || echo -e "  $H1:6432 : $KO"
docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 psql -h "$LB_VIP" -p 4632 -U postgres -d postgres -Atc "select 1" >/dev/null 2>&1 && echo -e "  VIP 4632 : $OK" || echo -e "  VIP 4632 : $KO"
echo -e "$OK Fin debug"
