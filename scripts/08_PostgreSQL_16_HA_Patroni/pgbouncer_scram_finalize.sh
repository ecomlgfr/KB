#!/usr/bin/env bash
set -u
set -o pipefail

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33m⚠\033[0m'

HEADER() {
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║        PGBOUNCER_SCRAM_FINALIZE  -  Secure + Rollback             ║"
  echo "╚════════════════════════════════════════════════════════════════════╝"
}

SERVERS_TSV="${SERVERS_TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
CREDS_DIR="/opt/keybuzz-installer/credentials"
PG_ENV="$CREDS_DIR/postgres.env"
LB_VIP="${LB_VIP:-10.0.0.10}"     # si besoin: export LB_VIP=10.0.0.9
USERS_DEFAULT="postgres,n8n,chatwoot,pgbouncer"
USERS="${USERS:-$USERS_DEFAULT}"

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
get_ip() { awk -F'\t' -v h="$1" '$2==h {print $3}' "$SERVERS_TSV" | head -1; }

psql_container() {
  # $1 host, $2 port, $3 sql
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 \
    psql -v ON_ERROR_STOP=1 -h "$1" -p "$2" -U postgres -d postgres -Atc "$3"
}

psql_rw() {
  # essaie VIP:5432 puis proxies, puis leader via Patroni
  local sql="$1"

  # 1) VIP RW standard
  psql_container "$LB_VIP" 5432 "$sql" >/dev/null 2>&1 && return 0

  # 2) proxies en direct
  local H1_IP H2_IP
  H1_IP="$(get_ip haproxy-01)"
  H2_IP="$(get_ip haproxy-02)"
  [ -n "$H1_IP" ] && psql_container "$H1_IP" 5432 "$sql" >/dev/null 2>&1 && return 0
  [ -n "$H2_IP" ] && psql_container "$H2_IP" 5432 "$sql" >/dev/null 2>&1 && return 0

  # 3) autodétection leader via Patroni (API 8008)
  local ip role
  for DB in db-master-01 db-slave-01 db-slave-02; do
    ip="$(get_ip "$DB")"
    [ -z "$ip" ] && continue
    role="$(curl -s "http://$ip:8008/patroni" 2>/dev/null | sed -n 's/.*"role":"\([^"]*\)".*/\1/p')"
    if [ "$role" = "leader" ]; then
      psql_container "$ip" 5432 "$sql" >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

# -------------------------------------------------------------------
# Rollback
# -------------------------------------------------------------------
rollback_if_requested() {
  if [ "${1:-}" != "--rollback" ]; then return 1; fi
  local H1_IP H2_IP
  H1_IP="$(get_ip haproxy-01)"
  H2_IP="$(get_ip haproxy-02)"
  for IP in "$H1_IP" "$H2_IP"; do
    echo "Rollback proxy $IP ..."
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'EOS'
set -u; set -o pipefail
BASE="/opt/keybuzz/pgbouncer"
BK="$BASE/backup"
[ -d "$BK" ] || { echo "  (aucune sauvegarde)"; exit 0; }
LAST=$(ls -1dt "$BK"/* 2>/dev/null | head -1 || true)
[ -n "$LAST" ] || { echo "  (aucune sauvegarde)"; exit 0; }

install -D -m 640 "$LAST/userlist.txt"  "$BASE/config/userlist.txt" 2>/dev/null || true
install -D -m 640 "$LAST/pgbouncer.ini" "$BASE/config/pgbouncer.ini" 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
  docker ps | grep -q pgbouncer && docker restart pgbouncer >/dev/null 2>&1 || true
  [ -f "$BASE/docker-compose.yml" ] && (cd "$BASE" && docker compose up -d pgbouncer) >/dev/null 2>&1 || true
fi
echo "  rollback appliqué"
EOS
  done
  echo -e "$OK rollback terminé"
  exit 0
}

# -------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------
HEADER

# Guards
[ -f "$SERVERS_TSV" ] || { echo -e "$KO $SERVERS_TSV introuvable"; exit 1; }
[ -f "$PG_ENV" ]      || { echo -e "$KO $PG_ENV introuvable (POSTGRES_PASSWORD manquant)"; exit 1; }
# shellcheck disable=SC1090
. "$PG_ENV"
[ -n "${POSTGRES_PASSWORD:-}" ] || { echo -e "$KO POSTGRES_PASSWORD manquant dans $PG_ENV"; exit 1; }

# Rollback ?
rollback_if_requested "${1:-}"

# IP proxies
H1_IP="$(get_ip haproxy-01)"
H2_IP="$(get_ip haproxy-02)"
[ -n "$H1_IP" ] || { echo -e "$KO IP haproxy-01 introuvable"; exit 1; }
[ -n "$H2_IP" ] || { echo -e "$KO IP haproxy-02 introuvable"; exit 1; }

# Liste des users
IFS=',' read -r -a UARR <<< "$USERS"

# 1) Forcer SCRAM et créer/mettre à jour les rôles (sans écraser mdp existants du .env)
echo "1) Vérification/Création des rôles (SCRAM)..."
psql_rw "ALTER SYSTEM SET password_encryption='scram-sha-256'; SELECT pg_reload_conf();" || {
  echo -e "$KO connexion RW impossible (VIP:5432 puis proxies puis leader)"; exit 1; }

# Génère un mdp si manquant dans postgres.env, sinon conserve
genpass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }
for U in "${UARR[@]}"; do
  VAR="${U^^}_PASSWORD"    # ex N8N_PASSWORD
  # si mdp défini dans .env, on garde ; sinon on génère
  if grep -q "^${VAR}=" "$PG_ENV" 2>/dev/null; then
    eval "VAL=\${$VAR:-}"
  else
    VAL="$(genpass)"
    echo "${VAR}='$VAL'" >> "$PG_ENV"
  fi
  # créer/altérer le rôle pour assurer SCRAM
  psql_rw "DO \$$
DECLARE v text := '$VAL';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$U') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '$U', v);
  ELSE
    -- si le hash n'est pas SCRAM, on réécrit le mdp (reste identique si déjà SCRAM)
    IF (SELECT rolpassword NOT LIKE 'SCRAM-SHA-256%%' FROM pg_authid WHERE rolname='$U') THEN
      EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', '$U', v);
    END IF;
  END IF;
END\$$;" || { echo -e "$KO échec création/MAJ rôle $U"; exit 1; }
done
echo -e "  $OK rôles applicatifs présents (SCRAM)"

# 2) Récupérer les hash SCRAM complets
echo "2) Récupération des hash SCRAM..."
SCRAM_SQL="
SELECT format('\"%s\" \"%s\"', rolname, rolpassword)
FROM pg_authid
WHERE rolname IN ($(printf "'%s'," "${UARR[@]}" | sed 's/,$//'))
  AND rolpassword LIKE 'SCRAM-SHA-256%';"
SCRAM_LINES="$(psql_rw "$SCRAM_SQL" && docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 \
  psql -h "$LB_VIP" -p 5432 -U postgres -d postgres -Atc "$SCRAM_SQL" 2>/dev/null)"
# La seconde commande repasse par VIP:5432 pour écrire $SCRAM_LINES si psql_rw ne l'a pas écrit en stdout
if [ -z "$SCRAM_LINES" ]; then
  echo -e "$KO aucun hash SCRAM récupéré (crée/ALT les rôles + RW 5432)"; exit 1
fi
echo -e "  $OK hash SCRAM récupérés pour: $(echo "$SCRAM_LINES" | awk '{print $1}' | tr -d '"' | xargs echo)"

# 3) Déployer userlist + pgbouncer.ini sur les proxies (avec backup & restart)
echo "3) Déploiement sur proxies..."

deploy_on_proxy() {
  local IP="$1"
  local TARGET_HOST="$2"    # 127.0.0.1 si possible, sinon IP privée
  local NOW; NOW="$(date +%Y%m%d_%H%M%S)"

  # Prépare fichiers + sauvegardes
  ssh -o StrictHostKeyChecking=no root@"$IP" bash -s "$TARGET_HOST" "$NOW" <<'EOS'
set -u; set -o pipefail
TARGET_HOST="$1"; NOW="$2"
BASE="/opt/keybuzz/pgbouncer"
CFG="$BASE/config"
BK="$BASE/backup/$NOW"
mkdir -p "$CFG" "$BK"
[ -f "$CFG/pgbouncer.ini" ] && cp -f "$CFG/pgbouncer.ini" "$BK/pgbouncer.ini" || true
[ -f "$CFG/userlist.txt" ]  && cp -f "$CFG/userlist.txt"  "$BK/userlist.txt"  || true

IP_PRIV="$(hostname -I | awk '{print $1}')"
cat > "$CFG/pgbouncer.ini" <<INI
[databases]
* = host=${TARGET_HOST} port=5432

[pgbouncer]
listen_addr = ${IP_PRIV}
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 50
ignore_startup_parameters = extra_float_digits
server_tls_sslmode = disable
INI

: > "$CFG/userlist.txt"
EOS

  # Pousser la userlist SCRAM
  TMP="$(mktemp)"; printf "%s\n" "$SCRAM_LINES" > "$TMP"
  scp -o StrictHostKeyChecking=no "$TMP" root@"$IP":/opt/keybuzz/pgbouncer/config/userlist.txt >/dev/null 2>&1
  rm -f "$TMP"

  # Redémarrer PgBouncer
  ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'EOS'
set -u; set -o pipefail
BASE="/opt/keybuzz/pgbouncer"
if [ -f "$BASE/docker-compose.yml" ]; then
  (cd "$BASE" && docker compose up -d pgbouncer) >/dev/null 2>&1 || true
fi
docker ps | grep -q pgbouncer && docker restart pgbouncer >/dev/null 2>&1 || true
sleep 2
EOS
}

# Choisir la cible: loopback si HAProxy écoute en 127.0.0.1:5432, sinon IP privée
TARGET_A="127.0.0.1"
ssh -o StrictHostKeyChecking=no root@"$H1_IP" "nc -z 127.0.0.1 5432" >/dev/null 2>&1 || TARGET_A="$H1_IP"
deploy_on_proxy "$H1_IP" "$TARGET_A"

TARGET_B="127.0.0.1"
ssh -o StrictHostKeyChecking=no root@"$H2_IP" "nc -z 127.0.0.1 5432" >/dev/null 2>&1 || TARGET_B="$H2_IP"
deploy_on_proxy "$H2_IP" "$TARGET_B"

# 4) Tests finaux
echo "4) Tests de connectivité ..."
test_psql() {
  local HOST="$1"; local PORT="$2"; local NAME="$3"
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 \
    psql -h "$HOST" -p "$PORT" -U postgres -d postgres -Atc "select 1" >/dev/null 2>&1 \
    && echo -e "  $NAME: $OK" || echo -e "  $NAME: $KO"
}
test_psql "$H1_IP" 6432 "PgBouncer $H1_IP:6432"
test_psql "$H2_IP" 6432 "PgBouncer $H2_IP:6432"
test_psql "$LB_VIP" 4632 "VIP $LB_VIP:4632 (POOL)"

echo -e "$OK Terminé. Rollback possible : $0 --rollback"
