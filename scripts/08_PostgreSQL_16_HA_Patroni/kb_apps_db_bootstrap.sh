#!/usr/bin/env bash
# KB – Bootstrap DBs & roles (idempotent) via Patroni leader
set -u; set -o pipefail

TSV="${TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
CREDS_DIR="/opt/keybuzz-installer/credentials"
POSTGRES_ENV="${CREDS_DIR}/postgres.env"
APPS_ENV="${CREDS_DIR}/app_dbs.env"
VIP="${VIP:-10.0.0.10}"
POOL_PORT="${POOL_PORT:-4632}"
RW_PORT="${RW_PORT:-5432}"
PATRONI_PORT="${PATRONI_PORT:-8008}"

[[ -r "$TSV" && -r "$POSTGRES_ENV" ]] || { echo "❌ TSV ou postgres.env manquant"; exit 1; }

# charge PATRONI_API_PASSWORD & POSTGRES_PASSWORD
eval "$(
  awk -F= '
    $1 ~ /export[[:space:]]*PATRONI_API_PASSWORD/ {print "PATRONI_API_PASSWORD=" $2}
    $1 ~ /export[[:space:]]*POSTGRES_PASSWORD/    {print "POSTGRES_PASSWORD=" $2}
  ' "$POSTGRES_ENV"
)"
: "${PATRONI_API_PASSWORD:?}"; : "${POSTGRES_PASSWORD:?}"

# inventaire
declare -A IP
while IFS=$'\t' read -r pub role priv fqdn rest || [[ -n "${pub:-}" ]]; do
  case "$role" in db-master-01|db-slave-01|db-slave-02) IP[$role]="$priv";; esac
done < <(sed -e 's/\r$//' "$TSV")

# détecte le leader (/patroni) avec Basic auth
BASIC="$(printf 'patroni:%s' "$PATRONI_API_PASSWORD" | base64 | tr -d '\n')"
find_leader() {
  for ip in "${IP[db-master-01]}" "${IP[db-slave-01]}" "${IP[db-slave-02]}"; do
    role=$(curl -s -m 3 -H "Authorization: Basic $BASIC" "http://$ip:$PATRONI_PORT/patroni" \
           | awk -F\" '/"role":/ {print $4}')
    case "$role" in leader|master) echo "$ip"; return 0;; esac
  done
  return 1
}
LEADER="$(find_leader || true)"
[[ -n "$LEADER" ]] || { echo "❌ leader Patroni introuvable sur :$PATRONI_PORT"; exit 1; }

# secrets applis (créés si absents)
mkdir -p "$CREDS_DIR"; touch "$APPS_ENV"; chmod 600 "$APPS_ENV"
get_or_gen() {
  local key="$1"
  local val; val="$(awk -F= -v k="$key" '$1==k{print $2}' "$APPS_ENV" | tr -d '"' | tail -1)"
  [[ -n "$val" ]] || { val="$(head -c 24 /dev/urandom | base64)"; echo "$key=\"$val\"" >> "$APPS_ENV"; }
  echo "$val"
}
PW_KEYBUZZ=$(get_or_gen KEYBUZZ_PASS)
PW_N8N=$(get_or_gen N8N_PASS)
PW_CHATWOOT=$(get_or_gen CHATWOOT_PASS)
PW_BASEROW=$(get_or_gen BASEROW_PASS)
PW_NOCODB=$(get_or_gen NOCODB_PASS)
PW_GRAFANA=$(get_or_gen GRAFANA_PASS)

# SQL (idempotent) : rôles + bdd + extensions
read -r -d '' SQL <<'EOSQL'
DO $$
DECLARE r RECORD;
BEGIN
  -- create role helper
  PERFORM 1;
END $$;

