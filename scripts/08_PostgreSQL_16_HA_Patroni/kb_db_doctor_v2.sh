#!/usr/bin/env bash
# KeyBuzz DB Suite – PgBouncer/HAProxy/Patroni doctor (V2)
# no-interactive • idempotent • private IPs • SCRAM + auth_query • no 'set -e'
set +e
set -u
set -o pipefail

OK=$'\033[0;32mOK\033[0m'; KO=$'\033[0;31mKO\033[0m'; INF=$'\033[1;33mINFO\033[0m'

ROOT="/opt/keybuzz-installer"
LOG_DIR="$ROOT/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/kb_db_doctor_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

SERVERS_TSV="$ROOT/inventory/servers.tsv"
PG_ENV="$ROOT/credentials/postgres.env"
PGB_DIR="/opt/keybuzz/pgbouncer"
PGB_LOCAL_PORT="${KB_PGB_LOCAL_PORT:-6432}"
RWPORT="${KB_PG_NATIVE_PORT:-5432}"
ROPORT="${KB_PG_RO_PORT:-5433}"
VIP="${KB_PG_VIP_IP:-10.0.0.10}"
HP_CHK=8008
HP_STATS=8404

get_ip(){ awk -t -F'\t' -v H="$1" '$2==H{print $3}' "$SERVERS_TSV" | head -1; }

P1="$(get_ip 'haproxy-01')"
P2="$(get_ip 'haproxy-02')"
DB1="$(get_ip 'db-master-01')"
DB2="$(get_ip 'db-slave-01')"
DB3="$(get_ip 'db-slave-02')"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   KeyBuzz DB Suite Doctor – PgBouncer/HAProxy/Patroni (TCP)    "
echo "║   no-interactive • idempotent • private IPs • SCRAM+auth_query "
echo "╚════════════════════════════════════════════════════════════════╝"
echo "$INF Propos: P1=$P1  P2=$P2  |  DBs: $DB1/$DB2/$DB3  |  VIP=$VIP  PGB=$PGB_LOCAL_PORT  RW=$RWPORT RO=$ROPORT  HC=$HP_CHK"

# ----- 0) detect leader inside containers (psql -> pg_is_in_recovery) -----
detect_leader() {
  for H in "$DB1" "$DB2" "$DB3"; do
    C=$(ssh -o StrictHostKeyChecking=no "$H" "docker ps --format '{{.Names}}' | egrep 'patroni|postgres' | head -1 || true")
    if [ -n "$C" ]; then
      R=$(ssh -o StrictHostKeyChecking=no "$H" "docker exec -u postgres $C psql -At -c \"select case when pg_is_in_recovery() then 'replica' else 'leader' end;\" 2>/dev/null | head -1")
      if [ "$R" = "leader" ]; then echo "$H"; return; fi
    fi
  done
  echo ""
}
LEADER=$(detect_leader)
if [ -z "$LEADER" ]; then echo "$KO Impossible d'identifier un leader (pg_is_recovery). On continue mais la MAJ du rôle pgbouncer sera sautée."; else echo "$OK Leader: $LEADER"; fi

