#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Configuration Backups Automatiques - MinIO                     ║"
echo "║    (PostgreSQL + Redis + K3s Resources + Applications)            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/backups_setup_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Configuration backups automatiques - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0: VÉRIFICATIONS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0: Vérifications préalables                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Récupérer les IPs
IP_MINIO=$(awk -F'\t' '$2=="minio-01" {print $3}' "$SERVERS_TSV")
IP_DB_MASTER=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")
IP_REDIS01=$(awk -F'\t' '$2=="redis-01" {print $3}' "$SERVERS_TSV")
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

[ -z "$IP_MINIO" ] && { echo -e "$KO IP MinIO introuvable"; exit 1; }
[ -z "$IP_DB_MASTER" ] && { echo -e "$KO IP DB Master introuvable"; exit 1; }
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP K3s Master introuvable"; exit 1; }

echo -e "$OK IPs récupérées"
echo "  MinIO       : $IP_MINIO"
echo "  DB Master   : $IP_DB_MASTER"
echo "  Redis-01    : $IP_REDIS01"
echo "  K3s Master  : $IP_MASTER01"
echo ""

# Charger les credentials MinIO
if [ -f "$CREDENTIALS_DIR/secrets.json" ]; then
    MINIO_ACCESS_KEY=$(jq -r '.minio.root_user' "$CREDENTIALS_DIR/secrets.json")
    MINIO_SECRET_KEY=$(jq -r '.minio.root_password' "$CREDENTIALS_DIR/secrets.json")
    echo -e "$OK Credentials MinIO chargés"
else
    echo -e "$KO Credentials MinIO introuvables"
    exit 1
fi

# Charger les credentials PostgreSQL
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
    echo -e "$OK Credentials PostgreSQL chargés"
else
    echo -e "$KO Credentials PostgreSQL introuvables"
    exit 1
fi

echo ""
read -p "Configurer les backups automatiques ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: CONFIGURATION BUCKET MINIO
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Configuration bucket MinIO                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier et créer le bucket de backup
ssh -o StrictHostKeyChecking=no root@"$IP_MINIO" bash <<EOSSH
# Installer mc (MinIO Client) si nécessaire
if ! command -v mc &> /dev/null; then
    curl -o /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc
    chmod +x /usr/local/bin/mc
fi

# Configurer l'alias
mc alias set keybuzz http://localhost:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}

# Créer le bucket s'il n'existe pas
mc mb keybuzz/keybuzz-backups --ignore-existing

# Créer les dossiers
mc mb keybuzz/keybuzz-backups/postgresql --ignore-existing
mc mb keybuzz/keybuzz-backups/redis --ignore-existing
mc mb keybuzz/keybuzz-backups/k3s-resources --ignore-existing
mc mb keybuzz/keybuzz-backups/apps-data --ignore-existing

# Configurer la rétention (30 jours)
mc ilm add keybuzz/keybuzz-backups --expiry-days 30

echo "✓ Bucket et dossiers créés"
EOSSH

echo -e "$OK Bucket MinIO configuré"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: SCRIPT DE BACKUP POSTGRESQL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Script backup PostgreSQL                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_DB_MASTER" bash <<'EOSSH'
cat > /opt/keybuzz/scripts/backup_postgresql.sh <<'PGBACKUP'
#!/usr/bin/env bash
set -u
set -o pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/pg_backup_$TIMESTAMP"
MINIO_BUCKET="keybuzz-backups/postgresql"

mkdir -p "$BACKUP_DIR"

# Backup toutes les bases
DATABASES="postgres n8n chatwoot litellm superset qdrant vault"

for DB in $DATABASES; do
    echo "Backup $DB..."
    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h localhost -U postgres -d "$DB" | gzip > "$BACKUP_DIR/${DB}_${TIMESTAMP}.sql.gz"
done

# Backup globals (roles, tablespaces, etc.)
PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -h localhost -U postgres --globals-only | gzip > "$BACKUP_DIR/globals_${TIMESTAMP}.sql.gz"

# Upload vers MinIO
mc alias set keybuzz http://10.0.0.MINIO_IP:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
mc cp -r "$BACKUP_DIR/" keybuzz/$MINIO_BUCKET/

# Nettoyer
rm -rf "$BACKUP_DIR"

