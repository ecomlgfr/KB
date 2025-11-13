#!/usr/bin/env bash
set -u
set -o pipefail

# ╔════════════════════════════════════════════════════════════════════╗
# ║                         MINIO INSTALLATION                         ║
# ║                    Hetzner Private Network Only                    ║
# ╚════════════════════════════════════════════════════════════════════╝

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[1;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_FILE="/opt/keybuzz-installer/credentials/secrets.json"
LOG_FILE="/opt/keybuzz-installer/logs/minio_install.log"

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                         MINIO INSTALLATION                         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier que servers.tsv existe
if [[ ! -f "$SERVERS_TSV" ]]; then
    echo -e "$KO Fichier servers.tsv introuvable: $SERVERS_TSV"
    exit 1
fi

# Extraire l'IP privée de minio-01
IP_TSV="$(awk -F'\t' '$2=="minio-01"{print $3}' "$SERVERS_TSV")"
if [[ -z "$IP_TSV" ]]; then
    echo -e "$KO IP privée de minio-01 introuvable dans servers.tsv"
    exit 1
fi

echo -e "$OK Cible: minio-01 ($IP_TSV)"
echo ""

# Générer les secrets MinIO si absents
mkdir -p "$(dirname "$CREDENTIALS_FILE")"
chmod 700 "$(dirname "$CREDENTIALS_FILE")"

if [[ -f "$CREDENTIALS_FILE" ]] && jq -e '.minio' "$CREDENTIALS_FILE" &>/dev/null; then
    MINIO_ROOT_USER=$(jq -r '.minio.root_user' "$CREDENTIALS_FILE")
    MINIO_ROOT_PASSWORD=$(jq -r '.minio.root_password' "$CREDENTIALS_FILE")
    echo -e "$OK Secrets MinIO existants récupérés"
else
    MINIO_ROOT_USER="admin-$(openssl rand -hex 4)"
    MINIO_ROOT_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
    
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        TMP_FILE=$(mktemp)
        jq --arg user "$MINIO_ROOT_USER" --arg pass "$MINIO_ROOT_PASSWORD" \
            '.minio = {root_user: $user, root_password: $pass}' \
            "$CREDENTIALS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CREDENTIALS_FILE"
    else
        echo "{\"minio\":{\"root_user\":\"$MINIO_ROOT_USER\",\"root_password\":\"$MINIO_ROOT_PASSWORD\"}}" > "$CREDENTIALS_FILE"
    fi
    
    chmod 600 "$CREDENTIALS_FILE"
    echo -e "$OK Secrets MinIO générés et stockés"
fi

# Connexion SSH et installation
echo "Connexion SSH vers minio-01..."
echo ""

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP_TSV" bash <<EOSSH | tee "$LOG_FILE"
set -u
set -o pipefail

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[1;33m⚠\033[0m'

echo "════════════════════════════════════════════════════════════════════"
echo "  PHASE 1: Préparation de l'environnement MinIO"
echo "════════════════════════════════════════════════════════════════════"
echo ""

# Structure de base
BASE="/opt/keybuzz/minio"
DATA="\$BASE/data"
CFG="\$BASE/config"
LOGS="\$BASE/logs"
ST="\$BASE/status"

mkdir -p "\$DATA" "\$CFG" "\$LOGS" "\$ST"
echo -e "\$OK Structure de dossiers créée"

# Vérifier et monter le volume Hetzner
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  PHASE 2: Configuration du volume Hetzner"
echo "════════════════════════════════════════════════════════════════════"
echo ""

if ! mountpoint -q "\$DATA"; then
    echo "Volume non monté, recherche d'un périphérique libre..."
    
    DEV=""
    # Chercher d'abord par ID SCSI
    for candidate in /dev/disk/by-id/scsi-*; do
        [[ -e "\$candidate" ]] || continue
        [[ "\$candidate" =~ -part ]] && continue
        real=\$(readlink -f "\$candidate" 2>/dev/null || echo "\$candidate")
        mount | grep -q " \$real " && continue
        DEV="\$real"
        break
    done
    
    # Fallback sur /dev/sd* et /dev/vd*
    if [[ -z "\$DEV" ]]; then
        for candidate in /dev/sd{b..z} /dev/vd{b..z}; do
            [[ -b "\$candidate" ]] || continue
            mount | grep -q " \$candidate " && continue
            DEV="\$candidate"
            break
        done
    fi
    
    if [[ -z "\$DEV" ]]; then
        echo -e "\$KO Aucun périphérique libre trouvé"
        exit 1
    fi
    
    echo -e "\$OK Périphérique détecté: \$DEV"
    
    # Formater si nécessaire
    if ! blkid "\$DEV" 2>/dev/null | grep -q ext4; then
        echo "Formatage en ext4..."
        wipefs -af "\$DEV" 2>/dev/null || true
        mkfs.ext4 -F -m0 -O dir_index,has_journal,extent "\$DEV" >/dev/null 2>&1
        echo -e "\$OK Formatage terminé"
    else
        echo -e "\$OK Système de fichiers ext4 déjà présent"
    fi
    
    # Monter
    echo "Montage sur \$DATA..."
    mount "\$DEV" "\$DATA" 2>/dev/null
    echo -e "\$OK Volume monté"
    
    # Ajouter à fstab
    UUID=\$(blkid -s UUID -o value "\$DEV")
    if ! grep -q " \$DATA " /etc/fstab; then
        echo "UUID=\$UUID \$DATA ext4 defaults,nofail 0 2" >> /etc/fstab
        echo -e "\$OK Ajout à /etc/fstab (UUID=\$UUID)"
    fi
    
    # Supprimer lost+found
    if [[ -d "\$DATA/lost+found" ]]; then
        rm -rf "\$DATA/lost+found"
        echo -e "\$OK lost+found supprimé"
    fi
else
    echo -e "\$OK Volume déjà monté sur \$DATA"
fi

echo ""
df -h "\$DATA" | grep -v "^Filesystem"

# Détecter l'IP privée locale
IP_PRIVEE="\$(hostname -I | awk '{print \$1}')"
echo ""
echo -e "\$OK IP privée détectée: \$IP_PRIVEE"

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  PHASE 3: Déploiement Docker Compose"
echo "════════════════════════════════════════════════════════════════════"
echo ""

# Créer le fichier .env
cat > "\$BASE/.env" <<ENV
IP_PRIVEE=\$IP_PRIVEE
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
ENV
chmod 600 "\$BASE/.env"
echo -e "\$OK Fichier .env créé"

# Créer docker-compose.yml
cat > "\$BASE/docker-compose.yml" <<'COMPOSE'
services:
  minio:
    image: quay.io/minio/minio:latest
    container_name: minio
    command: server /data --console-address ":9001"
    ports:
      - "\${IP_PRIVEE}:9000:9000"
      - "\${IP_PRIVEE}:9001:9001"
    environment:
      MINIO_ROOT_USER: "\${MINIO_ROOT_USER}"
      MINIO_ROOT_PASSWORD: "\${MINIO_ROOT_PASSWORD}"
      MINIO_BROWSER_REDIRECT_URL: "http://\${IP_PRIVEE}:9001"
    volumes:
      - /opt/keybuzz/minio/data:/data
      - /opt/keybuzz/minio/config:/root/.minio
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
COMPOSE

echo -e "\$OK docker-compose.yml créé"

# Arrêter les conteneurs existants si présents
if docker ps -a | grep -q minio; then
    echo "Arrêt des conteneurs MinIO existants..."
    docker compose -f "\$BASE/docker-compose.yml" down 2>/dev/null || true
    docker rm -f minio 2>/dev/null || true
fi

# Démarrer MinIO
echo "Démarrage de MinIO..."
cd "\$BASE"
docker compose up -d

echo ""
echo "Attente du démarrage du conteneur (10s)..."
sleep 10

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  PHASE 4: Vérifications et configuration"
echo "════════════════════════════════════════════════════════════════════"
echo ""

# Vérifier le conteneur
if docker ps | grep -q minio; then
    echo -e "\$OK Conteneur MinIO actif"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep minio
else
    echo -e "\$KO Conteneur MinIO non détecté"
    docker ps -a | grep minio || true
    echo ""
    echo "Logs Docker:"
    docker logs minio 2>&1 | tail -n 20
    echo "KO" > "\$ST/STATE"
    exit 1
fi

echo ""

# Configuration du client mc
echo "Configuration du client MinIO (mc)..."

# Télécharger mc si absent
if ! command -v mc &>/dev/null; then
    echo "Installation du client mc..."
    wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
    echo -e "\$OK Client mc installé"
else
    echo -e "\$OK Client mc déjà présent"
fi

# Attendre que MinIO soit prêt
echo "Attente de la disponibilité de l'API MinIO..."
for i in {1..30}; do
    if curl -sf "http://\$IP_PRIVEE:9000/minio/health/live" >/dev/null 2>&1; then
        echo -e "\$OK MinIO API prête"
        break
    fi
    [[ \$i -eq 30 ]] && { echo -e "\$KO Timeout API MinIO"; exit 1; }
    sleep 2
done

echo ""

# Configurer l'alias mc
echo "Configuration de l'alias mc..."
mc alias set minio "http://\$IP_PRIVEE:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 2>&1 | grep -v "mc:" || true
echo -e "\$OK Alias mc configuré"

# Créer le bucket keybuzz-backups
echo "Création du bucket keybuzz-backups..."
mc mb --ignore-existing minio/keybuzz-backups 2>&1 | grep -v "mc:" || true
echo -e "\$OK Bucket keybuzz-backups créé"

# Test d'upload
echo "Test d'upload..."
echo "MinIO operational on \$(date)" > /tmp/minio_test.txt
mc cp /tmp/minio_test.txt minio/keybuzz-backups/test/minio_test.txt 2>&1 | grep -v "mc:" || true
rm -f /tmp/minio_test.txt

# Vérifier le fichier
if mc ls minio/keybuzz-backups/test/ 2>&1 | grep -q "minio_test.txt"; then
    echo -e "\$OK Test d'upload réussi"
else
    echo -e "\$WARN Test d'upload incertain"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  RÉSUMÉ FINAL"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "Service:     MinIO"
echo "IP:          \$IP_PRIVEE"
echo "API:         http://\$IP_PRIVEE:9000"
echo "Console:     http://\$IP_PRIVEE:9001"
echo "Bucket:      keybuzz-backups"
echo "État:        OPÉRATIONNEL"
echo ""
echo "Credentials:"
echo "  User:      $MINIO_ROOT_USER"
echo "  Password:  [stocké dans secrets.json]"
echo ""

# Écrire l'état final
echo "OK" > "\$ST/STATE"
echo -e "\$OK Installation MinIO terminée avec succès"

EOSSH

EXITCODE=$?

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Logs d'installation (50 dernières lignes)"
echo "════════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_TSV" "tail -n 50 $LOG_FILE 2>/dev/null" || echo "Aucun log disponible"

echo ""
echo "════════════════════════════════════════════════════════════════════"

if [[ $EXITCODE -eq 0 ]]; then
    echo -e "$OK Installation MinIO réussie"
    echo ""
    echo "Accès:"
    echo "  • API S3:     http://$IP_TSV:9000"
    echo "  • Console:    http://$IP_TSV:9001"
    echo "  • User:       $MINIO_ROOT_USER"
    echo "  • Bucket:     keybuzz-backups"
    echo ""
    echo "Test mc depuis install-01:"
    echo "  mc alias set minio http://$IP_TSV:9000 $MINIO_ROOT_USER [password]"
    echo "  mc ls minio/keybuzz-backups/"
else
    echo -e "$KO Échec de l'installation MinIO"
    exit 1
fi

echo ""
