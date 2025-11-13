#!/usr/bin/env bash
# KeyBuzz – PgBouncer/HAProxy/Patroni full doctor (no-interactive, idempotent)
# No `set -e` to avoid shell exit on transient ssh errors.
set +e
set -u
set -o pipefail

# ---- visuals ----
OK=$'\033[0;32mOK\033[0m'
KO=$'\033[0;31mKO\033[0m'
INF=$'\033[1;33mINFO\033[0m'

LOG_DIR="/opt/keybuzz-installer/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/kb_pgbouncer_full_doctor_$(date +%Y%m%d_%H%M%S).log"
# capture all output
exec > >(tee -a "$LOG") 2>&1
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   KeyBuzz DB Suite Doctor – PgBouncer/HAProxy/Patroni (TCP)    "
echo "║   no-interactive • idempotent • private IPs • SCRAM+auth_query "
echo "╚════════════════════════════════════════════════════════════════╝"

# ---- paths & env discovery (no secrets printed) ----
ROOT="/opt/keybuzz-installer"
SERVERS_TSV="$ROOT/inventory/servers.tsv"
PG_ENV="$ROOT/credentials/postgres.env"
PGB_SECRET_DIR="$ROOT/credentials/pgbouncer"
PGB_SECRET_FILE="$PGB_SECRET_DIR/pgbouncer/pgbouncer_secret"

# derive IPs from servers.tsv
get_ip() { awk -F'\t' -v H="$1" '$2==H{print $3}' "$SERVERS_TSV" | head -1; }
P1="$(get_ip 'haproxy-01')"
P2="$(get_ip 'haproxy-02')"
DB1="$(get_ip 'db-master-01')"
DB2="$(get_ip 'db-slave-01')"
DB3="$(get_ip 'db-slave-02')"
VIP="${KB_VIP_IP:-10.0.0.10}"
PGB_PORT="${KB_PGB_LOCAL_PORT:-6432}"
RWPORT="${KB_PG_NATIVE_PORT:-5432}"
ROPORT="${KB_PG_RO_PORT:-5433}"
HP_STATS_PORT=8404
HPCHK=8008

echo "$INF Proxies: $P1 / $P2"
echo "$INF DBs: $DB1 / $DB2 / $DB3 • VIP: $VIP  PGB:$PGB_PORT  RW:$RWPORT  RO:$ROPORT  HC:$HPCHK"

# load postgres superuser creds (without echoing values)
if [ -f "$PG_ENV" ]; then
  # shellcheck disable=SC1090
  . "$PG_ENV"
  KB_PG_SUPERUSER="${KB_PG_SUPERUSER:-postgres}"
  KB_PG_SUPERPASS="${KB_PG_SUPERPASS:-${POSTGRES_PASSWORD:-}}"
  KB_PG_NATIVE_PORT="${KB_PG_NATIVE_PORT:-$RWPORT}"
  [ -n "${KB_PG_SUPERPASS:-}" ] || echo "$INF Aucun KB_PG_SUPERPASS dans $PG_ENV – on essaiera `psql` local au conteneur (peer)" 
else
  echo "$INF $PG_ENV introuvable, poursuite sans PGPASSWORD (mode peer local)."
  KB_PG_SUPERUSER="postgres"; KB_PG_NATIVE_PORT="${RWPORT}"
  KB_PG_SUPERPASS=""
fi

# ---- detect Patroni leader (by role endpoint) ----
detect_leader() {
  for H in "$DB1" "$DB2" "$DB3"; do
    ROLE="$(ssh -o StrictHostKeyChecking=no "$H" "curl -s --max-time 2 http://127.0.0.1:$HPCHK/patroni 2>/dev/null | grep -E '\"role\"\\s*:\\s*\"(leader)\"' -o | cut -d\\\" -f4" )"
    [ "$ROLE" = "leader" ] && { echo "$H"; return; }
  done
  echo ""
}
LEADER="$(detect_leader)"
if [ -z "$LEADER" ]; then
  echo "$KO Impossible d'identifier le leader Patroni via :$HPCHK"
