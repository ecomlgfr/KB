#!/bin/bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

INVENTORY="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/prepare_all_$TIMESTAMP.log"
PARALLEL_JOBS=10

mkdir -p "$LOG_DIR"

clear

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$MAIN_LOG"
}

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════════╗${NC}" | tee -a "$MAIN_LOG"
echo -e "${BLUE}║           ${BOLD}Préparation Complete Infrastructure Keybuzz${NC}${BLUE}                            ║${NC}" | tee -a "$MAIN_LOG"
echo -e "${BLUE}║                 Docker CE + WireGuard + docker-compose-plugin                     ║${NC}" | tee -a "$MAIN_LOG"
echo -e "${BLUE}║                         Réseau: 10.0.0.0/16                                       ║${NC}" | tee -a "$MAIN_LOG"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════════╝${NC}" | tee -a "$MAIN_LOG"
echo "" | tee -a "$MAIN_LOG"

if ! command -v parallel &>/dev/null; then
    log "${YELLOW}Installation de GNU Parallel...${NC}"
    apt-get update -qq && apt-get install -y -qq parallel
fi

if [ ! -f "$INVENTORY" ]; then
    log "${YELLOW}Création du fichier d'inventaire...${NC}"
    mkdir -p "$(dirname "$INVENTORY")"
    
    cat > "$INVENTORY" << 'EOF'
IP_PUBLIQUE	HOSTNAME	IP_WIREGUARD	FQDN	USER_SSH	POOL
91.98.124.228	k3s-master-01	10.0.0.100	master1.keybuzz.io	root	k3s-masters
91.98.117.26	k3s-master-02	10.0.0.101	master2.keybuzz.io	root	k3s-masters
91.98.165.238	k3s-master-03	10.0.0.102	master3.keybuzz.io	root	k3s-masters
116.203.135.192	k3s-worker-01	10.0.0.110	worker1.keybuzz.io	root	k3s-workers
91.99.164.62	k3s-worker-02	10.0.0.111	worker2.keybuzz.io	root	k3s-workers
157.90.119.183	k3s-worker-03	10.0.0.112	worker3.keybuzz.io	root	k3s-workers
91.98.200.38	k3s-worker-04	10.0.0.113	worker4.keybuzz.io	root	k3s-workers
188.245.45.242	k3s-worker-05	10.0.0.114	worker5.keybuzz.io	root	k3s-workers
195.201.122.106	db-master-01	10.0.0.120	db-master.keybuzz.io	root	db-pool
91.98.169.31	db-slave-01	10.0.0.121	db-slave1.keybuzz.io	root	db-pool
65.21.251.198	db-slave-02	10.0.0.122	db-slave2.keybuzz.io	root	db-pool
49.12.231.193	redis-01	10.0.0.123	redis1.keybuzz.io	root	redis-pool
23.88.48.163	redis-02	10.0.0.124	redis2.keybuzz.io	root	redis-pool
91.98.167.166	redis-03	10.0.0.125	redis3.keybuzz.io	root	redis-pool
23.88.105.16	queue-01	10.0.0.126	queue1.keybuzz.io	root	queue-pool
91.98.167.159	queue-02	10.0.0.127	queue2.keybuzz.io	root	queue-pool
91.98.68.35	queue-03	10.0.0.128	queue3.keybuzz.io	root	queue-pool
88.99.227.128	temporal-db-01	10.0.0.129	temporal-db.keybuzz.io	root	temporal
91.98.134.176	analytics-db-01	10.0.0.130	analytics-db.keybuzz.io	root	analytics
91.99.199.183	python-api-01	10.0.0.131	api1.keybuzz.io	root	api-pool
91.99.103.47	python-api-02	10.0.0.132	api2.keybuzz.io	root	api-pool
78.47.43.10	billing-01	10.0.0.133	billing.keybuzz.io	root	billing
116.203.144.185	minio-01	10.0.0.134	s3.keybuzz.io	root	storage
23.88.107.251	api-gateway-01	10.0.0.135	gateway.keybuzz.io	root	gateway
116.203.240.119	vector-db-01	10.0.0.136	qdrant.keybuzz.io	root	vector
91.98.200.40	litellm-01	10.0.0.137	llm.keybuzz.io	root	ai
91.98.197.70	temporal-01	10.0.0.138	temporal.keybuzz.io	root	temporal
91.99.237.167	analytics-01	10.0.0.139	analytics.keybuzz.io	root	analytics
195.201.225.134	etl-01	10.0.0.140	etl.keybuzz.io	root	etl
91.99.195.137	baserow-01	10.0.0.144	baserow.keybuzz.io	root	apps
78.46.170.170	nocodb-01	10.0.0.142	nocodb.keybuzz.io	root	apps
157.90.236.10	ml-platform-01	10.0.0.143	ml.keybuzz.io	root	ai
116.203.61.22	vault-01	10.0.0.150	vault.keybuzz.io	root	security
91.99.58.179	siem-01	10.0.0.151	siem.keybuzz.io	root	security
23.88.105.216	monitor-01	10.0.0.152	monitor.keybuzz.io	root	monitoring
91.98.139.56	backup-01	10.0.0.153	backup.keybuzz.io	root	backup
37.27.251.162	mail-core-01	10.0.0.160	mail.keybuzz.io	root	mail-pool
91.99.66.6	mail-mx-01	10.0.0.161	mx1.keybuzz.io	root	mail-pool
91.99.87.76	mail-mx-02	10.0.0.162	mx2.keybuzz.io	root	mail-pool
5.75.128.134	dev-aio-01	10.0.0.200	dev.keybuzz.io	root	dev
91.98.128.153	install-01	10.0.0.20	install-01.keybuzz.io	root	management
159.69.159.32	haproxy-01	10.0.0.11	haproxy1.keybuzz.io	root	haproxy-pool
91.98.164.223	haproxy-02	10.0.0.12	haproxy2.keybuzz.io	root	haproxy-pool
EOF
fi

