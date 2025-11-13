#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || true
# shellcheck source=./00_lib_env.sh
. "./00_lib_env.sh"
load_keybuzz_env

echo "╔═══════════════════════════════════════════════════╗"
echo "║  HAPROXY_EXPOSE_PGBOUNCER_VIP (4632 -> 2x:6432)  ║"
echo "╚═══════════════════════════════════════════════════╝"
echo "VIP:port : ${KB_VIP_IP}:${KB_PGB_VIP_PORT}"
echo "Backends : ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT} ; ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT}"

PROXIES=("${KB_PROXY1_IP}" "${KB_PROXY2_IP}")
DEBIAN_FRONTEND=noninteractive

for px in "${PROXIES[@]}"; do
  echo "--- Proxy ${px} ---"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"${px}" "apt-get update -yq && apt-get install -yq haproxy"

  ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"${px}" "bash -lc '
CFG=/etc/haproxy/haproxy.cfg
mkdir -p /etc/haproxy

if [ ! -f \"\$CFG\" ]; then
  cat >\"\$CFG\" <<EOC
global
  log /dev/log    local0
  log /dev/log    local1 notice
  maxconn 4096
  daemon

defaults
  log     global
  mode    tcp
  option  tcplog
  timeout connect 5s
  timeout client  30m
  timeout server  30m

# === Frontend PgBouncer VIP ===
frontend fe_pgbouncer
  bind ${KB_VIP_IP}:${KB_PGB_VIP_PORT}
  default_backend be_pgbouncer

backend be_pgbouncer
  balance roundrobin
  server px1 ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT} check
  server px2 ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT} check
EOC
else
  # Injecte/assure fe_pgbouncer + be_pgbouncer
  grep -q \"frontend fe_pgbouncer\" \"\$CFG\" || cat >>\"\$CFG\" <<\"EOP\"

frontend fe_pgbouncer
  bind ${KB_VIP_IP}:${KB_PGB_VIP_PORT}
  default_backend be_pgbouncer
EOP

  if ! grep -q \"backend be_pgbouncer\" \"\$CFG\"; then
    cat >>\"\$CFG\" <<\"EOP\"
backend be_pgbouncer
  balance roundrobin
  server px1 ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT} check
  server px2 ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT} check
EOP
  else
    # Remet à jour les serveurs si besoin (idempotent)
    sed -i \"s#server px1 .*#server px1 ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT} check#\" \"\$CFG\"
    sed -i \"s#server px2 .*#server px2 ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT} check#\" \"\$CFG\"
  fi
fi

haproxy -c -f \"\$CFG\"
systemctl enable haproxy
systemctl restart haproxy
sleep 1
ss -ltnp | grep ${KB_VIP_IP}:${KB_PGB_VIP_PORT} || (echo \"KO: VIP ${KB_VIP_IP}:${KB_PGB_VIP_PORT} non exposé\" && exit 1)
echo \"OK: ${KB_VIP_IP}:${KB_PGB_VIP_PORT} exposé sur ${px}\"
'"
done

echo "OK: VIP PgBouncer exposée sur ${KB_VIP_IP}:${KB_PGB_VIP_PORT}."
