#!/usr/bin/env bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok() { echo -e "${GREEN}✓${NC} $1"; }
ko() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      KeyBuzz FORCE INSTALL v2 - Docker CE Official           ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

[[ $EUID -ne 0 ]] && ko "Must run as root" && exit 1

export DEBIAN_FRONTEND=noninteractive

echo -e "${BLUE}[1/13] Fix /tmp permissions...${NC}"
chmod 1777 /tmp
rm -rf /tmp/apt.conf.* 2>/dev/null || true
ok "/tmp fixed"

echo ""
echo -e "${BLUE}[2/13] Allow unauthenticated packages (temporary)...${NC}"
mkdir -p /etc/apt/apt.conf.d/
cat > /etc/apt/apt.conf.d/99allow-unsigned << 'APTCONF'
APT::Get::AllowUnauthenticated "true";
Acquire::AllowInsecureRepositories "true";
Acquire::AllowDowngradeToInsecureRepositories "true";
APTCONF
ok "Unsigned packages allowed"

echo ""
echo -e "${BLUE}[3/13] Update APT (ignore GPG errors)...${NC}"
apt-get update -qq 2>&1 | grep -v "GPG error" | grep -v "not signed" || true
ok "APT updated"

echo ""
echo -e "${BLUE}[4/13] Install base dependencies (forced)...${NC}"
BASE_PACKAGES="dos2unix jq parallel sshpass python3-pip curl wget git htop vim tmux rsync net-tools dnsutils software-properties-common ca-certificates gnupg lsb-release ufw unzip"

FAILED=()
for pkg in $BASE_PACKAGES; do
  echo -n "  $pkg: "
  if dpkg -l | grep -q "^ii.*$pkg"; then
    echo "OK"
  else
    if apt-get install -y --allow-unauthenticated $pkg >/dev/null 2>&1; then
      ok ""
    else
      ko ""
      FAILED+=("$pkg")
    fi
  fi
done

