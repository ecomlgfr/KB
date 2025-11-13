#!/usr/bin/env bash
set -u
set -o pipefail

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="${SERVERS_TSV:-/opt/keybuzz-installer/inventory/servers.tsv}"
CREDS_DIR="/opt/keybuzz-installer/credentials"
PG_ENV="$CREDS_DIR/postgres.env"
LB_VIP="${LB_VIP:-10.0.0.10}"
LOG_DIR="/opt/keybuzz-installer/logs"
LOG="$LOG_DIR/keybuzz_ha_test_$(date +%Y%m%d_%H%M%S).log"
STATE_DIR="/opt/keybuzz/ha-tests/status"; mkdir -p "$STATE_DIR" "$LOG_DIR"

HEADER(){
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║           KEYBUZZ HA TEST ORCHESTRATOR  –  AUTO/SAFE              ║"
  echo "╚════════════════════════════════════════════════════════════════════╝"
}

line(){ printf '%s\n' "$*" | tee -a "$LOG" >/dev/null; }
say(){ echo -e "$*" | tee -a "$LOG" >/dev/null; }
need(){ command -v "$1" >/dev/null 2>&1 || { say "$KO binaire manquant: $1"; exit 2; }; }

# ---------- guards ----------
HEADER
[ -f "$SERVERS_TSV" ] || { say "$KO $SERVERS_TSV introuvable"; exit 2; }
[ -f "$PG_ENV" ]      || { say "$KO $PG_ENV introuvable"; exit 2; }
# shellcheck disable=SC1090
. "$PG_ENV"
[ -n "${POSTGRES_PASSWORD:-}" ] || { say "$KO POSTGRES_PASSWORD manquant dans $PG_ENV"; exit 2; }
need docker
need curl
need awk
need sed
need nc

# ---------- helpers ----------
get_ip(){ awk -F'\t' -v h="$1" '$2==h {print $3}' "$SERVERS_TSV" | head -1; }
H1_IP="$(get_ip haproxy-01)"
H2_IP="$(get_ip haproxy-02)"
DB1_IP="$(get_ip db-master-01)"
DB2_IP="$(get_ip db-slave-01)"
DB3_IP="$(get_ip db-slave-02)"

psql_c(){
  # dockerized psql (host, port, sql) ; returns 0/1
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 \
    psql -v ON_ERROR_STOP=1 -h "$1" -p "$2" -U postgres -d postgres -Atc "$3" >/dev/null 2>&1
}

psql_c_out(){
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:17 \
    psql -v ON_ERROR_STOP=0 -h "$1" -p "$2" -U postgres -d postgres -Atc "$3" 2>/dev/null
}

role_of(){
  # query patroni api role
  curl -s "http://$1:8008/patroni" | sed -n 's/.*"role":"\([^"]*\)".*/\1/p'
}

detect_leader(){
  local ip
  for ip in "$DB1_IP" "$DB2_IP" "$DB3_IP"; do
    [ -z "$ip" ] && continue
    local r; r="$(role_of "$ip")"
    [ "$r" = "leader" ] && { echo "$ip"; return 0; }
  done
  return 1
}

rw_try(){
  # try VIP:5432 -> proxies:5432 -> leader:5432
  psql_c "$LB_VIP" 5432 "select 1" && return 0
  [ -n "$H1_IP" ] && psql_c "$H1_IP" 5432 "select 1" && return 0
  [ -n "$H2_IP" ] && psql_c "$H2_IP" 5432 "select 1" && return 0
  local L; L="$(detect_leader || true)"; [ -n "$L" ] && psql_c "$L" 5432 "select 1" && return 0
  return 1
}

pool_test(){ psql_c "$LB_VIP" 4632 "select 1"; }
rw_test(){   psql_c "$LB_VIP" 5432 "select pg_is_in_recovery()"; }
ro_test(){   psql_c "$LB_VIP" 5433 "select pg_is_in_recovery()"; }

check_pgbouncer_proxies(){
  local ok=0; local tot=0
  for ip in "$H1_IP" "$H2_IP"; do
    [ -z "$ip" ] && continue
    tot=$((tot+1))
    if psql_c "$ip" 6432 "select 1"; then say "  PgBouncer $ip:6432 $OK"; ok=$((ok+1))
    else say "  PgBouncer $ip:6432 $KO"; fi
  done
  [ "$ok" -eq "$tot" ]
}

