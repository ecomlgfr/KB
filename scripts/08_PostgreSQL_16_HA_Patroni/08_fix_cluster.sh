#!/usr/bin/env bash
set -euo pipefail

OK=$'\033[0;32mOK\033[0m'
KO=$'\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CRED_ENV="/opt/keybuzz-installer/credentials/postgres.env"
TS="$(date +%Y%m%d_%H%M%S)"

log() { echo "[$(date +%H:%M:%S)] $*"; }

need_file() {
  [ -s "$1" ] || { echo "$KO fichier manquant: $1" >&2; exit 1; }
}

get_ip() {
  local host="$1"
  awk -F'\t' -v h="$host" '$2==h{print $3}' "$SERVERS_TSV" | head -1
}

need_file "$SERVERS_TSV"
need_file "$CRED_ENV"
# charge les secrets localement (jamais affichés)
# shellcheck disable=SC1090
set -a; source "$CRED_ENV"; set +a
API_USER="${PATRONI_API_USER:-patroni}"
API_PASS="${PATRONI_API_PASSWORD:?PATRONI_API_PASSWORD non défini dans $CRED_ENV}"
AUTH_B64="$(printf '%s:%s' "$API_USER" "$API_PASS" | base64 | tr -d '\n')"

DBS=( "db-master-01" "db-slave-01" "db-slave-02" )
HAPX=( "haproxy-01" "haproxy-02" )

ssh_opts=(-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5)

remote() {
  local ip="$1"; shift
  ssh "${ssh_opts[@]}" "root@${ip}" "$@"
}

copyin() {
  local ip="$1" src="$2" dst="$3"
  scp "${ssh_opts[@]}" "$src" "root@${ip}:$dst" >/dev/null
}

###############################################
# 1) Patch côté DB: UFW:7000 + pg_hba localhost
###############################################
for H in "${DBS[@]}"; do
  IP="$(get_ip "$H")"
  [ -n "$IP" ] || { echo "$KO IP introuvable pour $H"; exit 1; }
  log "DB $H @$IP : UFW:7000 + pg_hba localhost + reload"

  remote "$IP" "bash -s" <<'EOS'
set -euo pipefail
TS="$(date +%Y%m%d_%H%M%S)"

# 1) Ouvrir RAFT 7000 si ufw actif
if command -v ufw >/dev/null 2>&1; then
  ufw status | grep -q 'Status: active' && {
    ufw status | grep -qE '7000/tcp' || ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni RAFT'
  }
fi

# 2) Ajouter ligne pg_hba pour localhost réplication dans le cluster en cours si présent
for HBA in \
  /opt/keybuzz/postgres/data/pg_hba.conf \
  /var/lib/postgresql/data/pg_hba.conf
do
  [ -f "$HBA" ] || continue
  grep -qE 'host\s+replication\s+replicator\s+127\.0\.0\.1/32\s+scram-sha-256' "$HBA" || {
    cp -a "$HBA" "$HBA.bak.${TS}"
    printf "%s\n" "host    replication     replicator      127.0.0.1/32          scram-sha-256" >> "$HBA"
    touch "/tmp/_kb_pg_hba_updated"
  }
done

# 3) Tenter aussi de pérenniser dans patroni.yml (si présent)
PATRONI_YML="/opt/keybuzz/patroni/config/patroni.yml"
if [ -f "$PATRONI_YML" ]; then
  if ! grep -qE '^\s*-\s*host\s+replication\s+replicator\s+127\.0\.0\.1/32\s+scram-sha-256\s*$' "$PATRONI_YML"; then
    cp -a "$PATRONI_YML" "$PATRONI_YML.bak.${TS}"
    # Insérer proprement dans la section bootstrap.pg_hba si trouvée, sinon append à la fin avec indentation minimale
    if awk 'BEGIN{f=0} /^bootstrap:/ {f=1} f && /^ *pg_hba:/ {print; exit 0} END{exit 1}' "$PATRONI_YML" >/dev/null; then
      awk '
        BEGIN{in_boot=0; in_pg=0}
        /^bootstrap:/ {in_boot=1}
        {print}
        in_boot && /^ *pg_hba:/ {print "  - host replication replicator 127.0.0.1/32 scram-sha-256"; in_boot=0}
      ' "$PATRONI_YML" > "${PATRONI_YML}.new.${TS}" && mv "${PATRONI_YML}.new.${TS}" "$PATRONI_YML"
    else
      printf "\nbootstrap:\n  pg_hba:\n  - host replication replicator 127.0.0.1/32 scram-sha-256\n" >> "$PATRONI_YML"
    fi
    touch "/tmp/_kb_patroni_yml_updated"
  fi
  # Homogénéiser le scope si besoin (optionnel, safe)
  if grep -q '^scope:' "$PATRONI_YML" && ! grep -q '^scope: keybuzz' "$PATRONI_YML"; then
    sed -i "s/^scope:.*/scope: keybuzz/" "$PATRONI_YML"
    touch "/tmp/_kb_patroni_yml_updated"
  fi
fi

# 4) Reload PostgreSQL/Patroni si on a modifié un des fichiers
if [ -f /tmp/_kb_pg_hba_updated ]; then
  # essaye rechargement doux
  if command -v pg_ctl >/dev/null 2>&1; then
    pg_ctl reload -D /var/lib/postgresql/data >/dev/null 2>&1 || true
  fi
  # si Patroni gère l’instance, demande un reload via REST (laisse le script parent le faire)