else
  echo "$OK Leader Patroni: $LEADER"
fi

# ---- ensure pg_hba allows private LAN & docker bridge (idempotent) ----
patch_hba() {
  local HOST="$1"
  echo "→ Patch pg_hba @ $HOST"
  ssh -o StrictHostKeyChecking=no "$HOST" '
    C=$(docker ps --format "{{.Names}}" | egrep "patroni|postgres" | head -1 || true) || true
    [ -n "$C" ] || { echo "  '"$KO"' aucun conteneur"; exit 0; }
    docker exec -u postgres "$C" sh -lc '\''
      set -u
      HBA=$(psql -At -c "show hba_file;")
      [ -n "$HBA" ] || { echo "  ❌ hba_file?"; exit 0; }
      echo "  hba: $HBA"
      cp "$HBA" "$HBA.bak.$(date +%Y%m%d_%H%M%S)" || true
      add(){ grep -Fq "$1" "$HBA" || echo "$1" >> "$HBA"; }
      add "host    all             all             127.0.0.1/32            scram-sha-256"
      add "host    all             all             ::1/128                 scram-sha-256"
      add "host    all             all             10.0.0.0/16             scram-sha-256"
      add "host    all             all             172.16.0.0/12           scram-sha-256"
      add "host    replication     replicator      10.0.0.0/16             scram-sha-256"
      psql -c "select pg_reload_conf();" >/dev/null 2>&1 && echo "  '"$OK"' reload"
    '\''
  ' || true
}
for DBH in "$DB1" "$DB2" "$DB3"; do patch_hba "$DBH"; done

# ---- ensure HAProxy config (TCP + tcp-check HTTP to :8008) ----
patch_haproxy() {
  local H="$1" ; local HIP="$2"
  echo "→ Patch HAProxy @ $H"
  ssh -o StrictHostKeyChecking=no "$H" "
    set -u
    B=/opt/keybuzz/haproxy
    CFG=\$B/haproxy.cfg
    mkdir -p \"\$B\"
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
  bind $HIP:$RWPORT
  default_backend be_pg_master

backend be_pg_master
  mode tcp
  option tcp-check
  tcp-check connect port $HPCHK
  tcp-check send-binary \"GET /master HTTP/1.1\\r\\nHost: localhost\\r\\n\\r\\n\"
  tcp-check expect rstring \"HTTP/1.1 200\"
  default-server inter 2000 fall 2 rise 1
  server db1 $DB1:$RWPORT check port $HPCHK
  server db2 $DB2:$RWPORT check port $HPCHK
  server db3 $DB3:$RWPORT check port $HPCHK

frontend   fe_pg_ro
  bind  127.0.0.1:$ROPORT
  bind  $HIP:$ROPORT
  default_backend be_pg_replicas

backend be_pg_replicas
  mode  tcp
  option tcp-check
  tcp-check connect port $HPCHK
  tcp-check send-binary \"GET /replica HTTP/1.1\\r\\nHost: localhost\\r\\n\\r\\n\"
  tcp-check expect rstring \"HTTP/1.1 200\"
  default-server inter 2000 fall 2 rise 1
  server db1 $DB1:$RWPORT check port $HPCHK
  server db2 $B2:$RWPORT check port $HPCHK
  server db3 $DB3:$RWPORT check port $HPCHK

listen stats
  mode http
  bind $HIP:$HP_STATS
  stats enable
  stats uri /
  stats refresh 5s
  stats realm HAProxy\ Stats
EOF
    docker run --rm -v \"\$CFG\":/cfg:ro haproxy:2.8 haporxy -v >/dev/null 2>&1 || true
    docker run --rm -v \"\$CFG\":/cfg:ro haporxy:2.8 haproxy -c -f /cfg >/dev/null 2>&1 && echo '  $OK cfg OK' || echo '  $KO cfg invalide'
    docker compose -f \"\$B/docker-compose.yml\" 2>/dev/null 1>/dev/null || true
    cat >\"\$B/docker-compose.yml\" <<EOF
services:
  haproxy-local-pg:
    image: haproxy:2.8
    container_name: haproxy-local-pg
    restart: unless-stopped
    network_mode: host
    volumes:
      - \${B}/hapro/www:/usr/local/etc/haproxy:ro
      - \${B}/haproxy.cfg:/tmp/haproxy.cfg:ro
    command: ["haproxy","-f","/tmp/haproxy.cfg","-db"]
EOF
    mkdir -p \"\$B/hapro\" && cp -f \"\$CFG\" \"\$B/haproxy.cfg\"
    docker compose -f \"\$B/docker-compose.yml\" up -d >/dev/null 2>&1
    sleep 1
    ss -ltnH | grep -q \"$HIP:$RWPORT\" && echo '  $OK listen RW' || echo '  $KO listen RW'
  " || true
}
patch_haproxy "$P1" "$P1"
patch_haproxy "$P2" "$P2"

