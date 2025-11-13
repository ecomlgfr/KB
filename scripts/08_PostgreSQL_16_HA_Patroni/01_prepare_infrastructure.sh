#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   01_PREPARE_INFRASTRUCTURE - Préparation de l'infrastructure      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Configuration globale
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/01_prepare_infra_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"

# Vérifications préalables
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

echo ""
echo "1. Vérification de la connectivité..."
echo ""

# Liste des serveurs DB
DB_SERVERS=("10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")

CONNECTIVITY_OK=true
for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  $hostname ($ip): "
    
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ip" "echo ok" &>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
        CONNECTIVITY_OK=false
    fi
done

if [ "$CONNECTIVITY_OK" = false ]; then
    echo -e "\n$KO Problème de connectivité. Vérifiez les serveurs."
    exit 1
fi

echo ""
echo "2. Nettoyage des installations précédentes..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Nettoyage $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEANUP' 2>/dev/null
# Arrêt des services
systemctl stop postgresql 2>/dev/null
docker stop postgres patroni etcd 2>/dev/null
docker rm -f postgres patroni etcd 2>/dev/null

# Nettoyage des données
rm -rf /opt/keybuzz/postgres/data/* 2>/dev/null
rm -rf /opt/keybuzz/postgres/raft/* 2>/dev/null
rm -rf /var/lib/postgresql/* 2>/dev/null

# Kill des processus zombies
pkill -9 postgres 2>/dev/null
pkill -9 patroni 2>/dev/null
CLEANUP
    
    echo -e "$OK"
done

echo ""
echo "3. Configuration du firewall (UFW)..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  Configuration $hostname:"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'FIREWALL' 2>/dev/null
# Ports PostgreSQL
ufw allow from 10.0.0.0/16 to any port 5432 proto tcp comment 'PostgreSQL' 2>/dev/null
ufw allow from 10.0.0.0/16 to any port 6432 proto tcp comment 'PgBouncer' 2>/dev/null

# Ports Patroni
ufw allow from 10.0.0.0/16 to any port 8008 proto tcp comment 'Patroni API' 2>/dev/null
ufw allow from 10.0.0.0/16 to any port 7000 proto tcp comment 'Patroni Raft' 2>/dev/null

# SSH sécurisé
ufw allow from 10.0.0.0/16 to any port 22 proto tcp comment 'SSH internal' 2>/dev/null

ufw --force enable >/dev/null 2>&1
echo "    Règles appliquées"
FIREWALL
done

echo ""
echo "4. Préparation de la structure des répertoires..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Structure $hostname: "
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STRUCTURE' 2>/dev/null
# Créer la structure complète
mkdir -p /opt/keybuzz/postgres/{data,raft,archive,wal,backups}
mkdir -p /opt/keybuzz/patroni/{config,logs}
mkdir -p /opt/keybuzz/pgbouncer/{config,logs}
mkdir -p /opt/keybuzz/haproxy/{config,logs}
mkdir -p /opt/keybuzz-installer/{logs,credentials}

# Permissions PostgreSQL (UID 999)
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft
chmod 755 /opt/keybuzz/postgres/archive
chmod 755 /opt/keybuzz/postgres/wal

# Permissions pour les logs
chmod 755 /opt/keybuzz/*/logs
STRUCTURE
    
    echo -e "$OK"
done

echo ""
echo "5. Vérification des volumes Hetzner..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo "  $hostname:"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'VOLUMES'
# Chercher un volume disponible
DEVICE=""
for dev in /dev/sd[b-z] /dev/vd[b-z]; do
    if [ -b "$dev" ] && ! mount | grep -q "$dev"; then
        DEVICE="$dev"
        SIZE=$(lsblk -b -n -o SIZE "$dev" 2>/dev/null | awk '{print int($1/1073741824)}')
        echo "    Volume trouvé: $dev ($SIZE GB)"
        break
    fi
done

if [ -z "$DEVICE" ]; then
    echo "    Pas de volume externe (utilisation disque local)"
fi
VOLUMES
done

echo ""
echo "6. Installation des prérequis Docker..."
echo ""

for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    echo -n "  Docker sur $hostname: "
    
    if ssh -o StrictHostKeyChecking=no root@"$ip" "docker --version" &>/dev/null; then
        echo -e "$OK (déjà installé)"
    else
        echo "Installation..."
        ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'DOCKER' >/dev/null 2>&1
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker
DOCKER
        echo -e "    $OK"
    fi
done

echo ""
echo "7. Génération des credentials..."
echo ""

CREDS_DIR="/opt/keybuzz-installer/credentials"
mkdir -p "$CREDS_DIR"

# Générer les mots de passe s'ils n'existent pas
if [ ! -f "$CREDS_DIR/postgres.env" ]; then
    POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    REPLICATOR_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    PATRONI_API_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    
    cat > "$CREDS_DIR/postgres.env" <<EOF
#!/bin/bash
# PostgreSQL Credentials
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD"
export PATRONI_API_PASSWORD="$PATRONI_API_PASSWORD"
export PGBOUNCER_PASSWORD="$POSTGRES_PASSWORD"

# Connection strings
export MASTER_DSN="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.120:5432/postgres"
export REPLICA_DSN="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.121:5432/postgres"
export VIP_DSN="postgresql://postgres:$POSTGRES_PASSWORD@10.0.0.10:5432/postgres"
EOF
    chmod 600 "$CREDS_DIR/postgres.env"
    echo -e "  $OK Credentials générés"
else
    echo -e "  $OK Credentials existants"
fi

# Copier les credentials sur tous les serveurs
for server in "${DB_SERVERS[@]}"; do
    IFS=':' read -r ip hostname <<< "$server"
    scp -o StrictHostKeyChecking=no "$CREDS_DIR/postgres.env" root@"$ip":/opt/keybuzz-installer/credentials/ 2>/dev/null
done

echo ""
echo "8. Résumé de la préparation..."
echo ""

cat > "$CREDS_DIR/infrastructure-status.txt" <<EOF
Infrastructure PostgreSQL HA - État de préparation
Date: $(date)

Serveurs:
- db-master-01 (10.0.0.120) : PostgreSQL Master
- db-slave-01 (10.0.0.121) : PostgreSQL Replica
- db-slave-02 (10.0.0.122) : PostgreSQL Replica

Ports configurés:
- 5432 : PostgreSQL
- 6432 : PgBouncer
- 8008 : Patroni REST API
- 7000 : Patroni Raft DCS

Structure créée:
- /opt/keybuzz/postgres : Données PostgreSQL
- /opt/keybuzz/patroni : Configuration Patroni
- /opt/keybuzz/pgbouncer : Configuration PgBouncer
- /opt/keybuzz/haproxy : Configuration HAProxy

Credentials:
- Fichier: $CREDS_DIR/postgres.env
- À sourcer avant utilisation
EOF

echo -e "$OK Infrastructure préparée avec succès"
echo ""
echo "Logs: $MAIN_LOG"
echo "Credentials: $CREDS_DIR/postgres.env"
echo ""
echo "Prochaine étape: ./02_install_patroni_raft.sh"
echo ""