# ----- 1) open pg_hba on all DBs (add 127.0.0.1/32, ::1/128, 10.0.0.0/16, 172.16.0.0/12, replication) -----
patch_hba() {
  local H="$1"
  echo "→ Patch pg_hba @$H"
  ssh -o StrictHostKeyChecking=no "$H" '
    C=$(docker ps --format "{{.Names}}" | egrep "patroni|postgres" | head -1 || true)
    [ -n "$C" ] || { echo "  '"$KO"' no container"; exit 0; }
    docker exec -u postgres "$C" sh -lc "
      set -eu
      HBA=\$(psql -At -c \"show hba_file;\")
      echo \"  hba: \$HBA\"
      cp \"\$HBA\" \"\$HBA.bak.$(date +%Y%m%d_%H%M%S)\" || true
      add(){ grep -Fq \"$1\" \"\$HBA\" || echo \"$1\" >> \"\$HBA\"; }
      add \"host    all             all             127.0.0.1/32            scram-sha-256\"
      add \"host    all             all             ::1/128                 scram-sha-256\"
      add \"host    all             all             10.0.0.0/16             scram-sha-256\"
      add \"host    all             all             172.16.0.0/12           scram-sha-256\"
      add \"host    replication     replicator      10.0.0.0/16             scram-sha-256\"
      psql -c \"select pg_reload_conf();\"
    " >/dev/null && echo "  '"$OK"' reload" || echo "  '"$KO"' reload"
  '
}
for H in "$DB1" "$DB2" "$DB3"; do patch_hba "$H"; done

# ----- 2) HAProxy config (mode tcp + tcp-check HTTP on Port 8008) -----
patch_haproxy() {
  local HOST="$1" IP="$2"
  echo "→ Patch HAProxy @$HOST"
  ssh -o StrictHostKeyChecking=no "$HOST" "
    B=/opt/keybuzz/haproxy; CFG=\$B/haproxy.cfg; mkdir -p \"\$B\";
    cp -f \"\$CFG\" \"\$CFG.bak.\$(date +%Y%m%d_%H%M%S)\" 2>/dev/null || true
    cat >\"\$CFG\" <<'EOF'
global
  log stdout  format raw  local0
  maxconn 8192

defaults
  log     global
  mode    tcp
  option  tcplog
  timeout connect 5s
  timeout client  30m
  timeout server  30m

frontend fe_pg_rw
  bind 127.0.0.1:$RWPORT
  bind $IP:$RWPORT
  default_backend be_pg_master

backend be_pg_master
  mode tcp
  option tcp-check
  tcp-check connect port $HP_CHK
  tcp-check send-binary \"GET /master HTTP/1.1\\r\\nHost: localhost\\r\\n\\r\\n\"
  tcp-check expect rstring \"HTTP/1.1 200\"
  default-server inter 2000 fall 2 rise 1
  server db1 $DB1:$RWPORT check port $HP_CHK
  server db2 $DB2:$RWPORT check port $HP_CHK
  server db3 $DB3:$RWPORT check port $HP_CHK

frontend fe_pg_ro
  bind 127.0.0.1:$ROPORT
  bind $IP:$ROPORT
  default_backend be_pg_replicas

backend be_pg_replicas
  mode tcp
  option tcp-check
  tcp-check connect port $HP_CHK
  tcp-check send-binary \"GET /replica HTTP/1.1\\r\\nHost: localhost\\r\n\\r\n\"
  tcp-check expect rstring \"HTTP/1.1 200\"
  default-server inter 2000 fall 2 rise 1
  server db1 $DB1:$RWPORT check port $HP_CHK
  server db2 $DB2:$RWPORT check port $HP_CHK
  server db3 $DB3:$RWPORT check port $HP_CHK

listen stats
  mode http
  bind $IP:$HP_STATS
  stats enable
  stats uri /
  stats refresh 5s
  stats realm HAProxy\ Stats
EOF
    docker run --rm -v \"\$CFG\":/cfg:ro haproxy:2.8 haproxy -c -f /cfg >/dev/null 2>&1 || { echo '  $KO config invalide'; exit 0; }
    cat >\"\$B/docker-compose.yml\" <<EOF
services:
  haproxy-local-pg:
    image: haproxy:2.8
    container_name: haproxy-local-pg
    restart: unless-stopped
    network_mode: host
    volumes:
      - \$B/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
EOF
    docker compose -f \"\$B/docker-compose.yml\" up -d >/dev/null 2>&1
    sleep 1
    ss -ltnH | grep -q \"$IP:$RWPORT\" && echo '  $OK listen RW' || echo '  $KO listen RW'
  "
}
[ -n "${P1:-}" ] && patch_haproxy "$P1" "$P1"
[ -n "${P2:-}" && "$P2" != "$P1" ] && patch_haproxy "$P2" "$P2"

# ----- 3) Ensure pgbouncer.ini + compose on proxies (auth_user + auth_query + correct auth_file) -----
write_pgb_files() {
  local HOST="$1" IP="$2"
  echo "→ write pgbouncer files @$HOST"
  TMPD=$(mktemp -d)
  cat >"$TMPD/pgb.ini" <<EOF
[databases]
postgres = host=$IP port=$RWPORT dbname=postgres
* = host=$IP port=$RWPORT

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = $PGB_LOCAL_PORT
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_user = pgbouncer
auth_query = SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=\$1
pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = 5000
default_pool_size = 100
ignore_startup_parameters = extra_float_digits,options,search_path
admin_users = ${KB_PG_SUPERUSER:-postgres}
stats_users = pgbouncer
log_disconnections = 1
log_connections = 1
EOF

  cat >"$TMPD/pgb.dc.yml" <<EOF
services:
  pgbouncer:
    image: brainsam/pgbouncer:latest
    container_name: pgbouncer
    restart: unless-stopped
    ports:
      - "$IP:$PGB_LOCAL_PORT:$PGB_LOCAL_PORT"
    volumes:
      - $PGB_DIR/pgbouncer.ini:/elements/pgbouncer.ini:ro
      - $PGB_DIR/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    environment:
      - LOGFILE=/dev/stdout
    command: ["pgbouncer","/elements/pgbouncer.ini"]
EOF

  scp -o StrictHostKeyChecking=no "$TMPD/pgb.ini"  root@"$HOST":$PGB_DIR/pgbouncer.ini >/dev/null 2>&1
  scp -o StrictHostKeyChecking=no "$TMPD/pgb.dc.yml" root@"$HOST":$PGB_DIR/docker-compose.yml >/dev/null 2>&1
  rm -rf "$TMPD"
  ssh -o StrictHostKeyChecking=no "$HOST" "chmod 640 $PGB_DIR/pgbouncer.ini; mkdir -p $PGB_DIR; [ -f $PGB_DIR/userlist.txt ] || touch $PGB_DIR/userlist.txt; chmod 600 $PGB_DIR/userlist.txt; docker compose -f $PGB_DIR/docker-compose.yml up -d >/dev/null 2>&1; sleep 1; ss -ltnH | grep -q \"$IP:$PGB_LOCAL_PORT\" && echo '  $OK pgbouncer listening' || echo '  $KO pgbouncer listen'"
}
[ -n "${P1:-}" ] && write_pgb_files "$P1" "$P1"
[ -n "${P2:-}" ] && write_pgb_files "$P2" "$P2"

# ----- 4) Ensure pgbouncer role on leader + deploy plaintext secret to proxies + userlist -----
if [ -n "${LEADER:-}" ]; then
  echo "→ ensure pgbouncer role & secret on leader: $LEADER"
  ssh -o StrictHostKeyChecking=no "$LEADER" '
    C=$(docker ps --format "{{.Names}}' | sed "s/'"'"'/'\"'/" ) # no-op (placeholder)
  ' >/dev/null 2>&1
fi

# get leader container name
get_cname(){ ssh -o StrictHostKeyChecking=no "$1" "docker ps --format '{{.Names}}' | egrep 'patroni|postgres' | head -1 || true"; }
if [ -n "$LEADER" ]; then
  C_LEAD=$(get_cname "$LEADER")
  if [ -n "$C_LEAD" ]; then
    echo "  $INF leader container: $C_LEAD"
    # ensure secret exists (again, nested inside leader)
    ssh -o StrictHostKeyChecking=no "$LEADER" "mkdir -p $ROOT/credentials/pgbouncer; [ -s $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret ] || { mkdir -p $ROOT/credentials/pgbouncer; umask 077; mkdir -p $ROOT/credentials/pgbouncer; echo -n; }" >/dev/null 2>&1
    # if file missing create it
    ssh -o StrictHostKeyChecking=no "$LEADER" "[ -s $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret ] || { umsg=\$(head -c 24 /dev/urandom | base64); echo \"\$umsg\" > $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret; }"
    # create/update role pgbouncer using peer auth
    ssh -o StrictHostKeyChecking=no "$LEADER" "docker exec -u postgres $C_LEAD sh -lc 'set -eu; PW=\$(cat $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret); psql -At -c \"select 1 from pg_roles where rolname='\''pgbouncer'\''\" | grep -q 1 && psql -c \"ALTER ROLE pgbouncer WITH LOGIN PASSWORD '\''\$P W'\'' SUPERUSER;\" || psql -c \"CREATE ROLE pgbouncer LOGIN PASSWORD '\''\$P W'\'' SUPERUSER;\"; psql -At -c \"select rolname,rolcanlogin from pg_roles where rolname='\''pgbouncer'\'';\" ' 2>/dev/null" 
    # build userlist locally: only pgbouncer plaintext + SCRAM users (optional)
    VER=$(ssh -o StrictHostKeyChecking=no "$LEADER" "docker exec -u postgres $C_LEAD psql -At -c \"select '\"'\"'\"' || rolname || '\" \"' || rolpassword || '\"' from pg_authid where rolcanlogin and rolpassword like 'SCRAM-SHA-256%';\" 2>/dev/null")
    PWP=$(ssh -o StrictHostKeyChecking=no "$LEADER" "cat $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret")
    UL=$(mktemp); printf "%s\n" "$VER" >"$UL"; printf '"'"'"pgbouncer" "%s"\n'"'"' "$PWP" >>"$UL"
    # ship to each proxy and restart pgbouncer
    scp -o StrictHostKeyChecking=no "$UL" root@"$P1":$PGB_DIR/userlist.txt >/dev/null 2>&1
    scp -o StrictHostKeyChecking=no "$UL" root@"$P2":$PGB_DIR/userlist.txt >/dev/null 2>&1
    rm -f "$UL"
    ssh -o StrictHostKeyChecking=no "$P1" "chmod 600 $PGB_DIR/userlist.txt; docker compose -f $PGB_DIR/../pgbouncer/docker-compose.yml up -d >/dev/null 2>&1; sleep 1; docker exec pgbouncer ls -l /etc/pgbouncer/userlist.txt >/dev/null 2>&1 && echo '  $OK userlist monté @ $P1' || echo '  $KO userlist @ $P1'"
    ssh -o StrictHostKeyChecking=no "$P2" "chmod 600 $PGB_DIR/userlist.txt; docker compose -f $PGB_DIR/../pgbouncer/docker-compose.yml up -d >/dev/null 2>&1; sleep 1; docker exec pgbouncer ls -l /etc/pgbouncer/userlist.txt >/dev/null 2>&1 && echo '  $OK userlist monté @ $P2' || echo '  $KO userlist @ $P2'"
  else
    echo "  $KO conteneur Postgres/Patroni introuvable sur le leader"
  fi
else
  echo "$INF Leader inconnu — saute l'étape rôle pgbouncer. (Tu peux la refaire plus tard)"
fi

# ----- 5) Tests finaux -----
test_proxy() {
  local H="$1"
  echo "— Test pgbouncer @ $H (as backend user 'pgbouncer') —"
  # lire secret copié depuis leader
  PW_REMOTE=$(ssh -o StrictHostKeyChecking=no "$H" "cat $PGB_DIR/pgbouncer.pass 2>/dev/null || cat /root/pgbouncer_secret 2>/dev/null || true")
  if [ -z "$PW_REMOTE" ]; then echo "  $KO pas de secret pgbouncer côté $H"; return; fi
  ssh -o StrictHostKeyChecking=no "$H" "PGPASSWORD='$PW_REMOTE' psql -h $H -p $PGB_LOCAL_PORT -U pgbouncer -d postgres -At -c 'select 1;'" >/dev/null 2>&1 \
    && echo "  $OK pgbouncer $H:$PGB_LOCAL_PORT -> select 1" \
    || echo "  $KO pgbouncer $H:$PGB_LOCAL_PORT"
}
test_proxy "$P1"
test_proxy "$P2"

echo "— Test via LB $VIP:$PGB_LOCAL_PORT (as pgbouncer) —"
PW_VIA=$(ssh -o StrictHostKeyChecking=no "$P1" "cat $PGB_DIR/pgbouncer.pass 2>/dev/null || true")
[ -n "$PW_VIA" ] && PGPASSWORD="$PW_VIA" psql -h "$VIP" -p "$PGB_LOCAL_PORT" -U pgbouncer -d postgres -At -c 'select 1;' >/dev/null 2>&1 \
  && echo "$OK LB $VIP:$PGB_LOCAL_PORT select 1" || echo "$KO LB $VIP:$PGB_LOCAL_PORT"

echo
echo "ℹ️  Log détaillé : $LOG"