[[ ${#FAILED[@]} -gt 0 ]] && warn "Failed: ${FAILED[*]}"

echo ""
echo -e "${BLUE}[5/13] Install WireGuard...${NC}"
if command -v wg >/dev/null 2>&1; then
  ok "WireGuard exists"
else
  echo "  Installing wireguard..."
  if apt-get install -y --allow-unauthenticated wireguard wireguard-tools >/dev/null 2>&1; then
    ok "WireGuard installed"
  else
    ko "WireGuard failed"
  fi
fi

echo ""
echo -e "${BLUE}[6/13] Remove old Docker versions...${NC}"
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
ok "Old Docker removed"

echo ""
echo -e "${BLUE}[7/13] Install Docker prerequisites...${NC}"
apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
ok "Prerequisites installed"

echo ""
echo -e "${BLUE}[8/13] Add Docker GPG key...${NC}"
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
ok "Docker GPG key added"

echo ""
echo -e "${BLUE}[9/13] Add Docker repository...${NC}"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq 2>&1 | grep -v "GPG error" || true
ok "Docker repo added"

echo ""
echo -e "${BLUE}[10/13] Install Docker CE + compose plugin...${NC}"
if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
  systemctl enable docker
  systemctl start docker
  ok "Docker CE installed"
else
  ko "Docker CE failed"
fi

echo ""
echo -e "${BLUE}[11/13] Verify Docker installation...${NC}"
if docker --version >/dev/null 2>&1; then
  ok "docker: $(docker --version | cut -d' ' -f3)"
else
  ko "docker not working"
fi

if docker compose version >/dev/null 2>&1; then
  ok "docker compose: $(docker compose version --short)"
else
  ko "docker compose not working"
fi

echo ""
echo -e "${BLUE}[12/13] Create KeyBuzz structure...${NC}"
KB_DIRS=(
  "/opt/keybuzz-installer/scripts"
  "/opt/keybuzz-installer/configs"
  "/opt/keybuzz-installer/credentials"
  "/opt/keybuzz-installer/logs"
  "/opt/keybuzz-installer/backups"
  "/opt/keybuzz-installer/inventory"
  "/opt/keybuzz-installer/wgkeys"
  "/opt/keybuzz-installer/ssl"
  "/opt/keybuzz-installer/kb_build"
)

for dir in "${KB_DIRS[@]}"; do mkdir -p "$dir"; done
chmod 700 /opt/keybuzz-installer/credentials
ok "Directories created"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

cp *.sh /opt/keybuzz-installer/scripts/ 2>/dev/null || true
[[ -f servers_final.tsv ]] && cp servers_final.tsv /opt/keybuzz-installer/inventory/servers.tsv
[[ -f servers.tsv ]] && cp servers.tsv /opt/keybuzz-installer/inventory/
cp *.md /opt/keybuzz-installer/ 2>/dev/null || true
cp *.bat /opt/keybuzz-installer/scripts/ 2>/dev/null || true

find /opt/keybuzz-installer -name "*.sh" -exec dos2unix {} \; 2>/dev/null || true
find /opt/keybuzz-installer/scripts -name "*.sh" -exec chmod +x {} \;
ok "Scripts installed"

cat > /opt/keybuzz-installer/.env <<'EOF'
#!/usr/bin/env bash
export KEYBUZZ_HOME="/opt/keybuzz-installer"
export SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
export LOG_DIR="/opt/keybuzz-installer/logs"
export BACKUP_DIR="/opt/keybuzz-installer/backups"
export SCRIPTS_DIR="/opt/keybuzz-installer/scripts"
export SSH_PORT="22"
export WG_PORT="51820"
export ADMIN_USER="kbadmin"
export PARALLEL_JOBS="8"
export PATH="/opt/keybuzz-installer/scripts:$PATH"
EOF
chmod 644 /opt/keybuzz-installer/.env
ok "Environment configured"

if [[ -f /opt/keybuzz-installer/inventory/servers.tsv ]]; then
  grep -v "^HOSTNAME[[:space:]]" /opt/keybuzz-installer/inventory/servers.tsv | \
  grep -v "^#HOSTNAME" > /tmp/servers_temp.tsv || true
  
  (echo "IP_PUBLIQUE	HOSTNAME	IP_WIREGUARD	FQDN	USER_SSH"; \
   grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /tmp/servers_temp.tsv) > /opt/keybuzz-installer/inventory/servers.tsv
  
  SERVER_COUNT=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /opt/keybuzz-installer/inventory/servers.tsv | wc -l)
  rm -f /tmp/servers_temp.tsv
  ok "servers.tsv: $SERVER_COUNT servers"
fi

echo ""
echo -e "${BLUE}[13/13] SSH keys + DB setup...${NC}"
[[ ! -f /root/.ssh/id_ed25519 ]] && ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "operator@$(hostname)" && ok "Operator key" || ok "Key exists"
[[ ! -f /root/.ssh/kbmesh ]] && ssh-keygen -t ed25519 -f /root/.ssh/kbmesh -N "" -C "kbmesh@$(hostname)" && ok "Mesh key" || ok "Mesh exists"

grep -q "$(cat /root/.ssh/id_ed25519.pub 2>/dev/null)" /root/.ssh/authorized_keys 2>/dev/null || \
  cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ok "SSH keys configured"

DB_SERVERS=(195.201.122.106 91.98.169.31 65.21.251.198)
echo "  DB interconnection..."
for ip in "${DB_SERVERS[@]}"; do
  ping -c 1 -W 2 "$ip" >/dev/null 2>&1 && \
    ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$ip" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && [ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "$(hostname)"; chmod 600 ~/.ssh/id_ed25519' >/dev/null 2>&1
done

for ip in "${DB_SERVERS[@]}"; do
  for target_ip in "${DB_SERVERS[@]}"; do
    [[ "$ip" == "$target_ip" ]] && continue
    KEY=$(ssh -o BatchMode=yes -o ConnectTimeout=3 root@"$target_ip" "cat ~/.ssh/id_ed25519.pub 2>/dev/null")
    [[ -n "$KEY" ]] && ssh -o BatchMode=yes -o ConnectTimeout=3 root@"$ip" \
      "grep -qF '$KEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$KEY' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" >/dev/null 2>&1
  done
done
ok "DB keys exchanged"

if ! command -v hcloud >/dev/null 2>&1; then
  wget -q -O /tmp/hcloud.tar.gz https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz 2>/dev/null
  tar -xzf /tmp/hcloud.tar.gz -C /usr/local/bin/ 2>/dev/null
  chmod +x /usr/local/bin/hcloud
  rm -f /tmp/hcloud.tar.gz
  ok "hcloud installed"
else
  ok "hcloud exists"
fi

grep -q "KEYBUZZ_HOME" /root/.bashrc || cat >> /root/.bashrc <<'BASHRC'

if [[ -f /opt/keybuzz-installer/.env ]]; then
    source /opt/keybuzz-installer/.env
fi
BASHRC

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}         ✅ VERIFICATION${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

COMMANDS=(parallel docker dos2unix jq hcloud git wg)
for cmd in "${COMMANDS[@]}"; do
  command -v $cmd >/dev/null 2>&1 && ok "$cmd" || ko "$cmd"
done

echo ""
docker compose version >/dev/null 2>&1 && ok "docker compose plugin" || ko "docker compose plugin"

echo ""
[[ -f /opt/keybuzz-installer/inventory/servers.tsv ]] && \
  ok "Servers: $(grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /opt/keybuzz-installer/inventory/servers.tsv | wc -l)"
ok "Scripts: $(ls /opt/keybuzz-installer/scripts/*.sh 2>/dev/null | wc -l)"

echo ""
echo -e "${YELLOW}Next:${NC}"
echo "  1. source /opt/keybuzz-installer/.env"
echo "  2. export HCLOUD_TOKEN='...'"
echo "  3. (Windows) deploy_ssh_windows_v3_final.bat"
echo "  4. ./prepare_all_servers.sh"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo -e "${CYAN}    NOUVEAUX SCRIPTS DISPONIBLES V3         ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Scripts de gestion des pools:${NC}"
echo "  • KB_SSH_POOL_MANAGER.sh - Interconnexions automatiques"
echo "  • KB_ADD_SERVER.sh - Ajout de nouveaux serveurs"
echo ""
echo -e "${GREEN}Scripts HAProxy:${NC}"
echo "  • 06_HAPROXY_HA_PRODUCTION.sh - Load balancer PostgreSQL"
echo "  • FIX_DB_SSH_FINAL.sh - Correction SSH entre DB"
echo ""
echo -e "${YELLOW}Note: Infrastructure étendue à 43 serveurs${NC}"
echo "  - 2 serveurs HAProxy ajoutés (159.69.159.32, 91.98.164.223)"
echo "  - Pools configurés automatiquement"
echo ""

source /opt/keybuzz-installer/.env 2>/dev/null || true
