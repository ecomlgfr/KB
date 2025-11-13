#!/usr/bin/env bash
# pas de -e
set -uo pipefail
cd "$(dirname "$0")" || true
. "./00_lib_env.sh"; load_keybuzz_env

echo "╔════════════════════════════════════════════╗"
echo "║   HETZNER LB CHECK - PgBouncer 4632       ║"
echo "╚════════════════════════════════════════════╝"
echo "VIP: ${KB_VIP_IP}:${KB_PGB_VIP_PORT}"
echo "Pool: ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT}, ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT}"

ok_backend=1
for host in "${KB_PROXY1_IP}" "${KB_PROXY2_IP}"; do
  if nc -z -w 2 "$host" "${KB_PGB_LOCAL_PORT}"; then
    echo -e "  \033[0;32mOK\033[0m backend $host:${KB_PGB_LOCAL_PORT}"
  else
    echo -e "  \033[0;31mKO\033[0m backend $host:${KB_PGB_LOCAL_PORT} (service pgbouncer ? firewall ?)"
    ok_backend=0
  fi
done

if nc -z -w 2 "${KB_VIP_IP}" "${KB_PGB_VIP_PORT}"; then
  echo -e "  \033[0;32mOK\033[0m VIP ${KB_VIP_IP}:${KB_PGB_VIP_PORT} (listener LB actif)"
else
  echo -e "  \033[0;31mKO\033[0m VIP ${KB_VIP_IP}:${KB_PGB_VIP_PORT} (service LB manquant ?)"
  echo "    → Dans Hetzner Console > Load Balancers > lb-haproxy > Services:"
  echo "      - Add service : TCP ${KB_PGB_VIP_PORT}"
  echo "      - Targets : ${KB_PROXY1_IP}:${KB_PGB_LOCAL_PORT}, ${KB_PROXY2_IP}:${KB_PGB_LOCAL_PORT}"
  echo "      - Health check TCP ${KB_PGB_LOCAL_PORT}"
  exit 1
fi

[ "$ok_backend" -eq 1 ] || exit 1
echo -e "${GREEN}✅ Hetzner LB: tout semble correct.${NC}"
