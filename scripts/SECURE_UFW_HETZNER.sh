#!/usr/bin/env bash
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓${NC} $*"; }
ko() { echo -e "${RED}✗${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

cat <<'EOF'
╔════════════════════════════════════════════════════════════════════╗
║         SÉCURISATION UFW - RÉSEAU HETZNER NATIF                    ║
╚════════════════════════════════════════════════════════════════════╝
EOF

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_FILE="/opt/keybuzz-installer/logs/ufw_setup_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

[[ ! -f "$SERVERS_TSV" ]] && { ko "servers.tsv introuvable"; exit 1; }

echo ""
warn "Ce script va sécuriser TOUS les serveurs avec UFW"
warn "Règles: deny in / allow out / allow 10.0.0.0/16"
echo ""
read -p "Continuer? (y/N) " -r
[[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Annulé"; exit 0; }

echo ""
ok "Démarrage sécurisation..."
echo ""

declare -a SERVERS
while IFS=$'\t' read -r ip_pub hostname ip_priv rest; do
    [[ "$ip_pub" =~ ^# || "$ip_pub" == "IP_PUBLIQUE" ]] && continue
    SERVERS+=("$hostname|$ip_priv")
done < "$SERVERS_TSV"

TOTAL=${#SERVERS[@]}
ok "$TOTAL serveurs à configurer"
echo ""

OK_COUNT=0
KO_COUNT=0

for entry in "${SERVERS[@]}"; do
    IFS='|' read -r hostname ip <<< "$entry"
    
    echo -n "→ $hostname ($ip): "
    
    if ! timeout 3 ssh -o BatchMode=yes -o ConnectTimeout=2 root@"$ip" "echo 1" &>/dev/null; then
        ko "SSH KO"
        ((KO_COUNT++))
        continue
    fi
    
    ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$ip" "bash -s" <<'REMOTE_UFW'
set -uo pipefail

# Installer UFW si absent
if ! command -v ufw >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y ufw >/dev/null 2>&1
fi

# Reset UFW proprement
ufw --force reset >/dev/null 2>&1

# Règles de base
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1

# Autoriser réseau privé Hetzner complet
ufw allow from 10.0.0.0/16 comment "Hetzner private network" >/dev/null 2>&1

# Autoriser SSH depuis partout (sécurité: clés uniquement)
ufw allow 22/tcp comment "SSH" >/dev/null 2>&1

# Activer sans prompt
ufw --force enable >/dev/null 2>&1

# Vérifier
if ufw status | grep -q "Status: active"; then
    echo "OK"
    exit 0
else
    echo "KO"
    exit 1
fi
REMOTE_UFW
    
    if [[ $? -eq 0 ]]; then
        ok "OK"
        ((OK_COUNT++))
    else
        ko "échec"
        ((KO_COUNT++))
    fi
done

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ:"
echo "  OK: $OK_COUNT | KO: $KO_COUNT"
echo "══════════════════════════════════════════════════════════════════"

if [[ $KO_COUNT -eq 0 ]]; then
    ok "SÉCURISATION COMPLÈTE"
    echo ""
    echo "RÈGLES APPLIQUÉES SUR TOUS LES SERVEURS:"
    echo "  • deny incoming (défaut)"
    echo "  • allow outgoing (défaut)"
    echo "  • allow from 10.0.0.0/16 (réseau privé)"
    echo "  • allow 22/tcp (SSH)"
    echo ""
    ok "Vos pools restent isolés (gestion au niveau Hetzner/SSH)"
    exit 0
else
    warn "$KO_COUNT échecs - voir log: $LOG_FILE"
    exit 1
fi
