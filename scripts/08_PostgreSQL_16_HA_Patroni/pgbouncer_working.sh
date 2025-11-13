#!/usr/bin/env bash
set -u; set -o pipefail

KB_ROOT="/opt/keybuzz-installer"
TSV="$KB_ROOT/inventory/servers.tsv"
PGB="/opt/keybuzz/pgbouncer"
RW=5432; PGB_PORT=6432

get(){ awk -F'\t' -v H="$1" '$2==H{print $3}' "$TSV" | head -1; }
P1="$(get 'haproxy-01')"; P2="$(get 'haproxy-02')"
LEADER=""
for H in $(get 'db-master-01') $(get 'db-slave-01') $(get 'db-slave-02'); do
  C=$(ssh -o StrictHostKeyChecking=no "$H" "docker ps --format '{{.Names}}' | egrep 'patroni|postgres' | head -1 || true")
  [ -z "$C" ] && continue
  R=$(ssh -o StrictHostKeyChecking=no "$H" "docker exec -u postgres $C psql -At -c \"select case when pg_is_in_recovery() then 'replica' else 'leader' end;\" 2>/dev/null|head -1")
  [ "$R" = "leader" ] && { LEADER="$H"; break; }
done

# 1) secret backend pgbouncer sur le leader + rôle SQL
if [ -n "$LEADER" ]; then
  ssh -o StrictHostKeyChecking=no root@"$LEADER" 'mkdir -p /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer; \
    [ -s /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer/pgbouncer_secret ] || { umask 077; head -c 24 /dev/urandom | base64 > /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer/pgbouncer_secret; }; \
    C=$(docker ps --format "{{.Names}}" | egrep "patroni|postgres" | head -1 || true); \
    PW=$(cat /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer/pgbouncer_secret); \
    [ -n "$C" ] && docker exec -u postgres "$C" sh -lc "psql -c \"ALTER ROLE pgbouncer WITH LOGIN SUPERUSER PASSWORD '\''$PW'\'';\" >/dev/null 2>&1 || psql -c \"CREATE ROLE pgbouncer LOGIN SUPERUSER PASSWORD '\''$PW'\'';\" >/dev/null"'
fi

deploy_pgb() {
  local H="$1" IP="$2"
  ssh -o StrictHostKeyChecking=no root@"$H" "docker rm -f pgbouncer >/dev/null 2>&1 || true; mkdir -p $PGB"
  # compose
  ssh -o StrictHostKeyChecking=no root@"$H" "cat > $PGB/docker-compose.yml" <<YML
services:
  pgbouncer:
    image: brainsam/pgbouncer:latest
    container_name: pgbouncer
    restart: unless-stopped
    ports:
      - "$IP:$PGB_PORT:$PGB_PORT"
    volumes:
      - $PGB/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - $PGB/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    command: ["pgbouncer","/etc/pgbouncer/pgbouncer.ini"]
YML
  # ini
  ssh -o StrictHostKeyChecking=no root@"$H" "cat > $PGB/pgbouncer.ini" <<INI
[databases]
postgres = host=$IP port=$RW dbname=postgres
* = host=$IP port=$RW

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = $PGB_PORT
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_user = pgbouncer
auth_query = SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=\$1
pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = 5000
default_pool_size = 100
ignore_startup_parameters = extra_float_digits,options,search_path
admin_users = postgres
stats_users = pgbouncer
log_disconnections = 1
log_connections = 1
INI
  ssh -o StrictHostKeyChecking=no root@"$H" "chmod 640 $PGB/pgbouncer.ini; touch $PGB/userlist.txt; chmod 600 $PGB/userlist.txt"

  # secret leader → proxy
  if [ -n "$LEADER" ]; then
    scp -o StrictHostKeyChecking=no root@"$LEADER":/opt/keybuzz-installer/credentials/pgbouncer/pgbouncer/pgbouncer_secret \
      root@"$H":$PGB/pgbouncer.pass >/dev/null 2>&1
    ssh -o StrictHostKeyChecking=no root@"$H" "sed -i '/^\"pgbouncer\"/d' $PGB/userlist.txt; PW=\$(cat $PGB/pgbouncer.pass); printf '\"%s\" \"%s\"\\n' 'pgbouncer' \"\$PW\" | cat - $PGB/userlist.txt > $PGB/userlist.new && mv -f $PGB/userlist.new $PGB/userlist.txt"
  fi

  # run
  ssh -o StrictHostKeyChecking=no root@"$H" "docker compose -f $PGB/docker-compose.yml up -d >/dev/null 2>&1; sleep 1; ss -ltnH | grep -q \"$IP:$PGB_PORT\" && echo \"[$H] OK pgbouncer écoute\" || echo \"[$H] KO pgbouncer écoute\""
}

deploy_pgb "$P1" "$P1"
[ -n "$P2" ] && [ "$P2" != "$P1" ] && deploy_pgb "$P2" "$P2"
