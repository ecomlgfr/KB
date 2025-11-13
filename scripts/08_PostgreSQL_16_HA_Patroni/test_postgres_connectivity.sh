#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         TEST_POSTGRES_CONNECTIVITY - Test Connexions DB            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)

# Charger les credentials
if [ -f /opt/keybuzz-installer/credentials/secrets.json ]; then
    POSTGRES_PASSWORD=$(jq -r '.postgres.password' /opt/keybuzz-installer/credentials/secrets.json)
else
    source /opt/keybuzz-installer/credentials/postgres.env
fi

echo ""
echo "Test de connectivité PostgreSQL..."
echo ""

# Installer psql sur install-01 si nécessaire
if ! command -v psql &>/dev/null; then
    echo "Installation client PostgreSQL sur install-01..."
    apt-get update -qq && apt-get install -y postgresql-client -qq
fi

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo "1. Test port 5432 (netcat):"
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node ($ip): "
    
    if timeout 2 nc -zv "$ip" 5432 &>/dev/null; then
        echo -e "$OK Port ouvert"
    else
        echo -e "$KO Port fermé"
    fi
done

echo ""
echo "2. Test connexion psql depuis install-01:"
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node: "
    
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$ip" -U postgres -d postgres -c "SELECT 1;" &>/dev/null; then
        echo -e "$OK Connexion réussie"
    else
        # Essayer avec l'ancien mot de passe
        if PGPASSWORD="KeyBuzz2024Secure!" psql -h "$ip" -U postgres -d postgres -c "SELECT 1;" &>/dev/null; then
            echo -e "$OK Connexion réussie (ancien mdp)"
        else
            echo -e "$KO Connexion échouée"
        fi
    fi
done

echo ""
echo "3. Test connexion depuis les containers:"
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node (interne): "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" \
        "docker exec patroni psql -U postgres -d postgres -c 'SELECT version();'" &>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "$OK PostgreSQL accessible"
    else
        echo -e "$KO PostgreSQL inaccessible"
    fi
done
