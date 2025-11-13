#!/usr/bin/env bash
set -u; set -o pipefail
OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
SERVERS_TSV="${SERVERS_TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
PG_ENV="/opt/keybuzz-installer/credentials/postgres.env"
LB_VIP="${LB_VIP:-10.0.0.10}"
[ -f "$SERVERS_TSV" ] || { echo -e "$KO servers.tsv introuvable"; exit 2; }
[ -f "$PG_ENV" ] || { echo -e "$KO $PG_ENV introuvable"; exit 2; }
. "$PG_ENV"
get_ip(){ awk -F'\t' -v h="$1" '$2==h {print $3}' "$SERVERS_TSV" | head -1; }
H1="$(get_ip haproxy-01)"; H2="$(get_ip haproxy-02)"
[ -n "$POSTGRES_PASSWORD" ] || { echo -e "$KO POSTGRES_PASSWORD manquant"; exit 2; }
md5line(){ # $1 user $2 pass
  local H=$(echo -n "${2}${1}" | md5sum | awk '{print $1}')
  echo "\"$1\" \"md5$H\""
}
for IP in "$H1" "$H2"; do
  echo "Proxy $IP ..."
  ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'EOS'
set -u; set -o pipefail
BASE="/opt/keybuzz/pgbouncer"; CFG="$BASE/config"; BK="$BASE/backup/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$CFG" "$BK"
[ -f "$CFG/pgbouncer.ini" ] && cp -f "$CFG/pgbouncer.ini" "$BK/pgbouncer.ini" || true
[ -f "$CFG/userlist.txt" ]  && cp -f "$CFG/userlist.txt"  "$BK/userlist.txt"  || true
IP_PRIV="$(hostname -I | awk '{print $1}')"
cat > "$CFG/pgbouncer.ini" <<INI
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = ${IP_PRIV}
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 50
ignore_startup_parameters = extra_float_digits
server_tls_sslmode = disable
INI
: > "$CFG/userlist.txt"
EOS
  TMP=$(mktemp)
  {
    md5line postgres "$POSTGRES_PASSWORD"
    [ -n "${N8N_PASSWORD:-}" ]      && md5line n8n "$N8N_PASSWORD"
    [ -n "${CHATWOOT_PASSWORD:-}" ] && md5line chatwoot "$CHATWOOT_PASSWORD"
    [ -n "${PGBOUNCER_PASSWORD:-}" ] && md5line pgbouncer "$PGBOUNCER_PASSWORD"
  } > "$TMP"
  scp -o StrictHostKeyChecking=no "$TMP" root@"$IP":/opt/keybuzz/pgbouncer/config/userlist.txt >/dev/null 2>&1
  rm -f "$TMP"
  ssh -o StrictHostKeyChecking=no root@"$IP" 'docker ps | grep -q pgbouncer && docker restart pgbouncer >/dev/null 2>&1 || true; sleep 2'
done
echo -e "$OK MD5 appliqué (fallback). Teste: psql -h $LB_VIP -p 4632 -U postgres -d postgres -c "select 1""