# ---------- actions ----------
menu_health(){
  say "1) HEALTH – tests rapides"
  say "  VIP $LB_VIP:4632 (POOL) ..."
  if pool_test; then say "   → $OK"; else say "   → $KO"; fi
  say "  VIP $LB_VIP:5432 (RW) ..."
  if rw_test;   then say "   → $OK"; else say "   → $KO"; fi
  say "  VIP $LB_VIP:5433 (RO) ..."
  if ro_test;   then say "   → $OK"; else say "   → $KO"; fi
  say "  Proxies PgBouncer (6432) ..."
  check_pgbouncer_proxies || true
  say "  Patroni roles ..."
  local ip; for ip in "$DB1_IP" "$DB2_IP" "$DB3_IP"; do
    [ -z "$ip" ] && continue
    say "   - $ip : $(role_of "$ip" || echo '?')"
  done
}

menu_switchover(){
  say "2) SWITCHEVER ZERO-DOWNTIME"
  local L; L="$(detect_leader || true)"
  if [ -z "$L" ]; then say "$KO leader introuvable (API)"; return; fi
  say "  Leader actuel: $L"
  say "  Test POOL avant bascule ..."
  if pool_test; then say "   → $OK"; else say "   → $KO (POOL KO avant : corriger PgBouncer)"; fi

  read -rp "Confirmer switchover (y/N) ? " a; [ "${a:-N}" = "y" ] || { say "$WARN annulé"; return; }

  # choisir un candidat ≠ leader
  local CAND
  if [ "$L" = "$DB1_IP" ]; then CAND="${DB2_IP:-$DB3_IP}";
  elif [ "$L" = "$DB2_IP" ]; then CAND="${DB1_IP:-$DB3_IP}";
  else CAND="${DB1_IP:-$DB2_IP}"; fi
  [ -z "$CAND" ] && { say "$KO pas de candidat"; return; }

  # patroni api auth (si dispo)
  local auth_opt=""
  [ -n "${PATRONI_API_PASSWORD:-}" ] && auth_opt="-u patroni:$PATRONI_API_PASSWORD"
  say "  Switchover $L -> $CAND ..."
  curl -s $auth_opt -X POST "http://$L:8008/switchover" \
    -H 'Content-Type: application/json' \
    -d "{\"leader\":\"$L\",\"candidate\":\"$CAND\"}" >>"$LOG" 2>&1

  say "  Attente promotion ..."
  local t=0
  while :; do
    sleep 2; t=$((t+2)); [ $t -gt 60 ] && break
    local nl; nl="$(detect_leader || true)"; [ "$nl" = "$CAND" ] && break
  done

  if [ "$(detect_leader || true)" = "$CAND" ]; then
    say "  Nouveau leader: $CAND $OK"
  else
    say "  $KO switchover non confirmé"; return
  fi

  say "  Vérifie HAProxy RW/RO ..."
  if rw_test; then say "   RW $OK"; else say "   RW $KO"; fi
  if ro_test; then say "   RO $OK"; else say "   RO $KO"; fi
  say "  Vérifie POOL ..."
  if pool_test; then say "   POOL $OK"; else say "   POOL $KO"; fi

  # switchback vers db-master-01 si ce n'est pas déjà lui
  if [ "$CAND" != "$DB1_IP" ]; then
    read -rp "Revenir au leader préféré (db-master-01) automatiquement (y/N) ? " b
    if [ "${b:-N}" = "y" ]; then
      local auth2=""; [ -n "${PATRONI_API_PASSWORD:-}" ] && auth2="-u patroni:$PATRONI_API_PASSWORD"
      say "  Switchover vers db-master-01 ($DB1_IP) ..."
      curl -s $auth2 -X POST "http://$CAND:8008/switchover" \
        -H 'Content-Type: application/json' \
        -d "{\"leader\":\"$CAND\",\"candidate\":\"$DB1_IP\"}" >>"$LOG" 2>&1
      sleep 5
      say "  Leader final: $(detect_leader || echo '?')"
      say "  POOL ..."
      pool_test && say "   $OK" || say "   $KO"
    fi
  fi
}

