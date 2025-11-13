#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      06_KEEPALIVED_VIP - Keepalived VIP 10.0.0.10 (LB Hetzner)     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_FILE="/opt/keybuzz-installer/logs/keepalived_$(date +%Y%m%d_%H%M%S).log"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"

VIP="10.0.0.10"
PROXY_NODES=(haproxy-01 haproxy-02)

echo "" | tee -a "$LOG_FILE"
echo "═══ Configuration Keepalived pour VIP $VIP ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo -e "$WARN Note: La VIP $VIP est gérée par le Load Balancer Hetzner" | tee -a "$LOG_FILE"
echo "  Keepalived assure le failover automatique entre haproxy-01 et haproxy-02" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Récupérer les IPs
HAPROXY01_IP=$(awk -F'\t' '$2=="haproxy-01" {print $3}' "$SERVERS_TSV")
HAPROXY02_IP=$(awk -F'\t' '$2=="haproxy-02" {print $3}' "$SERVERS_TSV")

[ -z "$HAPROXY01_IP" ] && { echo -e "$KO haproxy-01 IP introuvable" | tee -a "$LOG_FILE"; exit 1; }
[ -z "$HAPROXY02_IP" ] && { echo -e "$KO haproxy-02 IP introuvable" | tee -a "$LOG_FILE"; exit 1; }

# Fonction pour installer Keepalived
install_keepalived() {
    local node_name="$1"
    local node_ip="$2"
    local priority="$3"
    local state="$4"
    local peer_ip="$5"
    
    echo "→ Configuration $node_name ($node_ip) - Priority: $priority, State: $state" | tee -a "$LOG_FILE"
    
    ssh -o StrictHostKeyChecking=no root@"$node_ip" bash -s "$node_name" "$node_ip" "$peer_ip" "$priority" "$state" "$VIP" <<'KEEPALIVED_INSTALL'
set -u
set -o pipefail

NODE_NAME="$1"
NODE_IP="$2"
PEER_IP="$3"
PRIORITY="$4"
STATE="$5"
VIP="$6"

# Installer Keepalived si absent
if ! command -v keepalived &>/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y keepalived
    echo "    ✓ Keepalived installé"
fi

# Trouver l'interface réseau principale
INTERFACE=$(ip -br a | grep "$NODE_IP" | awk '{print $1}')
[ -z "$INTERFACE" ] && { echo "    ✗ Interface introuvable"; exit 1; }

echo "    Interface: $INTERFACE"

# Configuration Keepalived
cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id $NODE_NAME
    enable_script_security
    script_user root
}

vrrp_script check_haproxy {
    script "/usr/bin/docker ps | grep haproxy"
    interval 3
    timeout 2
    fall 2
    rise 2
}

vrrp_instance VI_DB {
    state $STATE
    interface $INTERFACE
    virtual_router_id 51
    priority $PRIORITY
    advert_int 1
    
    # Mode unicast pour Hetzner (pas de multicast)
    unicast_src_ip $NODE_IP
    unicast_peer {
        $PEER_IP
    }
    
    # Authentification
    authentication {
        auth_type PASS
        auth_pass KeyBuzz2024
    }
    
    # VIP
    virtual_ipaddress {
        $VIP dev $INTERFACE
    }
    
    # Health check
    track_script {
        check_haproxy
    }
    
    # Notifications (optionnel)
    notify_master "/bin/echo 'MASTER' > /var/run/keepalived-state"
    notify_backup "/bin/echo 'BACKUP' > /var/run/keepalived-state"
    notify_fault "/bin/echo 'FAULT' > /var/run/keepalived-state"
}
EOF

# Activer et démarrer Keepalived
systemctl enable keepalived >/dev/null 2>&1
systemctl restart keepalived

sleep 3

if systemctl is-active --quiet keepalived; then
    echo "    ✓ Keepalived actif"
    
    # Vérifier l'état
    if [ -f /var/run/keepalived-state ]; then
        CURRENT_STATE=$(cat /var/run/keepalived-state)
        echo "    État: $CURRENT_STATE"
    fi
else
    echo "    ✗ Keepalived échec démarrage"
    journalctl -u keepalived --no-pager -n 20
    exit 1
fi
KEEPALIVED_INSTALL
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Configuration terminée" | tee -a "$LOG_FILE"
    else
        echo -e "  $KO Échec configuration" | tee -a "$LOG_FILE"
        return 1
    fi
}

# Installer sur haproxy-01 (MASTER, priority 150)
install_keepalived "haproxy-01" "$HAPROXY01_IP" "150" "MASTER" "$HAPROXY02_IP"

echo "" | tee -a "$LOG_FILE"

# Installer sur haproxy-02 (BACKUP, priority 100)
install_keepalived "haproxy-02" "$HAPROXY02_IP" "100" "BACKUP" "$HAPROXY01_IP"

echo "" | tee -a "$LOG_FILE"
echo "═══ Vérification de la VIP ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

sleep 5

# Vérifier qui possède la VIP
VIP_OWNER=""
for ip in "$HAPROXY01_IP" "$HAPROXY02_IP"; do
    echo -n "  Vérification sur $ip: " | tee -a "$LOG_FILE"
    if ssh -o StrictHostKeyChecking=no root@"$ip" "ip addr show | grep -q '$VIP'" 2>/dev/null; then
        echo -e "$OK VIP active" | tee -a "$LOG_FILE"
        VIP_OWNER="$ip"
    else
        echo "Backup" | tee -a "$LOG_FILE"
    fi
done

echo "" | tee -a "$LOG_FILE"

if [ -n "$VIP_OWNER" ]; then
    echo -e "$OK VIP $VIP active sur $VIP_OWNER" | tee -a "$LOG_FILE"
else
    echo -e "$WARN VIP non détectée (normal si gérée uniquement par LB Hetzner)" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo "═══ Test de connectivité via VIP ═══" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    source /opt/keybuzz-installer/credentials/postgres.env
    
    echo -n "Test connexion PostgreSQL via VIP ($VIP:5432): " | tee -a "$LOG_FILE"
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$VIP" -p 5432 -U postgres -d postgres -c "SELECT 1" -t 2>/dev/null | grep -q "1"; then
        echo -e "$OK" | tee -a "$LOG_FILE"
    else
        echo -e "$WARN Échec (vérifier la configuration du LB Hetzner)" | tee -a "$LOG_FILE"
    fi
else
    echo -e "$WARN postgres.env introuvable - impossible de tester la connexion" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo -e "$OK KEEPALIVED CONFIGURÉ" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Architecture de failover:" | tee -a "$LOG_FILE"
echo "  • haproxy-01 ($HAPROXY01_IP): MASTER (priority 150)" | tee -a "$LOG_FILE"
echo "  • haproxy-02 ($HAPROXY02_IP): BACKUP (priority 100)" | tee -a "$LOG_FILE"
echo "  • VIP: $VIP (gérée par LB Hetzner)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Commandes utiles:" | tee -a "$LOG_FILE"
echo "  # Voir l'état Keepalived" | tee -a "$LOG_FILE"
echo "  ssh root@$HAPROXY01_IP 'systemctl status keepalived'" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Voir les logs" | tee -a "$LOG_FILE"
echo "  ssh root@$HAPROXY01_IP 'journalctl -u keepalived -f'" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "  # Forcer un basculement (test)" | tee -a "$LOG_FILE"
echo "  ssh root@$HAPROXY01_IP 'systemctl stop haproxy'" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Prochaine étape: ./07_pgbouncer_scram.sh" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"

tail -n 50 "$LOG_FILE"