# ---- Ensure PgBouncer compose + ini + userlist (auth_user pgbouncer) on proxies ----
build_pgb_ini() {
  local IP="$1"
  cat <<EOF
[databases]
postgres = host=$IP port=$RWPORT dbname=postgres
* = host=$IP port=$RWPORT

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = $PGB_PORT
auth_type = scram-sha-256
auth_file = /opt/pgbouncer/userlist.txt
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
}
build_pgb_compose() {
  local IP="$1"
  cat <<EOF
services:
  pgbouncer:
    image: brainsam/pgbouncer:latest
    container_name: pgbouncer
    restart: unless-stopped
    ports:
      - "$IP:$PGB_PORT:$PGB_PORT"
    volumes:
      - /opt/keybuzz/pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - /opt/keybuzz/pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    environment:
      - LOGFILE=/dev/stdout
    command: ["pgbouncer","/etc/pgbouncer/pgbouncer.ini"]
EOF
}

deploy_pgb() {
  local H="$1" ; local IP="$2"
  echo "→ Deploy PgBouncer @$H (bind $IP:$PGB_PORT, auth_user=pgbouncer)"
  local TMPD; TMPD="$(mktemp -d)"
  build_pgb_ini "$IP" > "$TMPD/pgbouncer.ini"
  build_pgb_compose "$IP" > "$TMPD/docker-compose.yml"
  scp -o StrictHostKeyChecking=no "$TMPD/pgbouncer.ini"  root@"$H":/tmp/pgb.ini >/dev/null
  scp -o StrictHostKeyChecking=no "$TMPD/docker-compose.yml" root@"$H":/tmp/pgb.dc.yml >/dev/null
  rm -rf "$TMPD"
  ssh -o StrictHostKeyChecking=no "$H" "
    set -u
    B=/opt/keybuzz/pgbouncer
    mkdir -p \"\$B\"
    ts=\$(date +%Y%m%d_%H%M%S)
    [ -f \"\$B/pgbouncer.ini\" ] && cp -f \"\$B/pgbouncer.ini\" \"\$B/pgbouncer.ini.bak.\$ts\" || true
    [ -f \"\$B/docker-compose.yml\" ] && cp -f \"\$B/docker-compose.yml\" \"\$B/docker-compose.yml.bak.\$ts\" || true
    mv -f /tmp/pgb.ini \"\$B/pgbouncer.ini\"
    mv -f /tmp/pgb.dc.yml \"\$B/docker-compose.yml\"
    chmod 640 \"\$B/pgbouncer.ini\"
    # keep existing userlist if present; volume will mount /opt/keybuzz/pgbouncer/userlist.txt to /etc/pgbouncer/userlist.txt
    [ -f \"\$B/userlist.txt\" ] || touch \"\$B/userlist.txt\"
    chmod 600 \"\$B/userlist.txt\"
    docker compose -f \"\$B/docker-compose.yml\" up -d >/dev/null 2>&1
    sleep 1
    ss -ltnH | grep -q \"$IP:$PGB_PORT\" && echo '  $OK pgbouncer listening' || echo '  $KO pgbouncer listen'
  " || true
}
deploy_pgb "$P1" "$P1"
deploy_pgb "$P2" "$P2"

# ---- Ensure pgbouncer secret exists, role created, and userlist updated on proxies ----
ensure_pgb_secret_and_role() {
  local MASTER="$1"
  echo "→ Ensure pgbouncer secret & role on $MASTER"
  ssh -o StrictHostKeyChecking=no "$MASTER" '
    set -u
    C=$(docker ps --format "{{.Names}}" | egrep "patroni|postgres" | head -1 || true) || true
    [ -n "$C" ] || { echo "  '"$KO"' pas de conteneur"; exit 0; }
    mkdir -p /opt/keybuzz-installer/credentials/pgbouncer
    [ -s /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer_secret ] || { umask 077; head -c 24 /dev/urnull 2>/dev/null; echo; } >/dev/null
    test -s /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer_secret || { head -c 24 /dev/urandom | base64 > /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer_secret; }
    echo "  '"$OK"' secret présent"
    docker exec -u postgres "$C" sh -lc '"'"'
      set -eu
      HBA=$(psql -At -c "show hba_file;") >/dev/null
      PW=$(cat /opt/keybuzz-installer/credentials/pgbouncer/pgbouncer_secret)
      psql -At -c "select 1 from pg_roles where rolname='\''pgbouncer'\''" | grep -q 1 && \
        psql -c "ALTER ROLE pgbouncer WITH LOGIN PASSWORD '\''"'"'"$PW"'"'"'' SUPERUSER;" || \
        psql -c "CREATE ROLE pgbouncer LOGIN PASSWORD '\''"'"'"$PW"'"'"'' SUPERUSER;"
      psql -At -c "select rolname,rolcanlogin from pg_roles where rolname='\''pgbouncer'\'';"
    '"'"' >/dev/null 2>&1 && echo "  '"$OK"' rôle pgbouncer à jour" || echo "  '"$KO"' rôle pgbouncer"
  ' || true
}
[ -n "$LEADER" ] && ensure_pgb_secret_and_role "$LEADER"

push_userlist() {
  local PROXY="$1"
  echo "→ Push userlist.txt (pgbouncer plaintext + SCRAM users) @$PROXY"
  # grab SCRAM verifiers from leader (if available)
  VER="$(ssh -o StrictHostKeyChecking=no "$LEADER" 'C=$(docker ps --format "{{.Names}}" | egrep "patroni|postgres" | head -1 || true); [ -n "$C" ] && docker exec -u postgres "$C" psql -At -c "select '\''\"'\''||rolname||'\''\" \"''||rolpassword||'\''\'' from pg_authid where rolcanlogin and rolpassword like '\''\''SCRAM-SHA-256%'\'';" 2>/dev/null || true')"
  # copy secret from leader to proxy
  ssh -o StrictHostKeyChecking=no "$PROXY" "mkdir -p /opt/keybuzz/pgbouncer; true"
  scp -o StrictHostKeyChecking=no root@"$LEADER":/opt/keybuzz-installer/credentials/pgbouncer/pgbouncer_secret \
      root@"$PROXY":/opt/keybuzz/pgbouncer/pgbouncer.pass >/dev/null 2>&1
  # build userlist locally
  TMPU="$(mktemp)"
  echo "$VER" > "$TMPU"
  echo "\"pgbouncer\" \"$(ssh -o StrictHostKeyChecking=no "$PROXY" 'cat /opt/keybuzz/pgbouncer/pgbouncer.pass' 2>/dev/null)" >> "$TMPU"
  scp -o StrictHostKeyChecking=no "$TMPU" root@"$PROXY":/opt/keybuzz/pgbouncer/userlist.txt >/dev/null 2>&1
  rm -f "$TMPU"
  ssh -o StrictHostKeyChecking=no "$PROXY" 'chmod 600 /opt/keybuzz/pgbouncer/userlist.txt; docker compose -f /opt/keybuzz/pgbouncer/docker-compose.yml up -d >/dev/null 2>&1; sleep 1; docker exec pgbouncer ls -l /etc/pgbouncer/userlist.txt >/dev/null 2>&1 && echo "  '"$OK"' userlist monté" || echo "  '"$KO"' userlist non monté"' || true
}
[ -n "$LEADER" ] && push_userlist "$P1"
[ -n "$LEADER" ] && push_userlist "$P2"

# ---- Sanity tests ----
echo "== Tests depuis chaque proxy =="
test_proxy() {
  local H="$1"
  echo "--- Proxy $H ---"
  # 1) HAProxy RW direct
  ssh -o StrictHostKeyChecking=no "$H" \
    "docker run --rm --network host -e PGPASSWORD='${KB_PG_SUPERPASS:-}' postgres:16-alpine \
     psql -h $H -p $RWPORT -U ${KB_PG_SUPERUSER:-postgres} -d postgres -At -c 'select 1;'" \
    >/dev/null 2>&1 && echo " $OK HAProxy $H:$RWPORT" || echo " $KO HAProxy $H:$RWPORT"
  # 2) PgBouncer as backend-user (pgbouncer)
  ssh -o StrictHostKeyChecking=no "$H" \
   "PW=\$(cat /opt/keybuzz/pgbouncer/pgbouncer.pass 2>/dev/null || true); \
    [ -n \"\$PW\" ] && PGPASSWORD=\"\$PW\" psql -h $H -p $PGB_PORT -U pgbouncer -d postgres -At -c 'select 1;'" \
    >/dev/null 2>&1 && echo " $OK pgbouncer $H:$PGB_PORT (as pgbouncer)" || echo " $KO pgbouncer $H:$PGB_PORT (as pgbouncer)"
}
test_proxy "$P1"
test_proxy "$P2"

echo "== Test via LB $VIP:$PGB_PORT (as pgbouncer) =="
PW_VIA_PROXY="$(ssh -o StrictHostKeyChecking=no $P1 'cat /opt/keybuzz/pgbouncer/pgbouncer.pass' 2>/dev/null)"
[ -n "$PW_VIA_PROXY" ] && PGPASSWORD="$PW_VIA_PROXY" psql -h "$VIP" -p "$PGB_PORT" -U pgbouncer -d postgres -At -c 'select 1;' >/dev/null 2>&1 \
  && echo "$OK LB $VIP:$PGB_PORT" || echo "$KO LB $VIP:$PGB_PORT"

echo "== Dernières lignes journaux PgBouncer =="
ssh -o StrictHostKeyChecking=no "$P1" "docker logs --tail 40 pgbouncer 2>/dev/null | tail -n 40" || true
ssh -o StrictHostKeyChecking=no "$P2" "docker logs --tail 40 pgbouncer 2>/dev/null | tail -n 40" || true

echo "== Résumé =="

echo "  • Proxies      : $P1 / $P2"
echo "  • Leader DB    : ${LEADS:-$LEADER}"
echo "  • HBA          : 10.0.0.0/16 + 172.16.0.0/12 + loopback (scram)  $OK si pas d'erreur ci-dessus"
echo "  • HAProxy RW   : $RWPORT $OK si 'bind OK' + test RW $OK"
echo "  • PgBouncer    : bind $PGB_PORT + userlist monté + auth_user=$OK"
echo "  • Tests finaux : pgbouncer@$P1/$P2 & LB $VIP:$PGB_PORT doivent afficher 'select 1' + $OK"

echo "—— fin ———"
