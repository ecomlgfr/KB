#!/usr/bin/env bash
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓${NC} $*"; }
ko() { echo -e "${RED}✗${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

cat <<'EOF'
╔════════════════════════════════════════════════════════════════════╗
║         PRÉPARATION SERVEURS - SANS WIREGUARD                      ║
╚════════════════════════════════════════════════════════════════════╝
EOF

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/prepare_simple_$TIMESTAMP.log"
PARALLEL_JOBS=10

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG") 2>&1

[[ ! -f "$SERVERS_TSV" ]] && { ko "servers.tsv introuvable"; exit 1; }

TOTAL=$(grep -cE "^[0-9]" "$SERVERS_TSV" || echo 0)
ok "$TOTAL serveurs détectés"
echo ""

warn "Ce script va:"
echo "  • Mettre à jour apt"
echo "  • Installer outils de base"
echo "  • Vérifier Docker + compose"
echo "  • Créer structure /opt/keybuzz"
echo "  • Activer UFW (règles sécurisées)"
echo ""
echo "  SANS installer WireGuard (réseau Hetzner natif conservé)"
echo ""
read -p "Continuer? (y/N) " -r
[[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Annulé"; exit 0; }

echo ""
ok "Démarrage préparation..."
echo ""

install_server() {
    local ip="$1"
    local hostname="$2"
    local ip_priv="$3"
    
    if ! timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 root@"$ip_priv" "echo 1" &>/dev/null; then
        echo "$hostname: KO (SSH)"
        return 1
    fi
    
    ssh -o BatchMode=yes root@"$ip_priv" "bash -s" <<'REMOTE_SCRIPT'
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive

# Update
apt-get update -qq >/dev/null 2>&1

# Outils de base
apt-get install -y -qq curl wget git jq htop vim net-tools ca-certificates gnupg lsb-release ufw >/dev/null 2>&1

# Docker si absent
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com 2>/dev/null | sh >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
fi

# Plugin compose si absent
if ! docker compose version &>/dev/null; then
    apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1
fi

# Structure KeyBuzz
mkdir -p /opt/keybuzz/{configs,scripts,ssl,credentials,logs}
chmod 700 /opt/keybuzz/credentials

# UFW basique (sera complété par SECURE_UFW_HETZNER.sh)
if ! ufw status | grep -q "Status: active"; then
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow from 10.0.0.0/16 >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
fi

# Vérif finale
if docker --version &>/dev/null && docker compose version &>/dev/null; then
    echo "OK"
else
    echo "KO"
    exit 1
fi
REMOTE_SCRIPT
    
    if [[ $? -eq 0 ]]; then
        echo "$hostname: OK"
        return 0
    else
        echo "$hostname: KO"
        return 1
    fi
}

export -f install_server

if ! command -v parallel &>/dev/null; then
    warn "Installation GNU parallel..."
    apt-get update -qq && apt-get install -y -qq parallel >/dev/null 2>&1
fi

echo "Installation parallèle ($PARALLEL_JOBS jobs):"
echo ""

grep -E "^[0-9]" "$SERVERS_TSV" | parallel -j "$PARALLEL_JOBS" --colsep '\t' \
    install_server {1} {2} {3}

echo ""
echo "══════════════════════════════════════════════════════════════════"

SUCCESS=$(grep "OK$" "$MAIN_LOG" | wc -l)
FAILED=$(grep "KO" "$MAIN_LOG" | wc -l)

echo "RÉSUMÉ:"
echo "  Total:   $TOTAL"
echo "  Réussis: $SUCCESS"
echo "  Échecs:  $FAILED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    ok "PRÉPARATION COMPLÈTE"
    echo ""
    echo "PROCHAINES ÉTAPES:"
    echo "  1. ./SECURE_UFW_HETZNER.sh (règles UFW complètes)"
    echo "  2. ./volumes_manager.sh (montage volumes)"
    echo "  3. Installation modules (MinIO, PostgreSQL, etc.)"
    exit 0
else
    warn "$FAILED serveurs en échec"
    echo ""
    echo "Logs: $MAIN_LOG"
    exit 1
fi
