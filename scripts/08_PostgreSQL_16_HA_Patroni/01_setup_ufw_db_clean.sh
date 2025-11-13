#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          01_SETUP_UFW_DB_CLEAN - UFW sans etcd                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)

echo ""
echo "Configuration UFW pour Patroni RAFT (sans etcd)..."
echo ""

for node in "${DB_NODES[@]}"; do
    IP_PRIV=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP_PRIV" ] && { echo -e "$KO $node IP introuvable"; continue; }
    
    echo "  $node ($IP_PRIV):"
    
    ssh root@"$IP_PRIV" bash <<'UFW_CLEAN'
# Reset UFW proprement
ufw --force reset

# Règles par défaut
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment 'SSH'

# PostgreSQL
ufw allow from 10.0.0.0/16 to any port 5432 proto tcp comment 'PostgreSQL'

# Patroni API
ufw allow from 10.0.0.0/16 to any port 8008 proto tcp comment 'Patroni REST API'

# Patroni RAFT
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni RAFT'

# PAS d'etcd (on retire 2379/2380)

# Activer
ufw --force enable

echo "    ✓ UFW configuré (sans etcd)"
UFW_CLEAN
done

echo ""
echo -e "$OK Configuration UFW terminée (ports: 22, 5432, 8008, 7000)"

### KeyBuzz UFW additions (LAN + docker bridge) ###
ufw allow in on lo
ufw allow 22/tcp

# Postgres RW/RO depuis LAN + pont docker
ufw allow from 10.0.0.0/16 to any port 5432 proto tcp
ufw allow from 10.0.0.0/16 to any port 5433 proto tcp
ufw allow from 172.16.0.0/12 to any port 5432 proto tcp
ufw allow from 172.16.0.0/12 to any port 5433 proto tcp

# Patroni REST pour health HAProxy
ufw allow from 10.0.0.0/16 to any port 8008 proto tcp
ufw allow from 172.16.0.0/12 to any port 8008 proto tcp

# RAFT entre nœuds DB
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp
### /KeyBuzz UFW ###
