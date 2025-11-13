#!/usr/bin/env bash
set -euo pipefail

OK=$'\033[0;32mOK\033[0m'; KO=$'\033[0;31mKO\033[0m'
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CRED_ENV="/opt/keybuzz-installer/credentials/postgres.env"
TS="$(date +%Y%m%d_%H%M%S)"

need() { [ -s "$1" ] || { echo "$KO fichier manquant: $1" >&2; exit 1; }; }
need "$SERVERS_TSV"; need "$CRED_ENV"

set -a; source "$CRED_ENV"; set +a
API_USER="${PATRONI_API_USER:-patroni}"
API_PASS="${PATRONI_API_PASSWORD:?PATRONI_API_PASSWORD non défini dans $CRED_ENV}"
AUTH_B64="$(printf '%s:%s' "$API_USER" "$API_PASS" | base64 | tr -d '\n')"

get_ip() { awk -F'\t' -v h="$1" '$2==h{print $3}' "$SERVERS_TSV" | head -1; }

DB1_IP="$(get_ip db-master-01)"; [ -n "$DB1_IP" ] || { echo "$KO IP db-master-01 introuvable"; exit 1; }
DB2_IP="$(get_ip db-slave-01)";  [ -n "$DB2_IP" ] || { echo "$KO IP db-slave-01 introuvable"; exit 1; }
DB3_IP="$(get_ip db-slave-02)";  [ -n "$DB3_IP" ] || { echo "$KO IP db-slave-02 introuvable"; exit 1; }

HAPX_IPS=()
for h in haproxy-01 haproxy-02; do ip="$(get_ip "$h")"; [ -n "$ip" ] && HAPX_IPS+=("$ip"); done
[ "${#HAPX_IPS[@]}" -ge 1 ] || { echo "$KO aucune IP HAProxy trouvée"; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5)

patch_one() {
  local HIP="$1"
  echo "[*] Patch HAProxy @$HIP"

  # Sanity: tester Patroni REST depuis HAProxy (statut HTTP affiché)
  ssh "${ssh_opts[@]}" "root@${HIP}" bash -s <<EOF || true
set -e
for ip in "$DB1_IP" "$DB2_IP" "$DB3_IP"; do
  code=\$(curl -s -o /dev/null -w "%{http_code}" -m 2 -u "$API_USER:$API_PASS" "http://\${ip}:8008/patroni"); echo "  curl /patroni @\${ip}: \$code"
done
EOF

  ssh "${ssh_opts[@]}" "root@${HIP}" bash -s <<'EOF'
set -euo pipefail
TS="$(date +%Y%m%d_%H%M%S)"
CFG="/opt/keybuzz/haproxy/haproxy.cfg"
[ -f "$CFG" ] || { echo "KO: fichier manquant $CFG" >&2; exit 1; }
cp -a "$CFG" "${CFG}.bak.${TS}"
EOF

  # On réécrit les deux backends de manière déterministe (sans échapper bizarrement via awk)
  read -r -d '' NEW_MASTER <<EOT
backend be_pg_master
    mode http
    no option tcp-check
    option httpchk
    http-check connect
    http-check send meth GET uri /master ver HTTP/1.1 hdr Host patroni hdr Authorization "Basic ${AUTH_B64}"
    http-check expect status 200
    default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions
    server db1 ${DB1_IP}:5432 check port 8008
    server db2 ${DB2_IP}:5432 check port 8008
    server db3 ${DB3_IP}:5432 check port 8008
EOT

  read -r -d '' NEW_REPL <<EOT
backend be_pg_replicas
    mode http
    no option tcp-check
    balance roundrobin
    option httpchk
    http-check connect
    http-check send meth GET uri /replica ver HTTP/1.1 hdr Host patroni hdr Authorization "Basic ${AUTH_B64}"
    http-check expect status 200
    default-server inter 2s fall 3 rise 2
    server db1 ${DB1_IP}:5432 check port 8008
    server db2 ${DB2_IP}:5432 check port 8008
    server db3 ${DB3_IP}:5432 check port 8008
EOT

  # Remplacement côté hôte
  ssh "${ssh_opts[@]}" "root@${HIP}" bash -s <<'EOF'
set -euo pipefail
CFG="/opt/keybuzz/haproxy/haproxy.cfg"
TMP="$(mktemp)"
# On marque les zones à remplacer puis on réinserre notre contenu
awk '
  BEGIN{inM=0; inR=0}
  /^backend[[:space:]]+be_pg_master/ {inM=1; print "#__KB_START_MASTER__"; next}
  /^backend[[:space:]]+be_pg_replicas/ {inR=1; print "#__KB_START_REPL__"; next}
  (inM || inR) && (/^backend[[:space:]]+|^frontend[[:space:]]+|^listen[[:space:]]+|^$/) {
    if (inM) {print "#__KB_END_MASTER__"; inM=0}
    if (inR) {print "#__KB_END_REPL__"; inR=0}
    print; next
  }
  { if (!inM && !inR) print }
  END{
    if (inM) print "#__KB_END_MASTER__"
    if (inR) print "#__KB_END_REPL__"
  }
' "$CFG" > "$TMP"
mv "$TMP" "$CFG"
EOF

  # Injecte nos snippets
  ssh "${ssh_opts[@]}" "root@${HIP}" bash -s <<EOF
set -euo pipefail
CFG="/opt/keybuzz/haproxy/haproxy.cfg"
# Insert master block
if grep -q '#__KB_START_MASTER__' "\$CFG"; then
  awk 'BEGIN{inS=0}
       /#__KB_START_MASTER__/ {print; print "'"$(printf "%s" "$NEW_MASTER" | sed "s,/,\\\\/,g")"'"; inS=1; next}
       /#__KB_END_MASTER__/   {print; inS=0; next}
       {print}' "\$CFG" > "\$CFG.new" && mv "\$CFG.new" "\$CFG"
fi
# Insert replica block
if grep -q '#__KB_START_REPL__' "\$CFG"; then
  awk 'BEGIN{inS=0}
       /#__KB_START_REPL__/ {print; print "'"$(printf "%s" "$NEW_REPL" | sed "s,/,\\\\/,g")"'"; inS=1; next}
       /#__KB_END_REPL__/   {print; inS=0; next}
       {print}' "\$CFG" > "\$CFG.new" && mv "\$CFG.new" "\$CFG"
fi

# Redémarre/Recharge
if docker compose -f /opt/keybuzz/haproxy/docker-compose.yml ps >/dev/null 2>&1; then
  docker compose -f /opt/keybuzz/haproxy/docker-compose.yml up -d >/dev/null
  sleep 1
fi
EOF

  echo "  - Stats (après patch):"
  curl -s "http://${HIP}:8404/;csv" | egrep "be_pg_(master|replicas)|db[123]" | head -n 40 || true
}

for ip in "${HAPX_IPS[@]}"; do patch_one "$ip"; done

echo
echo "$OK Patch HAProxy (http-check + Basic Auth + no tcp-check) appliqué."
echo "Si un backend reste DOWN, teste manuellement depuis un haproxy :"
echo "  curl -u ${API_USER}:${API_PASS} http://${DB1_IP}:8008/master -i"
echo "  curl -u ${API_USER}:${API_PASS} http://${DB2_IP}:8008/replica -i"
