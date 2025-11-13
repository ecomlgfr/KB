#!/usr/bin/env bash
# KeyBuzz - HAProxy leader-aware (RW:5432 / RO:5433 / stats:8404) sur haproxy-01/02 (Docker)
# Règles : set -u ; set -o pipefail ; IPs depuis servers.tsv ; bind IP privée ; pas d’IP en dur ; idempotent
set -u
set -o pipefail

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; INF='\033[1;33mINFO\033[0m'
SCRIPT_NAME="haproxy_leader_aware_on_proxies_docker"
LOG_DIR="/opt/keybuzz-installer/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
REMOTE_HA_BASE="/opt/keybuzz/haproxy"
cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           HAPROXY LEADER-AWARE (Docker) 5432/5433/8404            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

get_ip(){ awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }

P1="$(get_ip 'haproxy-01')"; P2="$(get_ip 'haproxy-02')"
DB1="$(get_ip 'db-master-01')"; DB2="$(get_ip 'db-slave-01')"; DB3="$(get_ip 'db-slave-02')"
[ -n "$P1" ] && [ -n "$P2" ] && [ -n "$DB1" ] && [ -n "$DB2" ] && [ -n "$DB3" ] || { echo -e "$KO inventaire incomplet ($SERVERS_TSV)"; exit 1; }

# Patroni REST port (health)
PATRONI_PORT="${KB_PATRONI_PORT:-8008}"

make_remote_file(){ # host path content
  local host="$1" path="$2" content="$3"
  printf "%s" "$content" | base64 -w0 | ssh -o StrictHostKeyChecking=no root@"$host" "mkdir -p \"\$(dirname \"$path\")\" && base64 -d > \"$path\""
}

haproxy_cfg_for_proxy(){ # ip_proxy -> haproxy.cfg (bind IP privée + 127.0.0.1)
  local ip="$1"
  cat <<EOF
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

# === RW (leader) :5432 ===
frontend fe_pg_rw
  bind 127.0.0.1:5432
  bind ${ip}:5432
  default_backend be_pg_master

backend be_pg_master
  option httpchk GET /master
  http-check expect status 200
  server db1 ${DB1}:5432 check port ${PATRONI_PORT}
  server db2 ${DB2}:5432 check port ${PATRONI_PORT}
  server db3 ${DB3}:5432 check port ${PATRONI_PORT}

# === RO (replicas) :5433 ===
frontend fe_pg_ro
  bind 127.0.0.1:5433
  bind ${ip}:5433
  default_backend be_pg_replicas

backend be_pg_replicas
  balance roundrobin
  option httpchk GET /replica
  http-check expect status 200
  server db1 ${DB1}:5432 check port ${PATRONI_PORT}
  server db2 ${DB2}:5432 check port ${PATRONI_PORT}
  server db3 ${DB3}:5432 check port ${PATRONI_PORT}

# === Stats HTTP :8404 ===
listen stats
  mode http
  bind ${ip}:8404
  stats enable
  stats uri /
  stats refresh 5s
  stats realm HAProxy\ Stats
EOF
}

compose_for_proxy(){ # ip_proxy -> docker-compose.yml (ports IP:PORT:PORT)
  local ip="$1"
  cat <<EOF
services:
  haproxy_local_pg:
    image: ${IMG_HAPROXY}
    container_name: haproxy-local-pg
    restart: unless-stopped
    ports:
      - "${ip}:5432:5432"
      - "${ip}:5433:5433"
      - "${ip}:8404:8404"
    volumes:
      - ${REMOTE_HA_BASE}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
EOF
}

deploy_on_proxy(){ # host_ip
  local host="$1"
  local cfg; cfg="$(haproxy_cfg_for_proxy "$host")"
  local compose; compose="$(compose_for_proxy "$host")"

  # backup si présent
  ssh -o StrictHostKeyChecking=no root@"$host" "mkdir -p ${REMOTE_HA_BASE}; ts=\$(date +%Y%m%d_%H%M%S); [ -f ${REMOTE_HA_BASE}/haproxy.cfg ] && cp -f ${REMOTE_HA_BASE}/haproxy.cfg ${REMOTE_HA_BASE}/haproxy.cfg.bak.\$ts || true" >>"$LOG" 2>&1

  make_remote_file "$host" "${REMOTE_HA_BASE}/haproxy.cfg" "$cfg"
  ssh -o StrictHostKeyChecking=no root@"$host" 'printf "\n" >> ${REMOTE_HA_BASE}/haproxy.cfg' >>"$LOG" 2>&1
  make_remote_file "$host" "${REMOTE_HA_BASE}/docker-compose.yml" "$compose"
  ssh -o StrictHostKeyChecking=no root@"$host" 'printf "\n" >> ${REMOTE_HA_BASE}/docker-compose.yml' >>"$LOG" 2>&1

  # validation de la conf via conteneur éphémère
  if ! ssh -o StrictHostKeyChecking=no root@"$host" "docker run --rm -v ${REMOTE_HA_BASE}/haproxy.cfg:/cfg:ro ${IMG_HAPROXY} haproxy -c -f /cfg" >>"$LOG" 2>&1; then
    echo -e "$KO haproxy.cfg invalide sur $host (voir log)"; tail -n 50 "$LOG" || true; exit 1
  fi

  # up -d
  ssh -o StrictHostKeyChecking=no root@"$host" "docker compose -f ${REMOTE_HA_BASE}/docker-compose.yml up -d" >>"$LOG" 2>&1

  # health locaux (ports bind sur IP privée)
  ssh -o StrictHostKeyChecking=no root@"$host" "sleep 0.8; ss -ltnH | grep -q \"${host}:5432\" && ss -ltnH | grep -q \"${host}:5433\" && ss -ltnH | grep -q \"${host}:8404\"" \
    && echo -e "$OK HAProxy écoute sur ${host}:5432/5433/8404" \
    || { echo -e "$KO HAProxy n'écoute pas correctement sur ${host} (voir log)"; tail -n 50 "$LOG" || true; exit 1; }

  # reach Patroni REST pour chaque DB (pour éviter surprises firewall)
  for dbip in "$DB1" "$DB2" "$DB3"; do
    if ssh -o StrictHostKeyChecking=no root@"$host" "nc -z -w 2 ${dbip} ${PATRONI_PORT}"; then
      echo -e "$OK ${host} → Patroni ${dbip}:${PATRONI_PORT}"
    else
      echo -e "$KO ${host} ne joint pas Patroni ${dbip}:${PATRONI_PORT} (firewall ? réseau ?)"
    fi
  done
}

echo "--- Proxy ${P1} ---"; deploy_on_proxy "$P1"
echo "--- Proxy ${P2} ---"; deploy_on_proxy "$P2"

echo -e "$OK Déploiement HAProxy leader-aware terminé."
tail -n 50 "$LOG" || true
