#!/usr/bin/env bash
set -u
set -o pipefail
OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
SERVERS_TSV="${SERVERS_TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║               HAPROXY_ENABLE_LOOPBACK - 127.0.0.1:5432            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

[ -f "$SERVERS_TSV" ] || { echo -e "$KO servers.tsv introuvable"; exit 2; }
get_ip(){ awk -F'\t' -v h="$1" '$2==h {print $3}' "$SERVERS_TSV" | head -1; }
for H in haproxy-01 haproxy-02; do
  IP="$(get_ip "$H")"; [ -n "$IP" ] || { echo -e "$KO IP absente pour $H"; exit 2; }
  echo "Patch $H ($IP)..."
  ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'EOS'
set -u; set -o pipefail
CFG="/opt/keybuzz/db-proxy/config/haproxy.cfg"
[ -f "$CFG" ] || CFG="/etc/haproxy/haproxy.cfg"
[ -f "$CFG" ] || { echo "  pas de haproxy.cfg"; exit 1; }
cp -a "$CFG" "${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
# ajoute les binds loopback si absents
grep -qE 'bind 127\.0\.0\.1:5432' "$CFG" || sed -i '/frontend fe_pg_rw/a\  bind 127.0.0.1:5432' "$CFG"
grep -qE 'bind 127\.0\.0\.1:5433' "$CFG" || sed -i '/frontend fe_pg_ro/a\  bind 127.0.0.1:5433' "$CFG"
# restart container ou service
if docker ps | grep -q haproxy; then docker restart haproxy >/dev/null 2>&1 || true; fi
systemctl is-active haproxy >/dev/null 2>&1 && systemctl restart haproxy || true
# test
nc -z 127.0.0.1 5432 && echo "  127.0.0.1:5432 $OK" || echo "  127.0.0.1:5432 $KO"
EOS
done
echo -e "$OK terminé"
