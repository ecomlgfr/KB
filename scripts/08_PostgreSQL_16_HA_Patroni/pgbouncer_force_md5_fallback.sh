#!/usr/bin/env bash
set -euo pipefail
PROXIES=("10.0.0.11" "10.0.0.12")
SSH_USER="root"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no"

echo "╔══════════════════════════════════════╗"
echo "║     PGBOUNCER_FORCE_MD5_FALLBACK     ║"
echo "╚══════════════════════════════════════╝"

for px in "${PROXIES[@]}"; do
  echo "--- Proxy ${px} ---"
  ssh ${SSH_OPTS} ${SSH_USER}@${px} "sed -i 's/^auth_type = .*/auth_type = md5/' /etc/pgbouncer/pgbouncer.ini && systemctl restart pgbouncer && sleep 1 && systemctl --no-pager -l status pgbouncer || true"
done

echo "OK: PgBouncer basculé en MD5."
