#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                 01_SETUP_UFW_DB - Configuration Firewall           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)

echo ""
echo "═══ Configuration UFW sur nœuds DB ═══"
echo ""

for node in "${DB_NODES[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "$KO $node IP introuvable"; continue; }
    
    echo "→ $node ($IP_PRIV)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP_PRIV" bash <<'EOS'
set -u

# Reset UFW
ufw --force reset

# Règles par défaut
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment 'SSH'

# Réseau Hetzner privé complet
ufw allow from 10.0.0.0/16 comment 'Hetzner Private Network'

# PostgreSQL
ufw allow from 10.0.0.0/16 to any port 5432 proto tcp comment 'PostgreSQL'

# Patroni API
ufw allow from 10.0.0.0/16 to any port 8008 proto tcp comment 'Patroni REST'

# etcd client
ufw allow from 10.0.0.0/16 to any port 2379 proto tcp comment 'etcd client'

# Activer
ufw --force enable

echo "✓ UFW configuré"
EOS
    
    [ $? -eq 0 ] && echo -e "  $OK" || echo -e "  $KO"
done

echo ""
echo -e "$OK Configuration UFW terminée"
