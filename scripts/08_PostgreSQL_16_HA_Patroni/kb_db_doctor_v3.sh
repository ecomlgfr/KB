#!/usr/bin/env bash
# KeyBuzz DB Suite – PgBouncer/HAProxy/Patroni Doctor v3
# no-interactive • idempotent • robust quoting • all-in-one
set +e
set -u
set -o pipefail

OK=$'\033[0;32mOK\033[0m'; KO=$'\033[0;31mKO\033[0m'; INF=$'\033[1;33mINFO\033[0m'

ROOT="/opt/keybuzz-installer"
LOG_DIR="$ROOT/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/kb_db_doctor_v3_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

SERVERS_TSV="$ROOT/inventory/servers.tsv"
PG_ENV="$ROOT/credentials/postgres.env"
PGB_DIR="/opt/keybuzz/pgbouncer"
VIP="${KB_PG_VIP_IP:-10.0.0.10}"
PGB_PORT="${KB_PGB_LOCAL_PORT:-6432}"
RWPORT="${KB_PG_NATIVE_PORT:-5432}"
ROPORT="${KB_PG_RO_PORT:-5433}"
HPCHK=8008
HPST=8404

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   KeyBuzz DB Suite Doctor – PgBouncer/HAProxy/Patroni (TCP)"
echo "║   no-interactive • idempotent • private IPs • SCRAM+auth_query"
echo "╚════════════════════════════════════════════════════════════════╝"

# --- discover infra
get_ip(){ awk -F'\t' -v H="$1" '$2==H{print $3}' "$SERVERS_TSV" | head -1; }
P1="$(get_ip 'haproxy-01')"; P2="$(get_ip 'haproxy-02')"
DB1="$(get_ip 'db-master-01')"; DB2="$(get_ip 'db-slave-01')"; DB3="$(get_ip 'db-slave-02')"
echo "$INF Proxies: $P1 / $P2"
echo "$INF DBs: $DB1 / $DB2 / $DB3 • VIP=$VIP  PGB=$PGB_PORT  RW=$RWPORT RO=$ROPORT  HC=$HPCHK"

