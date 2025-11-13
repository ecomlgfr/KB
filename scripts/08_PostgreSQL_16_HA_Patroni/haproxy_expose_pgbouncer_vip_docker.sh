#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

echo "╔═══════════════════════════════════════════════════╗"
echo "║ HAPROXY_EXPOSE_PGBOUNCER_VIP (Docker, host net)  ║"
echo "╚═══════════════════════════════════════════════════╝"
echo "VIP:port : ${KB_VIP_IP}:${KB_PGB_VIP_PORT}"
echo "Backends : ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT} ; ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT}"

PROXIES=("${KB_PROXY1_IP}" "${KB_PROXY2_IP}")

make_remote_file() { # host path content
  local host="$1" path="$2" content="$3"
  printf "%s" "$content" | base64 -w0 | ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$host" "mkdir -p \"$(dirname "$path")\" && base64 -d > \"$path\""
}

HAPROXY_CFG="global
  log stdout  format raw  local0
  maxconn 4096

defaults
  log     global
  mode    tcp
  option  tcplog
  timeout connect 5s
  timeout client  30m
  timeout server  30m

frontend fe_pgbouncer
  bind ${KB_VIP_IP}:${KB_PGB_VIP_PORT}
  default_backend be_pgbouncer

backend be_pgbouncer
  balance roundrobin
  server px1 ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT} check
  server px2 ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT} check
"

COMPOSE="services:
  haproxy_pgb_vip:
    image: ${IMG_HAPROXY}
    container_name: haproxy-pgb-vip
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${REMOTE_HA_BASE}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
"

ANY_VIP=0
for px in "${PROXIES[@]}"; do
  echo "--- Proxy ${px} ---"
  make_remote_file "$px" "${REMOTE_HA_BASE}/haproxy.cfg" "$HAPROXY_CFG"
  make_remote_file "$px" "${REMOTE_HA_BASE}/docker-compose.yml" "$COMPOSE"

  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$px" "docker run --rm -v ${REMOTE_HA_BASE}/haproxy.cfg:/cfg:ro ${IMG_HAPROXY} haproxy -c -f /cfg >/dev/null 2>&1"; then
    echo -e "  ${GREEN}Configuration file is valid${NC}"
  else
    echo -e "  ${RED}KO: haproxy.cfg invalide sur ${px}${NC}"
    exit 1
  fi

  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$px" "docker compose -f ${REMOTE_HA_BASE}/docker-compose.yml up -d >/dev/null 2>&1"; then
    echo -e "  ${GREEN}Container haproxy-pgb-vip Started${NC}"
  else
    echo -e "  ${RED}KO: docker compose up haproxy a échoué sur ${px}${NC}"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$px" "docker compose -f ${REMOTE_HA_BASE}/docker-compose.yml logs --no-color || true"
    exit 1
  fi

  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$px" "ip a | grep -q \"${KB_VIP_IP}\""; then
    ANY_VIP=1
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$px" "ss -ltnH | grep -q \"${KB_VIP_IP}:${KB_PGB_VIP_PORT}\""; then
      echo -e "  ${GREEN}OK:${NC} ${KB_VIP_IP}:${KB_PGB_VIP_PORT} écoute sur ${px}"
    else
      echo -e "  ${RED}KO:${NC} ${KB_VIP_IP}:${KB_PGB_VIP_PORT} non exposé sur ${px} (le conteneur tourne mais ne bind pas ?)"
      exit 1
    fi
  else
    echo -e "  ${YELLOW}(info)${NC} VIP non portée par ${px}, pas d'écoute (normal)"
  fi
done

if [ "$ANY_VIP" -eq 0 ]; then
  echo -e "${RED}KO:${NC} La VIP ${KB_VIP_IP} n'est portée par aucun proxy. Vérifie keepalived/assignation VIP."
  exit 1
fi

echo -e "${GREEN}OK:${NC} Stack HAProxy (Docker) déployée et VIP active sur au moins un proxy."
