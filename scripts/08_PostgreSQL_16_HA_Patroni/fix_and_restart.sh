#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           FIX_AND_RESTART - Correction et relance                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

echo ""
echo "1. Vérification et correction des credentials..."
echo ""

CREDS_FILE="/opt/keybuzz-installer/credentials/postgres.env"

# Vérifier si le fichier existe
if [ -f "$CREDS_FILE" ]; then
    echo "  Fichier credentials existant, vérification..."
    
    # Charger et vérifier
    source "$CREDS_FILE"
    
    # Vérifier les variables manquantes
    if [ -z "${PATRONI_API_PASSWORD:-}" ] || [ -z "${REPLICATOR_PASSWORD:-}" ]; then
        echo "  Variables manquantes détectées, ajout..."
        
        # Générer les mots de passe manquants
        [ -z "${PATRONI_API_PASSWORD:-}" ] && PATRONI_API_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
        [ -z "${REPLICATOR_PASSWORD:-}" ] && REPLICATOR_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
        
        # Ajouter au fichier
        cat >> "$CREDS_FILE" <<EOF

# Variables ajoutées pour correction
export PATRONI_API_PASSWORD="${PATRONI_API_PASSWORD}"
export REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD}"
EOF
        echo -e "  $OK Variables ajoutées"
    else
        echo -e "  $OK Variables déjà présentes"
    fi
else
    echo "  Création du fichier credentials..."
    
    # Générer tous les mots de passe
    POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    REPLICATOR_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    PATRONI_API_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
    
    mkdir -p /opt/keybuzz-installer/credentials
    
    cat > "$CREDS_FILE" <<EOF
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
    
    chmod 600 "$CREDS_FILE"
    echo -e "  $OK Fichier créé"
fi

# Recharger les credentials
source "$CREDS_FILE"

echo ""
echo "2. Arrêt des containers en erreur..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Arrêt sur $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" "docker stop patroni 2>/dev/null; docker rm patroni 2>/dev/null" 2>/dev/null
    echo -e "$OK"
done

echo ""
echo "3. Vérification des logs d'erreur..."
echo ""

echo "  Erreurs sur db-master-01:"
ssh root@10.0.0.120 'docker logs patroni 2>&1 | grep -E "ERROR|FATAL|error" | tail -5' 2>/dev/null || echo "    Pas de logs"

echo ""
echo "4. Nettoyage des configurations erronées..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Nettoyage $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEAN' 2>/dev/null
rm -f /opt/keybuzz/patroni/config/patroni.yml
rm -rf /opt/keybuzz/postgres/raft/*
CLEAN
    echo -e "$OK"
done

echo ""
echo "5. Affichage des credentials pour vérification..."
echo ""

echo "  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}"
echo "  REPLICATOR_PASSWORD: ${REPLICATOR_PASSWORD}"
echo "  PATRONI_API_PASSWORD: ${PATRONI_API_PASSWORD}"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Corrections appliquées"
echo ""
echo "Maintenant, relancez l'installation :"
echo "  ./02_install_patroni_raft.sh"
echo ""
echo "Les credentials sont maintenant dans: $CREDS_FILE"
echo "═══════════════════════════════════════════════════════════════════"
