#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Génération automatique des credentials
###############################################################################
# Ce script génère des credentials sécurisés et met à jour le fichier .env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.mariadb_proxysql_erpnext"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERREUR: Fichier $ENV_FILE introuvable!"
    exit 1
fi

echo "Génération des credentials manquants..."

# Fonction pour générer un password aléatoire
generate_password() {
    openssl rand -base64 16 | tr -d "=+/" | cut -c1-20
}

# Backup du .env
cp "$ENV_FILE" "${ENV_FILE}.bak"

# Lecture et mise à jour des credentials vides
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue

    # Si la valeur est vide et que c'est un PASSWORD, on génère
    if [[ -z "$value" || "$value" == '""' ]]; then
        if [[ "$key" == *"PASSWORD"* ]]; then
            new_password=$(generate_password)
            sed -i "s|^${key}=.*|${key}=\"${new_password}\"|g" "$ENV_FILE"
            echo "  ✓ Généré: $key"
        fi
    fi
done < "$ENV_FILE"

echo ""
echo "✓ Credentials générés et sauvegardés dans $ENV_FILE"
echo "✓ Backup: ${ENV_FILE}.bak"
echo ""
echo "⚠️  IMPORTANT: Sauvegarder ce fichier dans un endroit sûr!"
