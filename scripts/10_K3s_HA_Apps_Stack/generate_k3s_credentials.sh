#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Génération automatique des credentials pour applications K3s
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.k3s_apps"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERREUR: Fichier $ENV_FILE introuvable!"
    exit 1
fi

echo "Génération des credentials manquants pour applications K3s..."

# Fonction pour générer un password aléatoire
generate_password() {
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-32
}

# Fonction pour générer une clé de chiffrement (64 chars hex)
generate_encryption_key() {
    openssl rand -hex 32
}

# Backup du .env
cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Lecture et mise à jour des credentials vides
declare -A GENERATED

while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue

    # Nettoyer la valeur (enlever quotes et espaces)
    value=$(echo "$value" | sed 's/^"//;s/"$//' | xargs)

    # Si la valeur est vide et que c'est un credential, on génère
    if [[ -z "$value" ]]; then
        new_value=""

        if [[ "$key" == *"PASSWORD"* ]] || [[ "$key" == *"_KEY"* && "$key" != *"_KEY_PATH"* ]] || [[ "$key" == *"TOKEN"* ]]; then
            if [[ "$key" == "N8N_ENCRYPTION_KEY" ]] || [[ "$key" == "CHATWOOT_SECRET_KEY_BASE" ]] || [[ "$key" == "SUPERSET_SECRET_KEY" ]] || [[ "$key" == "LITELLM_MASTER_KEY" ]]; then
                new_value=$(generate_encryption_key)
            else
                new_value=$(generate_password)
            fi

            if [[ -n "$new_value" ]]; then
                sed -i "s|^${key}=.*|${key}=\"${new_value}\"|g" "$ENV_FILE"
                echo "  ✓ Généré: $key"
                GENERATED[$key]=$new_value
            fi
        fi
    fi
done < "$ENV_FILE"

echo ""
echo "✓ Credentials générés et sauvegardés dans $ENV_FILE"
echo "✓ Backup: ${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
echo ""
echo "Credentials générés:"
for key in "${!GENERATED[@]}"; do
    echo "  - $key"
done
echo ""
echo "⚠️  IMPORTANT: Sauvegarder ce fichier dans un endroit sûr!"