# --- load superuser pass for final client test (do not echo)
KB_PG_SUPERUSER="postgres"; KB_PG_SUPERPASS="${KB_PG_SUPERPASS:-}"; KB_PG_NATIVE_PORT="${KB_PG_NATIVE_PORT:-$RWPORT}"
if [ -f "$ROOT/credentials/postgres.env" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/credentials/postgres.env"
fi

# --- detect leader (inside container via psql, not curl)
detect_leader() {
  for H in "$DB1" "$DB2" "$DB3"; do
    C=$(ssh -o StrictHostKeyChecking=no "$H" "docker ps --format '{{.Names}}' | egrep 'patroni|postgres' | head -1 || true")
    [ -z "$C" ] && continue
    ROLE=$(ssh -o StrictHostKeyChecking=no "$H" "docker exec -u postgres $C psql -At -c \"select case when pg_is_in_recovery() then 'replica' else 'leader' end;\" 2>/dev/null | head -n1")
    [ "$ROLE" = "leader" ] && { echo "$H"; return; }
  done
  echo ""
}
LEADER=$(detect_leader)
if [ -z "$LEADER" ]; then
  echo "$KO Impossible d'identifier le leader – on continue (certaines étapes seront sautées)"
else
  echo "$OK Leader: $LEADER"
fi

# --- open pg_hba on each DB
patch_hba() {
  H="$1"
  echo "→ Patch pg_hba @$H"
  ssh -o StrictHostKeyChecking=no "$H" " \
    C=\$(docker ps --format '{{.Names}}' | egrep 'patroni|postgres' | head -1 || true); \
    [ -z \"\$C\" ] && { echo '  $KO aucun conteneur'; exit 0; }; \
    docker exec -u postgres \"\$C\" sh -lc '
      set -eu
      HBA=\$(psql -At -c \"show hba_file;\");
      echo \"  hba: \$HBA\";
      cp \"\$HBA\" \"\$HBA.bak.\$(date +%Y%m%d_%H%M%S)\" || true
      add(){ grep -Fq \"$1\" \"\$HBA\" || echo \"$1\" >> \"\$HBA\"; }
      add \"host    all             all             127.0.0.1/32            scram-sha-256\"
      add \"host    all             all             ::1/128                 scram-sha-256\"
      add \"host    all             all             10.0.0.0/16             scram-sha-256\"
      add \"host    all             all             172.16.0.0/12           scram-sha-256\"
      add \"host    replication     replicator      10.0.0.0/16             scram-sha-256\"
      psql -c \"select pg_reload_conf();\"
    ' >/dev/null 2>&1 && echo '  $OK reload' || echo '  $KO reload'
  "
}
for H in "$DB1" "$DB2" "$DB3"; do patch_hba "$H"; done

# --- write HAProxy cfg with TCP + tcp-check HTTP on :8008, no $B2 typos, no ;csv
write_haproxy_cfg() {
  HOST="$1"; IP="$2"; CFG_LOCAL="$(mktemp)"
  cat >"$CFG_LOCAL" <<EOF
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
  bind 127.0.0.1:${RWPORT}
  bind ${IP}:${RWPORT}
  default_backend be_pg_master

backend be_pg_master
  mode tcp
  option tcp-check
  tcp-check connect port ${HPCHK}
  tcp-check send-binary "GET /master HTTP/1.1\r\nHost: localhost\r\n\r\n"
  tcp-check expect rstring "HTTP/1.1 200"
  default-server inter 2000 fall 2 rise 1
  server db1 ${DB1}:${RWPORT} check port ${HPCHK}
  server db2 ${DB2}:${RWPORT} check port ${HPCHK}
  server db3 ${DB3}:${RWPORT} check port ${HPCHK}

frontend fe_pg_ro
  bind 127.0.0.1:${ROPORT}
  bind ${IP}:${ROPORT}
  default_backend be_pg_replicas

backend be_pg_replicas
  mode tcp
  option tcp-check
  tcp-check connect port ${HPCHK}
  tcp-check send-binary "GET /replica HTTP/1.1\r\nHost: localhost\r\n\r\n"
  tcp-check expect rstring "HTTP/1.1 200"
  default-server inter 2000 fall 2 rise 1
  server db1 ${DB1}:${RWPORT} check port ${HPCHK}
  server db2 ${DB2}:${RWPORT} check port ${HPCHK}
  server db3 ${DB3}:${RWPORT} check port ${HPCHK}

listen stats
  mode http
  bind ${IP}:${HPST}
  stats enable
  stats uri /
  stats refresh 5s
  stats realm HAProxy\ Stats
EOF
  scp -o StrictHostKeyChecking=no "$CFG_LOCAL" root@"$HOST":/opt/keybuzz/haproxy/haproxy.cfg >/dev/null 2>&1
  rm -f "$CFG_LOCAL"
  ssh -o StrictHostKeyChecking=no "$HOST" " \
    B=/opt/keybuzz/haproxy; CFG=\$B/haproxy.cfg; \
    docker run --rm -v \"\$CFG\":/cfg:ro haproxy:2.8 haproxy -c -f /cfg >/dev/null 2>&1 || { echo '  $KO cfg invalide'; exit 0; }; \
    cat >\"\$B/docker-compose.yml\" <<EOT
services:
  haproxy-local-pg:
    image: haproxy:2.8
    container_name: haproxy-local-pg
    restart: unless-stopped
    network_mode: host
    volumes:
      - \$B/haproxy.cfg:/usr/local/etc/haproxy/hoy.cfg:ro
EOT
    # correct target path
    sed -i 's#hoy\\.cfg#haproxy.cfg#' \"\$B/docker-compose.yml\"
    docker compose -f \"\$B/docker-compose.yml\" up -d >/dev/null 2>&1 || true
    sleep 1
    ss -ltnH | grep -q \"${IP}:${RWPORT}\" && echo '  $OK listen RW' || echo '  $KO listen RW'
  "
}
write_haproxy_cfg "10.0.0.11" "$P1"
write_haproxy_cfg "10.0.0.12" "$P2"

# --- write pgbouncer files consistently (use /etc/pgbouncer/*.ini and *.txt)
write_pgb_cfg() {
  HOST="$1"; IP="$2"
  echo "→ write pgbouncer.ini + compose @$HOST"
  INILOC=$(mktemp); COMPOSELOC=$(tempfile 2>/dev/null || mktemp)
  cat >"$INILOC" <<EOF
[databases]
postgres = host=${IP} port=${RWPORT} dbname=postgres
* = host=${IP} port=${RWPORT}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${PGB_PORT}
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

  cat >"$COMPOSELOC" <<EOF
services:
  pgbouncer:
    image: ghcr.io/brainsam/pgbouncer:latest
    container_name: pgbouncer
    restart: unless-stopped
    ports:
      - "${IP}:${PGB_PORT}:${PGB_PORT}"
    volumes:
      - ${PGB_DIR}/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ${PGB_DIR}/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    environment:
      - LOGFILE=/dev/stdout
    command: ["pgbouncer","/etc/pgbouncer/pgbouncer.ini"]
EOF

  scp -o StrictHostKeyChecking=no "$INILOC"     root@"$HOST":$PGB_DIR/pgbouncer.ini    >/dev/null 2>&1
  scp -o StrictHostKeyChecking=no "$COMPOSELOC" root@"$HOST":$PGB_DIR/docker-compose.yml >/dev/null 2>&1
  rm -f "$INILOC" "$COMPOSELOC"

  ssh -o StrictHostKeyChecking=no "$HOST" " \
    mkdir -p '$PGB_DIR'; \
    [ -f '$PGB_DIR/userlist.txt' ] || touch '$PGB_DIR/userlist.txt'; \
    chmod 640 '$PGB_DIR/pgbouncer.ini'; chmod 600 '$PGB_DIR/userlist.txt'; \
    docker compose -f '$PGB_DIR/docker-compose.yml' up -d >/dev/null 2>&1; sleep 1; \
    ss -ltnH | grep -q '${IP}:${PGB_PORT}' && echo '  ${OK} pgbouncer listening' || echo '  ${KO} pgbouncer listen'
  "
}
write_pgb_cfg "10.0.0.11" "$P1"
write_pgb_cfg "10.0.0.12" "$P2"

# --- ensure pgbouncer role + secret on leader, push userlists
if [ -n "$LEADER" ]; then
  echo "→ ensure pgbouncer role+secret on leader $LEADER"
  ssh -o StrictHostKeyChecking=no root@"$LEADER" " \
    mkdir -p $ROOT/credentials/pgbouncer/pgbouncer; \
    [ -s $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret ] || { umask 077; head -c 24 /dev/urandom | base64 > $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret; }; \
    C=\$(docker ps --format '{{.Names}}' | egrep 'patroni|postgres' | head -1 || true); \
    PW=\$(cat $ROOT/credentials/pgbouncer/pgbouncer/pgbouncer_secret); \
    [ -n \"\$C\" ] && docker exec -u postgres \$C sh -lc 'psql -At -c \"select 1\" >/dev/null 2>&1 && (psql -c \"DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='\''pgbouncer'\'') THEN CREATE ROLE pgbouncer LOGIN SUPERUSER PASSWORD '\''\"'\"'\$PW'\"'\"''; END IF; END \$\$;\" && psql -c \"ALTER ROLE pgbouncer WITH PASSWORD '\''\"'\"'\$PW'\"'\"''\")' || true \
  "

  # get SCRAM verifiers for client users
  VER=$(ssh -o StrictHostKeyChecking=no root@"$LEADER" "C=\$(docker ps --format '{{.Names}}' | egrep 'patroni|postgres' | head -1 || true); [ -n \"\$C\" ] && docker exec -u postgres \$C psql -At -c \"select rolname||'|'||rolpassword from pg_authid where rolcanlogin and rolpassword like 'SCRAM-SHA-256%';\" 2>/dev/null" )
  if [ -n "$VER" ]; then
    UL=$(mktemp); echo "$VER" | awk -F'|' 'NF==2{printf("\"%s\" \"%s\"\n",$1,$2)}' > "$UL"
    for H in "10.0.0.11" "10.0.0.12"; do
      SEC=$(ssh -o StrictHostKeyChecking=no root@"$H" "cat $PGB_DIR/pgbouncer.pass 2>/dev/null || cat /root/pgbouncer_secret 2>/dev/null || true")
      printf "\"pgbouncer\" \"%s\"\n" "$SEC" >> "$UL"
      scp -o StrictHostKeyChecking=no "$UL" root@"$H":$PGB_DIR/userlist.txt >/dev/null 2>&1
      ssh -o StrictHostKeyChecking=no root@"$H" "chmod 600 $PGB_DIR/userlist.txt; docker compose -f $PGB_DIR/docker-compose.yml up -d >/dev/null 2>&1; sleep 1; docker exec pgbouncer ls -l /etc/pgbouncer/userlist.txt >/dev/null 2>&1 && echo '  ${OK} userlist monté @ $H' || echo '  ${KO} userlist @ $H'"
      # reset UL for next host (so we don't append twice)
      sed -i '$d' "$UL"
    done
    rm -f "$UL"
  else
    echo "$INF Impossible de récupérer les verifiers SCRAM depuis $LEADER (on peut quand même s’auth côté client via auth_file si tu ajoutes les lignes SCRAM plus tard)."
  fi
fi

# --- final tests (client -> PgBouncer -> HAProxy -> Postgres)
test_chain() {
  H="$1"; U="${KB_PG_SUPERUSER:-postgres}"; PASS="${KB_PG_SUPERPASS:-}"
  echo "— Test client as '$U' via $H:$PGB_PORT —"
  if [ -z "$PASS" ]; then
    echo "  $INF KB_PG_SUPERPASS introuvable dans $ROOT/credentials/postgres.env ; test sauté."
    return
  fi
  PGPASSWORD="$PASS" psql -h "$H" -p "$PGB_PORT" -U "$U" -d postgres -At -c 'select 1;' >/dev/null 2>&1 \
    && echo "  $OK client->PgBouncer ($H:$PGB_PORT) -> Postgres" \
    || echo "  $KO client->PgBouncer ($H:$PGB_PORT)"
}
test_chain "10.0.0.11"
test_chain "10.0.0.12"

echo "— Test via LB $VIP:$PGB_PORT (client as ${KB_PG_SUPERUSER:-postgres}) —"
if [ -n "${KB_PG_SUPERPASS:-}" ]; then
  PGPASSWORD="$KB_PG_SUPERPASS" psql -h "$VIP" -p "$PGB_PORT" -U "${KB_PG_SUPERUSER:-postgres}" -d postgres -At -c 'select 1;' >/dev/null 2>&1 \
    && echo "$OK client->LB $VIP:$PGB_PORT -> PgBouncer -> Postgres" \
    || echo "$KO client->LB $VIP:$PGB_PORT"
else
  echo "$INF Pas de KB_PG_SUPERPASS en env local — test LB sauté."
fi

echo
echo "==== Résumé ===="
echo "• HAProxy locaux: 10.0.0.11:$RWPORT/$ROPORT/$HPST et 10.0.0.12:$RWPORT/$ROPORT/$HPST doivent écouter ($OK affiché)."
echo "• userlist monté dans les conteneurs PgBouncer ($OK) et auth_user=pgbouncer + auth_query actifs."
echo "• pg_hba.conf ouvert pour 10.0.0.0/16 + 172.16.0.0/12 ($OK)."
echo "• Tests finaux: 'client->PgBouncer->Postgres' sur 10.0.0.11/12 et via VIP $VIP:$PGB_PORT doivent rendre '1'."
echo "Log: $LOG"