TOTAL=$(tail -n +2 "$INVENTORY" | grep -c -E "^[0-9]" || echo "0")

log "📋 Inventaire     : $INVENTORY"
log "📊 Serveurs       : $TOTAL"
log "⚡ Jobs parallèles: $PARALLEL_JOBS"
log "🌐 Réseau WG      : 10.0.0.0/16"
log ""

install_server_complete() {
    local ip="$1"
    local hostname="$2"
    local log_file="$LOG_DIR/${hostname}_$TIMESTAMP.log"
    
    echo "[$hostname] Début installation sur $ip" >> "$log_file"
    echo -e "${YELLOW}⟳${NC} $hostname ($ip) - Installation..."
    
    if ! timeout 5 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes root@"$ip" "echo 'SSH OK'" &>> "$log_file"; then
        echo -e "${RED}✗${NC} $hostname ($ip) - SSH inaccessible"
        echo "[$hostname] ERREUR SSH" >> "$log_file"
        return 1
    fi
    
    if ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@"$ip" "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        
        echo '=== Mise à jour système ==='
        apt-get update -qq
        
        echo '=== Installation WireGuard ==='
        apt-get install -y -qq wireguard wireguard-tools
        
        echo '=== Installation Docker CE ==='
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        
        apt-get install -y -qq ca-certificates curl gnupg lsb-release
        
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" > /etc/apt/sources.list.d/docker.list
        
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        systemctl enable docker
        systemctl start docker
        
        echo '=== Vérifications ==='
        docker --version
        docker compose version
        wg --version
        
        echo '=== OK ==='
    " &>> "$log_file"; then
        echo -e "${GREEN}✓${NC} $hostname ($ip) - OK"
        echo "[$hostname] Installation réussie" >> "$log_file"
        return 0
    else
        echo -e "${RED}✗${NC} $hostname ($ip) - KO"
        echo "[$hostname] ERREUR installation" >> "$log_file"
        return 1
    fi
}

export -f install_server_complete
export LOG_DIR TIMESTAMP
export RED GREEN YELLOW BLUE CYAN NC

echo -e "${BOLD}Installation:${NC}"
echo "  • Docker CE (dernière version)"
echo "  • WireGuard"
echo "  • docker-compose-plugin"
echo ""
echo -e "${YELLOW}Sur $TOTAL serveurs${NC}"
echo ""

if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
    echo -n "Continuer ? (o/N) "
    read -r response
    if [[ ! "$response" =~ ^[Oo]$ ]]; then
        log "Annulé"
        exit 0
    fi
fi

log ""
log "🚀 Démarrage installation..."
log "════════════════════════════════════════════════════════════════════════════"

tail -n +2 "$INVENTORY" | grep -E "^[0-9]" | parallel -j "$PARALLEL_JOBS" --colsep '\t' --joblog "$LOG_DIR/parallel_$TIMESTAMP.log" \
    install_server_complete {1} {2}

log "════════════════════════════════════════════════════════════════════════════"
log ""

SUCCESS=$(grep -c "exitval:0" "$LOG_DIR/parallel_$TIMESTAMP.log" 2>/dev/null || echo "0")
FAILED=$(grep -c "exitval:[^0]" "$LOG_DIR/parallel_$TIMESTAMP.log" 2>/dev/null || echo "0")

log "╔══════════════════════════════════════════════════════════════════════════╗"
log "║                          RÉSUMÉ INSTALLATION                              ║"
log "╚══════════════════════════════════════════════════════════════════════════╝"
log ""
log "📊 Total  : $TOTAL"
log "✅ Réussis: $SUCCESS"
log "❌ Échecs : $FAILED"
log ""

if [ "$FAILED" -gt 0 ]; then
    log "${RED}Serveurs en échec:${NC}"
    grep "exitval:[^0]" "$LOG_DIR/parallel_$TIMESTAMP.log" | while read -r line; do
        server=$(echo "$line" | awk '{print $NF}')
        log "  ✗ $server"
    done
    log ""
    log "Logs: $LOG_DIR"
else
    log "${GREEN}✅ Tous les serveurs configurés !${NC}"
fi

log ""
log "Prochaines étapes:"
log "  ${CYAN}./kb_master_install_fix.sh${NC} (WireGuard mesh)"
log "  ${CYAN}./volumes_manager.sh${NC} (Volumes Hetzner)"
log ""

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