-- Roles (LOGIN + SCRAM)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='keybuzz') THEN CREATE ROLE keybuzz LOGIN PASSWORD :'KEYBUZZ'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='n8n')     THEN CREATE ROLE n8n     LOGIN PASSWORD :'N8N'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='chatwoot')THEN CREATE ROLE chatwoot LOGIN PASSWORD :'CHATWOOT'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='baserow') THEN CREATE ROLE baserow LOGIN PASSWORD :'BASEROW'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='nocodb')  THEN CREATE ROLE nocodb  LOGIN PASSWORD :'NOCODB'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='grafana') THEN CREATE ROLE grafana LOGIN PASSWORD :'GRAFANA'; END IF;
  -- force update password/idempotent
  ALTER ROLE keybuzz  WITH LOGIN PASSWORD :'KEYBUZZ';
  ALTER ROLE n8n      WITH LOGIN PASSWORD :'N8N';
  ALTER ROLE chatwoot WITH LOGIN PASSWORD :'CHATWOOT';
  ALTER ROLE baserow  WITH LOGIN PASSWORD :'BASEROW';
  ALTER ROLE nocodb   WITH LOGIN PASSWORD :'NOCODB';
  ALTER ROLE grafana  WITH LOGIN PASSWORD :'GRAFANA';
END $$;

-- DBs (crée si absentes, owner = rôle)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='keybuzz') THEN CREATE DATABASE keybuzz OWNER keybuzz; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='n8n')     THEN CREATE DATABASE n8n     OWNER n8n;     END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='chatwoot') THEN CREATE DATABASE chatwoot OWNER chatwoot; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='baserow')  THEN CREATE DATABASE baserow  OWNER baserow;  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='nocodb')   THEN CREATE DATABASE nocodb   OWNER nocodb;   END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='grafana')  THEN CREATE DATABASE grafana  OWNER grafana;  END IF;
END $$;

-- Extensions utiles
\connect keybuzz
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

\connect n8n
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

\connect chatwoot
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

\connect baserow
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

\connect nocodb
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

\connect grafana
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

EOSQL

# exécute dans le conteneur patroni (host-network)
echo "▶️  Leader: $LEADER → création rôles/BDD/extensions…"
docker exec -i patroni psql -U postgres \
  --set=KEYBUZZ="$PW_KEYBUZZ" \
  --set=N8N="$PW_N8N" \
  --set=CHATWOOT="$PW_CHATWOOT" \
  --set=BASEROW="$PW_BASEROW" \
  --set=NOCODB="$PW_NOCODB" \
  --set=GRAFANA="$PW_GRAFANA" \
  -v ON_ERROR_STOP=1 -f - <<< "$SQL" || { echo "❌ psql a échoué"; exit 1; }

echo
echo "✅ Fini. DSN conseillés (POOL via PgBouncer – HA conseillé) :"
cat <<EOT
KEYBUZZ_DATABASE_URL=postgresql://keybuzz:${PW_KEYBUZZ}@${VIP}:${POOL_PORT}/keybuzz
N8N_DATABASE_URL=postgresql://n8n:${PW_N8N}@${VIP}:${POOL_PORT}/n8n
CHATWOOT_DATABASE_URL=postgresql://chatwoot:${PW_CHATWOOT}@${VIP}:${POOL_PORT}/chatwoot
BASEROW_DATABASE_URL=postgresql://baserow:${PW_BASEROW}@${VIP}:${POOL_PORT}/baserow
NOCODB_DATABASE_URL=postgresql://nocodb:${PW_NOCODB}@${VIP}:${POOL_PORT}/nocodb
GRAFANA_DATABASE_URL=postgresql://grafana:${PW_GRAFANA}@${VIP}:${POOL_PORT}/grafana
EOT

echo
echo "ℹ️  RW direct (debug):"
cat <<EOT
postgresql://keybuzz:${PW_KEYBUZZ}@${VIP}:${RW_PORT}/keybuzz
postgresql://n8n:${PW_N8N}@${VIP}:${RW_PORT}/n8n
EOT

echo
echo "👉 Notes:"
echo "  • n8n peut demander N8N_POSTGRESDB_QUERY_MODE=simple si erreurs de prepare."
echo "  • Chatwoot + PgBouncer: ok en mode transaction."
echo "  • Secrets stockés : $APPS_ENV (chmod 600)."