echo "✓ Backup PostgreSQL terminé : $TIMESTAMP"
PGBACKUP

chmod +x /opt/keybuzz/scripts/backup_postgresql.sh
echo "✓ Script PostgreSQL créé"
EOSSH

echo -e "$OK Script backup PostgreSQL créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: SCRIPT DE BACKUP REDIS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Script backup Redis                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_REDIS01" bash <<'EOSSH'
cat > /opt/keybuzz/scripts/backup_redis.sh <<'REDISBACKUP'
#!/usr/bin/env bash
set -u
set -o pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/redis_backup_$TIMESTAMP"
MINIO_BUCKET="keybuzz-backups/redis"

mkdir -p "$BACKUP_DIR"

# Trigger BGSAVE
redis-cli -a "$REDIS_PASSWORD" BGSAVE

# Attendre que le BGSAVE soit terminé
while [ "$(redis-cli -a "$REDIS_PASSWORD" LASTSAVE)" == "$(redis-cli -a "$REDIS_PASSWORD" LASTSAVE)" ]; do
    sleep 2
done

# Copier le RDB
cp /var/lib/redis/dump.rdb "$BACKUP_DIR/dump_${TIMESTAMP}.rdb"

# Compresser
gzip "$BACKUP_DIR/dump_${TIMESTAMP}.rdb"

# Upload vers MinIO
mc alias set keybuzz http://10.0.0.MINIO_IP:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
mc cp "$BACKUP_DIR/dump_${TIMESTAMP}.rdb.gz" keybuzz/$MINIO_BUCKET/

# Nettoyer
rm -rf "$BACKUP_DIR"

echo "✓ Backup Redis terminé : $TIMESTAMP"
REDISBACKUP

chmod +x /opt/keybuzz/scripts/backup_redis.sh
echo "✓ Script Redis créé"
EOSSH

echo -e "$OK Script backup Redis créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: SCRIPT DE BACKUP K3S RESOURCES
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Script backup K3s Resources                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'EOSSH'
cat > /opt/keybuzz/scripts/backup_k3s.sh <<'K3SBACKUP'
#!/usr/bin/env bash
set -u
set -o pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/k3s_backup_$TIMESTAMP"
MINIO_BUCKET="keybuzz-backups/k3s-resources"

mkdir -p "$BACKUP_DIR"

# Backup des resources K8s
echo "Backup resources K8s..."

# Namespaces
kubectl get all --all-namespaces -o yaml > "$BACKUP_DIR/all-resources.yaml"

# Secrets
kubectl get secrets --all-namespaces -o yaml > "$BACKUP_DIR/secrets.yaml"

# ConfigMaps
kubectl get configmaps --all-namespaces -o yaml > "$BACKUP_DIR/configmaps.yaml"

# PVC
kubectl get pvc --all-namespaces -o yaml > "$BACKUP_DIR/pvc.yaml"

# Ingress
kubectl get ingress --all-namespaces -o yaml > "$BACKUP_DIR/ingress.yaml"

# Services
kubectl get svc --all-namespaces -o yaml > "$BACKUP_DIR/services.yaml"

# Compresser
cd "$BACKUP_DIR" && tar -czf "k3s_resources_${TIMESTAMP}.tar.gz" *.yaml

# Upload vers MinIO
mc alias set keybuzz http://10.0.0.MINIO_IP:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
mc cp "k3s_resources_${TIMESTAMP}.tar.gz" keybuzz/$MINIO_BUCKET/

# Nettoyer
cd / && rm -rf "$BACKUP_DIR"

echo "✓ Backup K3s terminé : $TIMESTAMP"
K3SBACKUP

chmod +x /opt/keybuzz/scripts/backup_k3s.sh
echo "✓ Script K3s créé"
EOSSH

echo -e "$OK Script backup K3s créé"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: CONFIGURATION CRONTABS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Configuration crontabs                                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# PostgreSQL - tous les jours à 2h du matin
echo "→ Configuration backup PostgreSQL..."
ssh -o StrictHostKeyChecking=no root@"$IP_DB_MASTER" bash <<EOSSH
# Ajouter au crontab si pas déjà présent
if ! crontab -l 2>/dev/null | grep -q "backup_postgresql.sh"; then
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/keybuzz/scripts/backup_postgresql.sh >> /var/log/backup_postgresql.log 2>&1") | crontab -
    echo "✓ Crontab PostgreSQL configuré (2h00)"
