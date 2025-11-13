#!/usr/bin/env bash
# pas de -e
set -uo pipefail

# === Couleurs ===
GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[1;33m"; NC="\033[0m"

ENV_CANDIDATES=(
  "./.env" "../.env" "../../.env"
  "/opt/keybuzz-installer/.env"
  "/opt/keybuzz-installer/config/.env"
  "/etc/keybuzz/.env"
)

_safe_source_env_file() {
  local f="$1"
  [ -f "$f" ] || return 1
  set -a
  local tmp; tmp="$(mktemp)"
  sed -E 's/^[[:space:]]*export[[:space:]]+//; /^[[:space:]]*#/d; /^[[:space:]]*$/d' "$f" > "$tmp"
  # shellcheck source=/dev/null
  . "$tmp"
  rm -f "$tmp"
  set +a
  echo "  - chargé: $f"
  return 0
}

_guess_pwd_from_env() {
  local candidates=(
    "${POSTGRES_SUPERUSER_PASSWORD:-}"
    "${POSTGRES_PASSWORD:-}"
    "${PATRONI_SUPERUSER_PASSWORD:-}"
    "${DB_SUPERPASS:-}"
    "${PG_SUPERPASS:-}"
    "${PGPASSWORD:-}"
  )
  for v in "${candidates[@]}"; do
    [ -n "${v:-}" ] && { echo "$v"; return 0; }
  done
  local line val
  for f in "${ENV_CANDIDATES[@]}"; do
    [ -f "$f" ] || continue
    line="$(grep -E '^(export[[:space:]]+)?(POSTGRES|PG|PATRONI).*(_?PASS(WORD)?)\s*=' "$f" | head -n1 || true)"
    [ -n "$line" ] || continue
    val="$(echo "$line" | sed -E 's/^[^=]*=\s*//; s/^["'\'']?(.*[^"'\''])["'\'']?$/\1/')"
    [ -n "$val" ] && { echo "$val"; return 0; }
  done
  echo ""
}

load_keybuzz_env() {
  echo "Chargement auto des .env ..."
  local any=0; for f in "${ENV_CANDIDATES[@]}"; do _safe_source_env_file "$f" && any=1; done
  [ "$any" -eq 0 ] && echo "  ! aucun .env détecté (je continue avec défauts)"

  # === Réseau / LB Hetzner ===
  export KB_LB_MODE="${KB_LB_MODE:-hetzner}"   # 'hetzner' | 'keepalived'
  export KB_VIP_IP="${KB_VIP_IP:-${VIP_IP:-10.0.0.10}}"
  export KB_PG_NATIVE_PORT="${KB_PG_NATIVE_PORT:-${PG_PORT:-5432}}"
  export KB_PGB_LOCAL_PORT="${KB_PGB_LOCAL_PORT:-6432}"
  export KB_PGB_VIP_PORT="${KB_PGB_VIP_PORT:-4632}"   # PORT côté LB Hetzner

  # Proxies (backends du LB)
  export KB_PROXY1_IP="${KB_PROXY1_IP:-${HAPROXY_01_IP:-10.0.0.11}}"
  export KB_PROXY2_IP="${KB_PROXY2_IP:-${HAPROXY_02_IP:-10.0.0.12}}"

  # Postgres
  export KB_PG_SUPERUSER="${KB_PG_SUPERUSER:-${POSTGRES_SUPERUSER:-postgres}}"
  export KB_PG_DBNAME="${KB_PG_DBNAME:-${POSTGRES_DB:-postgres}}"
  export KB_PGB_AUTH_MODE="${KB_PGB_AUTH_MODE:-scram}"

  local _pwd; _pwd="$(_guess_pwd_from_env)"
  export KB_PG_SUPERPASS="${_pwd}"

  export KB_PATRONI_LEADER_FILE="${KB_PATRONI_LEADER_FILE:-/tmp/patroni_leader_ip}"

  # === Images DOCKER (priorité : officielles stables qui ne demandent PAS env DATABASES) ===
  # On évite pgbouncer/pgbouncer:* (exige DATABASES/DATABASES_HOST) → KO vu tes logs
  if [ -z "${IMG_PGBOUNCER:-}" ]; then
    export IMG_PGBOUNCER_CANDIDATES=(
      "brainsam/pgbouncer:1.22"
      "brainsam/pgbouncer:latest"
      "edoburu/pgbouncer:latest"
      "bitnami/pgbouncer:latest"
    )
  else
    export IMG_PGBOUNCER_CANDIDATES=("${IMG_PGBOUNCER}")
  fi
  export IMG_HAPROXY="${IMG_HAPROXY:-haproxy:2.8}"

  # chemins côté proxy
  export REMOTE_BASE="/opt/keybuzz/pgbouncer"

  export GREEN RED YELLOW NC
}

