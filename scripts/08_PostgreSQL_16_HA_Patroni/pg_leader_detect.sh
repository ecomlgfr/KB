#!/usr/bin/env bash
set -u
set -o pipefail
OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
SERVERS_TSV="${SERVERS_TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                 PG LEADER DETECT - Patroni API                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
[ -f "$SERVERS_TSV" ] || { echo -e "$KO servers.tsv introuvable"; exit 2; }
get_ip(){ awk -F'\t' -v h="$1" '$2==h {print $3}' "$SERVERS_TSV" | head -1; }
for H in db-master-01 db-slave-01 db-slave-02; do
  IP="$(get_ip "$H")"; [ -n "$IP" ] || continue
  ROLE="$(curl -s "http://$IP:8008/patroni" | sed -n 's/.*"role":"\([^"]*\)".*/\1/p')"
  if [ "$ROLE" = "leader" ]; then echo -e "$OK Leader: $H ($IP)"; echo "$IP"; exit 0; fi
done
echo -e "$KO leader introuvable (API Patroni injoignable ?)"; exit 1