fi
EOS

  # Reload via REST si possible (autorisé basic)
  # (Ne bloque pas si indisponible)
  curl -s -m 2 -u "${API_USER}:${API_PASS}" "http://${IP}:8008/reload" >/dev/null 2>&1 || true
done
log "DB: ${OK}"

###############################################################
# 2) HAProxy: checks HTTP /master & /replica avec Authorization
###############################################################
# Récup des IP haproxy + patch de la config
for H in "${HAPX[@]}"; do
  IP="$(get_ip "$H")"
  [ -n "$IP" ] || { echo "$KO IP introuvable pour $H"; exit 1; }
  log "HAProxy $H @$IP : patch backends (httpchk + Authorization)"

  remote "$IP" "bash -s" <<EOS
set -euo pipefail
TS="$(date +%Y%m%d_%H%M%S)"
AUTH_B64="${AUTH_B64}"

CFG="/opt/keybuzz/haproxy/haproxy.cfg"
[ -f "\$CFG" ] || { echo "$KO fichier manquant \$CFG" >&2; exit 1; }
cp -a "\$CFG" "\${CFG}.bak.\${TS}"

# Reconstruire proprement les blocs backends master/replicas
awk -v auth="\$AUTH_B64" '
  BEGIN{inblk=0; blk=""}
  function flushblk() {
    if (blk ~ /backend[[:space:]]+be_pg_master/) {
      print "backend be_pg_master"
      print "    mode http"
      print "    option httpchk GET /master HTTP/1.1\\r\\nHost:\\ patroni\\r\\nAuthorization:\\ Basic\\ " auth
      print "    http-check expect status 200"
      print "    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions"
      print "    server db1 ${DB1}:5432 check port 8008"
      print "    server db2 ${DB2}:5432 check port 8008"
      print "    server db3 ${DB3}:5432 check port 8008"
    } else if (blk ~ /backend[[:space:]]+be_pg_replicas/) {
      print "backend be_pg_replicas"
      print "    mode http"
      print "    balance roundrobin"
      print "    option httpchk GET /replica HTTP/1.1\\r\\nHost:\\ patroni\\r\\nAuthorization:\\ Basic\\ " auth
      print "    http-check expect status 200"
      print "    default-server inter 3s fall 3 rise 2"
      print "    server db1 ${DB1}:5432 check port 8008"
      print "    server db2 ${DB2}:5432 check port 8008"
      print "    server db3 ${DB3}:5432 check port 8008"
    } else {
      printf "%s", blk
    }
    blk=""
  }
  /^backend[[:space:]]+be_pg_(master|replicas)/{ # commence capture
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

# Résolution des IP DB à injecter (depuis hosts / variables)
# On remplace placeholders si présents
DB1_IP="$(awk -F'\t' '\$2==\"db-master-01\"{print \$3}' "$SERVERS_TSV" | head -1)"
DB2_IP="$(awk -F'\t' '\$2==\"db-slave-01\"{print \$3}' "$SERVERS_TSV" | head -1)"
DB3_IP="$(awk -F'\t' '\$2==\"db-slave-02\"{print \$3}' "$SERVERS_TSV" | head -1)"

# Si les placeholders \${DB1} etc existent, substituer
sed -i "s|\${DB1}|${DB1_IP:-10.0.0.120}|g; s|\${DB2}|${DB2_IP:-10.0.0.121}|g; s|\${DB3}|${DB3_IP:-10.0.0.122}|g" "\${CFG}.new.\${TS}" || true

mv "\${CFG}.new.\${TS}" "\$CFG"

# Restart/Reload haproxy via docker compose
if docker compose -f /opt/keybuzz/haproxy/docker-compose.yml ps >/dev/null 2>&1; then
  docker compose -f /opt/keybuzz/haproxy/docker-compose.yml up -d >/dev/null
  sleep 1
fi
EOS

  # Vérif rapide des CSV stats
  curl -s "http://${IP}:8404/;csv" | egrep -m1 "be_pg_(master|replicas)" || true
done
log "HAProxy: ${OK}"

##########################################################
# 3) Post-vérifs rapides (non bloquants, affichage simple)
##########################################################
for H in "${HAPX[@]}"; do
  IP="$(get_ip "$H")"
  log "Check HAProxy CSV @$IP"
  curl -s "http://${IP}:8404/;csv" | egrep "be_pg_(master|replicas)|db[123]" | head -n 40 || true
done

# Tentative d'un SELECT 1 via proxys RW/RO (si superuser configuré)
if [ -n "${KB_PG_SUPERUSER:-}" ] && [ -n "${POSTGRES_PASSWORD:-${KB_PG_SUPERPASS:-}}" ]; then
  export PGPASSWORD="${POSTGRES_PASSWORD:-${KB_PG_SUPERPASS:-}}"
  for H in "${HAPX[@]}"; do
    IP="$(get_ip "$H")"
    log "psql RW @$IP:5432"
    psql -h "$IP" -p 5432 -U "${KB_PG_SUPERUSER:-postgres}" -d postgres -At -c 'select 1;' || true
    log "psql RO @$IP:5433"
    psql -h "$IP" -p 5433 -U "${KB_PG_SUPERUSER:-postgres}" -d postgres -At -c 'select 1;' || true
  done
fi

echo "--------------------------------------------"
echo "Patch terminé. Vérifie ci-dessus les sorties."
echo "Si certains backends restent DOWN :"
echo " - Auth Basic sur checks OK ?"
echo " - Patroni REST :8008 joignable ?"
echo " - RAFT 7000 ouvert ?"
echo "--------------------------------------------"