else
    echo "✓ Crontab PostgreSQL déjà configuré"
fi
EOSSH

# Redis - tous les jours à 3h du matin
echo "→ Configuration backup Redis..."
ssh -o StrictHostKeyChecking=no root@"$IP_REDIS01" bash <<EOSSH
if ! crontab -l 2>/dev/null | grep -q "backup_redis.sh"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * /opt/keybuzz/scripts/backup_redis.sh >> /var/log/backup_redis.log 2>&1") | crontab -
    echo "✓ Crontab Redis configuré (3h00)"
else
    echo "✓ Crontab Redis déjà configuré"
fi
EOSSH

# K3s - tous les jours à 4h du matin
echo "→ Configuration backup K3s..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOSSH
if ! crontab -l 2>/dev/null | grep -q "backup_k3s.sh"; then
    (crontab -l 2>/dev/null; echo "0 4 * * * /opt/keybuzz/scripts/backup_k3s.sh >> /var/log/backup_k3s.log 2>&1") | crontab -
    echo "✓ Crontab K3s configuré (4h00)"
else
    echo "✓ Crontab K3s déjà configuré"
fi
EOSSH

echo -e "$OK Crontabs configurés"

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 6: TEST MANUEL DES BACKUPS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Test des backups                                      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

read -p "Lancer un test des backups maintenant ? (yes/NO) : " test_confirm

if [ "$test_confirm" == "yes" ]; then
    echo ""
    echo "→ Test backup PostgreSQL..."
    ssh -o StrictHostKeyChecking=no root@"$IP_DB_MASTER" "/opt/keybuzz/scripts/backup_postgresql.sh"
    
    echo ""
    echo "→ Test backup Redis..."
    ssh -o StrictHostKeyChecking=no root@"$IP_REDIS01" "/opt/keybuzz/scripts/backup_redis.sh"
    
    echo ""
    echo "→ Test backup K3s..."
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "/opt/keybuzz/scripts/backup_k3s.sh"
    
    echo ""
    echo -e "$OK Tests des backups terminés"
else
    echo "Tests sautés"
fi

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         ✅ Backups automatiques configurés avec succès         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📦 Configuration :"
echo "  Bucket MinIO   : s3://keybuzz-backups/"
echo "  Rétention      : 30 jours"
echo "  URL MinIO      : http://s3.keybuzz.io:9000"
echo ""
echo "📅 Planning :"
echo "  PostgreSQL     : Tous les jours à 2h00"
echo "  Redis          : Tous les jours à 3h00"
echo "  K3s Resources  : Tous les jours à 4h00"
echo ""
echo "📂 Dossiers MinIO :"
echo "  PostgreSQL     : keybuzz-backups/postgresql/"
echo "  Redis          : keybuzz-backups/redis/"
echo "  K3s Resources  : keybuzz-backups/k3s-resources/"
echo ""
echo "🔧 Scripts créés :"
echo "  PostgreSQL     : /opt/keybuzz/scripts/backup_postgresql.sh"
echo "  Redis          : /opt/keybuzz/scripts/backup_redis.sh"
echo "  K3s            : /opt/keybuzz/scripts/backup_k3s.sh"
echo ""
echo "📊 Logs :"
echo "  PostgreSQL     : /var/log/backup_postgresql.log"
echo "  Redis          : /var/log/backup_redis.log"
echo "  K3s            : /var/log/backup_k3s.log"
echo ""
echo "🔍 Vérifier les backups :"
echo "  mc ls keybuzz/keybuzz-backups/postgresql/"
echo "  mc ls keybuzz/keybuzz-backups/redis/"
echo "  mc ls keybuzz/keybuzz-backups/k3s-resources/"
echo ""
echo "⚠️  IMPORTANT :"
echo "  - Testez régulièrement la restauration des backups"
echo "  - Surveillez l'espace disque MinIO"
echo "  - Configurez des alertes sur les échecs de backup"
echo ""
echo "Prochaine étape :"
echo "  ./21_final_validation_complete.sh"
echo ""

exit 0