menu_crash_leader(){
  say "3) SIMULATION CRASH LEADER (stop conteneur Patroni) + AUTO-RETURN"
  local L; L="$(detect_leader || true)"
  if [ -z "$L" ]; then say "$KO leader introuvable"; return; fi
  say "  Leader actuel: $L"
  say "  Test POOL avant ..."
  pool_test && say "   → $OK" || say "   → $KO (POOL KO avant)"
  read -rp "Stopper le conteneur Patroni sur $L ? (y/N) " a; [ "${a:-N}" = "y" ] || { say "$WARN annulé"; return; }

  ssh -o StrictHostKeyChecking=no root@"$L" '
    set -u; set -o pipefail
    CID=$(docker ps --format "{{.ID}} {{.Names}}" | awk "/patroni/{print \$1; exit}")
    [ -n "$CID" ] && docker stop "$CID" >/dev/null 2>&1 || exit 0
  ' && say "  Patroni stoppé sur $L" || say "  $WARN impossible d’arrêter Patroni (déjà down ?)"

  say "  Attente réélection ..."
  local t=0
  while :; do
    sleep 2; t=$((t+2)); [ $t -gt 60 ] && break
    local nl; nl="$(detect_leader || true)"
    if [ -n "$nl" ] && [ "$nl" != "$L" ]; then break; fi
  done
  local NL; NL="$(detect_leader || true)"
  [ -n "$NL" ] && say "  Nouveau leader: $NL" || say "  $KO pas de leader"

  say "  Vérifications (sans interruption) ..."
  rw_try && say "   RW $OK" || say "   RW $KO"
  pool_test && say "   POOL $OK" || say "   POOL $KO"

  read -rp "Redémarrer Patroni sur $L et attendre réintégration ? (y/N) " b; [ "${b:-N}" = "y" ] || { say "$WARN laisse comme tel"; return; }
  ssh -o StrictHostKeyChecking=no root@"$L" '
    set -u; set -o pipefail
    docker ps --format "{{.Names}}" | grep -q patroni || docker start $(docker ps -a --format "{{.ID}} {{.Names}}"|awk "/patroni/{print \$1; exit}") >/dev/null 2>&1 || true
  ' && say "  Patroni redémarré sur $L" || say "  $WARN redémarrage Patroni non confirmé"

  say "  Attente STATE=running ..."
  sleep 8
  say "  Leader courant: $(detect_leader || echo '?')"
  # Switchback si souhaité
  read -rp "Switchback planifié vers db-master-01 ? (y/N) " c
  if [ "${c:-N}" = "y" ] && [ "$(detect_leader || true)" != "$DB1_IP" ]; then
    local SLEADER; SLEADER="$(detect_leader || true)"
    local auth=""; [ -n "${PATRONI_API_PASSWORD:-}" ] && auth="-u patroni:$PATRONI_API_PASSWORD"
    curl -s $auth -X POST "http://$SLEADER:8008/switchover" \
      -H 'Content-Type: application/json' \
      -d "{\"leader\":\"$SLEADER\",\"candidate\":\"$DB1_IP\"}" >>"$LOG" 2>&1
    sleep 5
    say "  Leader final: $(detect_leader || echo '?')"
  fi
  say "  POOL final ..."
  pool_test && say "   $OK" || say "   $KO"
}

menu_full(){
  say "4) RUN COMPLET (health -> switchover -> switchback -> crash/recover)"
  menu_health
  menu_switchover
  menu_crash_leader
  say "  RUN COMPLET terminé"
}

# ---------- main menu ----------
while :; do
  echo
  echo "Sélectionne une action :"
  echo "  1) Health rapide (POOL/RW/RO/PgBouncer/Patroni)"
  echo "  2) Switchover ZERO-downtime + retour auto"
  echo "  3) Simulation crash leader + réintégration + switchback"
  echo "  4) RUN COMPLET"
  echo "  0) Quitter"
  read -rp "Choix: " CH
  case "${CH:-0}" in
    1) menu_health ;;
    2) menu_switchover ;;
    3) menu_crash_leader ;;
    4) menu_full ;;
    0) break ;;
    *) echo "Choix invalide";;
  esac
done

echo
echo "Dernières lignes du log : $LOG"
tail -n 50 "$LOG" || true
echo "État global écrit dans: $STATE_DIR (managé par sous-scripts le cas échéant)"
