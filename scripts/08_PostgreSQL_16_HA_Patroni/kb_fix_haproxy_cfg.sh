#!/usr/bin/env bash
set -euo pipefail

echo "▶️ KB – Fix HAProxy cfg (RW/RO TCP + stats) – $(date)"

TSV="/opt/keybuzz-installer/inventory/servers.tsv"
get(){ awk -F'\t' -v H="$1" '$2==H{print $3}' "$TSV" | head -1; }

IP_H1="$(get haproxy-01)"; IP_H2="$(get haproxy-02)"
IP_DB1="$(get db-master-01)"; IP_DB2="$(get db-slave-01)"; IP_DB3="$(get db-slave-02)"

# Sanity
for v in "$IP_H1" "$IP_H2" "$IP_DB1" "$IP_DB2" "$IP_DB3"; do
  [ -n "$v" ] || { echo "KO: IP introuvable dans servers.tsv"; exit 1; }
done

# === modèle haproxy.cfg (TCP frontends, checks HTTP patroni, stats :8404) ===
mk_cfg() {
cat <<CFG
global
  log stdout format raw local0
  maxconn 10000
  tune.ssl.default-dh-param 2048

defaults
  log     global
  mode    tcp
  option  dontlognull
  timeout connect 5s
  timeout client  1m
  timeout server  1m
  option  tcpka

# ---- STATS ----
listen stats
  bind 0.0.0.0:8404
  mode http
  stats enable
  stats uri /
  stats refresh 5s

# ---- Postgres RW (leader) ----
frontend fe_pg_rw
  bind 127.0.0.1:5432
  bind 0.0.0.0:5432
  default_backend be_pg_master

backend be_pg_master
  mode tcp
  option httpchk GET /master
  http-check expect status 200
  default-server inter 2s fall 2 rise 2
  server db1 $IP_DB1:5432 check port 8008
  server db2 $IP_DB2:5432 check port 8008
  server db3 $IP_DB3:5432 check port 8008

# ---- Postgres RO (replicas) ----
frontend fe_pg_ro
  bind 127.0.0.1:5433
  bind 0.0.0.0:5433
  default_backend be_pg_replicas

backend be_pg_replicas
  mode tcp
  balance roundrobin
  option httpchk GET /replica
  http-check expect status 200
  default-server inter 2s fall 2 rise 2
  server db1 $IP_DB1:5432 check port 8008
  server db2 $IP_DB2:5432 check port 8008
  server db3 $IP_DB3:5432 check port 8008
CFG
}

fix_proxy() {
  local IP="$1"
  echo "🔧 push cfg -> $IP"
  ssh -o StrictHostKeyChecking=no root@"$IP" bash -s <<'EOS'
set -euo pipefail
DIR="/opt/keybuzz/haproxy/data"
[ -d "$DIR" ] || DIR="/opt/keybuzz/haproxy"   # fallback si ancien layout
mkdir -p "$DIR"
[ -f "$DIR/haproxy.cfg" ] && cp -f "$DIR/haproxy.cfg" "$DIR/haproxy.cfg.bak.$(date +%Y%m%d_%H%M%S)" || true
cat > "$DIR/haproxy.cfg" <<'__CFG__'
__CFG__
chmod 644 "$DIR/haproxy.cfg"

# UFW (au cas où)
ufw status >/dev/null 2>&1 || { apt-get update -y && apt-get install -y ufw; }
ufw --force enable
ufw allow from 10.0.0.0/16 to any port 5432 proto tcp comment 'HAProxy RW'
ufw allow from 10.0.0.0/16 to any port 5433 proto tcp comment 'HAProxy RO'
ufw allow from 10.0.0.0/16 to any port 6432 proto tcp comment 'PgBouncer'
ufw allow from 10.0.0.0/16 to any port 8404 proto tcp comment 'HAProxy stats'

# Redémarrer le conteneur
docker ps --format '{{.Names}}' | grep -q '^haproxy$' && docker restart haproxy >/dev/null || true
sleep 2

# Vérifs locales
ss -ltnH | awk '{print $4}' | grep -q ':8404$' && echo "  -> :8404 écoute" || echo "  -> :8404 KO"
ss -ltnH | awk '{print $4}' | grep -q ':5432$' && echo "  -> :5432 écoute" || echo "  -> :5432 KO"
ss -ltnH | awk '{print $4}' | grep -q ':5433$' && echo "  -> :5433 écoute" || echo "  -> :5433 KO"
EOS
}

# Génère le fichier temporaire avec les IPs injectées
TMP_CFG="$(mktemp)"; mk_cfg > "$TMP_CFG"
# Injecter dans le heredoc distant
CFG_PAYLOAD="$(sed "s|__CFG__|$(sed 's/[&/\]/\\&/g' "$TMP_CFG")|g" <<<"__CFG__")"
rm -f "$TMP_CFG"

# Pousser sur H1/H2
ssh -o StrictHostKeyChecking=no root@"$IP_H1" "bash -s" <<<"$(declare -f); mk_cfg(){ :; }; $(typeset -f fix_proxy); cat <<'PAY' >/tmp/_cfgpayload; $CFG_PAYLOAD
PAY
bash -lc 'sed -n "1,/^PAY$/p" /tmp/_cfgpayload >/dev/null 2>&1';"
ssh -o StrictHostKeyChecking=no root@"$IP_H1" "bash -s" <<'EOS'
set -e
DIR="/opt/keybuzz/haproxy/data"; [ -d "$DIR" ] || DIR="/opt/keybuzz/haproxy"
cat /tmp/_cfgpayload | sed '1,/^PAY$/d' > "$DIR/haproxy.cfg"
docker ps --format '{{.Names}}' | grep -q '^haproxy$' && docker restart haproxy >/dev/null || true
ss -ltnH | awk '{print $4}' | egrep ':(5432|5433|8404)$' || true
EOS

ssh -o StrictHostKeyChecking=no root@"$IP_H2" "bash -s" <<<"$(declare -f); mk_cfg(){ :; }; $(typeset -f fix_proxy); cat <<'PAY' >/tmp/_cfgpayload; $CFG_PAYLOAD
PAY
bash -lc 'sed -n "1,/^PAY$/p" /tmp/_cfgpayload >/dev/null 2>&1';"
ssh -o StrictHostKeyChecking=no root@"$IP_H2" "bash -s" <<'EOS'
set -e
DIR="/opt/keybuzz/haproxy/data"; [ -d "$DIR" ] || DIR="/opt/keybuzz/haproxy"
cat /tmp/_cfgpayload | sed '1,/^PAY$/d' > "$DIR/haproxy.cfg"
docker ps --format '{{.Names}}' | grep -q '^haproxy$' && docker restart haproxy >/dev/null || true
ss -ltnH | awk '{print $4}' | egrep ':(5432|5433|8404)$' || true
EOS

echo "✅ HAProxy cfg poussé et conteneurs relancés."
echo "➡️  Tests suggérés :"
echo "  nc -zv $IP_H1 8404 && echo stats_H1_OK; nc -zv $IP_H2 8404 && echo stats_H2_OK"
echo "  psql -h 10.0.0.10 -p 5432 -U postgres -d postgres -c 'select version();'  # avec PGPASSWORD exporté"
