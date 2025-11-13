#!/usr/bin/env bash
set -euo pipefail

OK=$'\033[0;32mOK\033[0m'
KO=$'\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CRED_ENV="/opt/keybuzz-installer/credentials/postgres.env"
TS="$(date +%Y%m%d_%H%M%S)"

need_file() { [ -s "$1" ] || { echo "$KO fichier manquant: $1" >&2; exit 1; }; }
need_file "$SERVERS_TSV"
need_file "$CRED_ENV"

# Charge l’auth Patroni
set -a; source "$CRED_ENV"; set +a
API_USER="${PATRONI_API_USER:-patroni}"
API_PASS="${PATRONI_API_PASSWORD:?PATRONI_API_PASSWORD non défini dans $CRED_ENV}"
AUTH_B64="$(printf '%s:%s' "$API_USER" "$API_PASS" | base64 | tr -d '\n')"

# Récupère les IP privées des 3 nœuds DB depuis servers.tsv
get_ip() { awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }

DB1_IP="$(get_ip db-master-01)"; [ -n "$DB1_IP" ] || { echo "$KO IP db-master-01 introuvable"; exit 1; }
DB2_IP="$(get_ip db-slave-01)";  [ -n "$DB2_IP" ] || { echo "$KO IP db-slave-01 introuvable"; exit 1; }
DB3_IP="$(get_ip db-slave-02)";  [ -n "$DB3_IP" ] || { echo "$KO IP db-slave-02 introuvable"; exit 1; }

HAPX_IPS=()
for h in haproxy-01 haproxy-02; do
  ip="$(get_ip "$h")"
  [ -n "$ip" ] && HAPX_IPS+=("$ip")
done
[ "${#HAPX_IPS[@]}" -ge 1 ] || { echo "$KO aucune IP HAProxy trouvée"; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5)

patch_one_haproxy() {
  local HIP="$1"
  echo "[*] Patch HAProxy @$HIP"

  ssh "${ssh_opts[@]}" "root@${HIP}" bash -s <<EOF
set -euo pipefail
TS="${TS}"
CFG="/opt/keybuzz/haproxy/haproxy.cfg"
[ -f "\$CFG" ] || { echo "$KO fichier manquant \$CFG" >&2; exit 1; }
cp -a "\$CFG" "\${CFG}.bak.\${TS}"

# Réécrit UNIQUEMENT les backends be_pg_master et be_pg_replicas
awk '
  BEGIN{inblk=0; blk=""}
  function flushblk() {
    if (blk ~ /^backend[[:space:]]+be_pg_master/) {
      print "backend be_pg_master"
      print "    mode http"
      print "    option httpchk GET /master HTTP/1.1\\r\\nHost:\\ patroni\\r\\nAuthorization:\\ Basic\\ ${AUTH_B64}"
      print "    http-check expect status 200"
      print "    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions"
      print "    server db1 ${DB1_IP}:5432 check port 8008"
      print "    server db2 ${DB2_IP}:5432 check port 8008"
      print "    server db3 ${DB3_IP}:5432 check port 8008"
    } else if (blk ~ /^backend[[:space:]]+be_pg_replicas/) {
      print "backend be_pg_replicas"
      print "    mode http"
      print "    balance roundrobin"
      print "    option httpchk GET /replica HTTP/1.1\\r\\nHost:\\ patroni\\r\\nAuthorization:\\ Basic\\ ${AUTH_B64}"
      print "    http-check expect status 200"
      print "    default-server inter 3s fall 3 rise 2"
      print "    server db1 ${DB1_IP}:5432 check port 8008"
      print "    server db2 ${DB2_IP}:5432 check port 8008"
      print "    server db3 ${DB3_IP}:5432 check port 8008"
    } else {
      printf "%s", blk
    }
    blk=""
  }
  /^backend[[:space:]]+be_pg_(master|replicas)/{
    if (inblk) flushblk()
    inblk=1; blk=\$0 ORS; next
  }
  inblk && (/^backend[[:space:]]+|^frontend[[:space:]]+|^listen[[:space:]]+|^$/) {
    flushblk(); inblk=0
    print \$0; next
  }
  { if (inblk) blk = blk \$0 ORS; else print }
  END{ if (inblk) flushblk() }
' "\$CFG" > "\${CFG}.new.\${TS}"

mv "\${CFG}.new.\${TS}" "\$CFG"

# Redémarre/Recharge via compose si présent
if docker compose -f /opt/keybuzz/haproxy/docker-compose.yml ps >/dev/null 2>&1; then
  docker compose -f /opt/keybuzz/haproxy/docker-compose.yml up -d >/dev/null
  sleep 1
fi
EOF

  # Affiche un aperçu des stats CSV
  echo "  - Stats CSV :"
  curl -s "http://${HIP}:8404/;csv" | egrep "be_pg_(master|replicas)|db[123]" | head -n 40 || true
}

for ip in "${HAPX_IPS[@]}"; do
  patch_one_haproxy "$ip"
done

echo
echo "Vérifications psql (si credentials superuser disponibles) ..."
if [ -n "${KB_PG_SUPERUSER:-}" ] && [ -n "${POSTGRES_PASSWORD:-${KB_PG_SUPERPASS:-}}" ]; then
  export PGPASSWORD="${POSTGRES_PASSWORD:-${KB_PG_SUPERPASS:-}}"
  for ip in "${HAPX_IPS[@]}"; do
    echo "--- RW @$ip:5432 ---"
    psql -h "$ip" -p 5432 -U "${KB_PG_SUPERUSER:-postgres}" -d postgres -At -c 'select 1;' || true
    echo "--- RO @$ip:5433 ---"
    psql -h "$ip" -p 5433 -U "${KB_PG_SUPERUSER:-postgres}" -d postgres -At -c 'select 1;' || true
  done
else
  echo "(Infos superuser absentes — tests psql sautés)"
fi

echo "${OK} Patch HAProxy terminé."
