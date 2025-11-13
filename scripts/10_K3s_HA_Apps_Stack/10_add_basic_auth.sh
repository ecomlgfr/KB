#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       Authentification basique pour Ingress NGINX                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

# ═══════════════════════════════════════════════════════════════════════════
# Usage
# ═══════════════════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Ajouter/Retirer l'authentification basique sur les Ingress

Options:
  --app <name>       Application (n8n, chatwoot, litellm, qdrant, superset, all)
  --user <username>  Nom d'utilisateur (défaut: admin)
  --password <pass>  Mot de passe (défaut: généré aléatoirement)
  --remove           Retirer l'authentification
  --help             Afficher cette aide

Exemples:
  # Ajouter auth sur superset avec mot de passe généré
  $0 --app superset --user admin

  # Ajouter auth sur toutes les apps avec mot de passe spécifique
  $0 --app all --user keybuzz --password MySecurePass123

  # Retirer auth sur qdrant
  $0 --app qdrant --remove

Applications supportées:
  - n8n         : Workflow automation
  - chatwoot    : Customer support
  - litellm     : LLM Router
  - qdrant      : Vector database
  - superset    : Business Intelligence
  - all         : Toutes les applications ci-dessus

EOF
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Parsing arguments
# ═══════════════════════════════════════════════════════════════════════════

APP=""
USERNAME="admin"
PASSWORD=""
REMOVE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            APP="$2"
            shift 2
            ;;
        --user)
            USERNAME="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --remove)
            REMOVE=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Option invalide: $1"
            usage
            ;;
    esac
done

if [ -z "$APP" ]; then
    echo -e "$KO Application non spécifiée"
    usage
fi

# Générer un mot de passe si non fourni
if [ -z "$PASSWORD" ] && [ "$REMOVE" = false ]; then
    PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
fi

# ═══════════════════════════════════════════════════════════════════════════
# Fonction pour ajouter/retirer auth sur une app
# ═══════════════════════════════════════════════════════════════════════════

manage_auth() {
    local app="$1"
    local namespace="$app"
    
    echo ""
    echo "═══ Application: $app ═══"
    echo ""
    
    if [ "$REMOVE" = true ]; then
        # ─── Retirer l'authentification ───────────────────────────────────
        
        echo "→ Suppression de l'authentification basique sur $app"
        
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
set -u

# Supprimer le secret
kubectl delete secret basic-auth -n $namespace 2>/dev/null || true

# Retirer les annotations du Ingress
kubectl annotate ingress $app -n $namespace \
    nginx.ingress.kubernetes.io/auth-type- \
    nginx.ingress.kubernetes.io/auth-secret- \
    nginx.ingress.kubernetes.io/auth-realm- 2>/dev/null || true

echo "  ✓ Authentification retirée"
EOF
        
    else
        # ─── Ajouter l'authentification ───────────────────────────────────
        
        echo "→ Ajout de l'authentification basique sur $app"
        echo "  Utilisateur : $USERNAME"
        echo "  Mot de passe : ${PASSWORD:0:10}***"
        
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
set -u

# Créer le fichier auth
htpasswd -bc /tmp/auth "$USERNAME" "$PASSWORD"

# Créer le secret
kubectl create secret generic basic-auth \\
    --from-file=auth=/tmp/auth \\
    -n $namespace --dry-run=client -o yaml | kubectl apply -f -

rm /tmp/auth

# Ajouter les annotations au Ingress
kubectl annotate ingress $app -n $namespace \\
    nginx.ingress.kubernetes.io/auth-type=basic \\
    nginx.ingress.kubernetes.io/auth-secret=basic-auth \\
    nginx.ingress.kubernetes.io/auth-realm="Authentication Required" \\
    --overwrite

echo "  ✓ Authentification ajoutée"
EOF
        
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $app configuré"
    else
        echo -e "  $KO Erreur sur $app"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Exécution
# ═══════════════════════════════════════════════════════════════════════════

echo ""
if [ "$REMOVE" = true ]; then
    echo "Action : Retirer l'authentification basique"
else
    echo "Action : Ajouter l'authentification basique"
    echo "  Utilisateur : $USERNAME"
    echo "  Mot de passe : ${PASSWORD:0:10}*** (${#PASSWORD} caractères)"
fi

if [ "$APP" = "all" ]; then
    echo "  Applications : n8n, chatwoot, litellm, qdrant, superset"
else
    echo "  Application : $APP"
fi

echo ""
read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Configuration en cours ═══"
echo "═══════════════════════════════════════════════════════════════════"

if [ "$APP" = "all" ]; then
    for app in n8n chatwoot litellm qdrant superset; do
        manage_auth "$app"
    done
else
    manage_auth "$APP"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Configuration terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$REMOVE" = false ]; then
    echo "Credentials à utiliser :"
    echo "  Utilisateur : $USERNAME"
    echo "  Mot de passe : $PASSWORD"
    echo ""
    echo "Ces credentials sont stockés dans :"
    echo "  /opt/keybuzz-installer/credentials/basic-auth-${APP}.txt"
    echo ""
    
    # Sauvegarder les credentials
    CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"
    mkdir -p "$CREDENTIALS_DIR"
    
    cat > "$CREDENTIALS_DIR/basic-auth-${APP}.txt" <<EOF
Application: $APP
Username: $USERNAME
Password: $PASSWORD
Date: $(date)
EOF
    chmod 600 "$CREDENTIALS_DIR/basic-auth-${APP}.txt"
    
    echo "Test d'accès :"
    if [ "$APP" = "all" ]; then
        echo "  curl -u $USERNAME:$PASSWORD https://n8n.keybuzz.io"
        echo "  curl -u $USERNAME:$PASSWORD https://chat.keybuzz.io"
        echo "  curl -u $USERNAME:$PASSWORD https://llm.keybuzz.io"
        echo "  curl -u $USERNAME:$PASSWORD https://qdrant.keybuzz.io"
        echo "  curl -u $USERNAME:$PASSWORD https://superset.keybuzz.io"
    else
        case "$APP" in
            n8n)       echo "  curl -u $USERNAME:$PASSWORD https://n8n.keybuzz.io" ;;
            chatwoot)  echo "  curl -u $USERNAME:$PASSWORD https://chat.keybuzz.io" ;;
            litellm)   echo "  curl -u $USERNAME:$PASSWORD https://llm.keybuzz.io" ;;
            qdrant)    echo "  curl -u $USERNAME:$PASSWORD https://qdrant.keybuzz.io" ;;
            superset)  echo "  curl -u $USERNAME:$PASSWORD https://superset.keybuzz.io" ;;
        esac
    fi
else
    echo "L'authentification a été retirée."
    echo ""
    echo "Test d'accès (sans authentification) :"
    if [ "$APP" = "all" ]; then
        echo "  curl https://n8n.keybuzz.io"
    else
        case "$APP" in
            n8n)       echo "  curl https://n8n.keybuzz.io" ;;
            chatwoot)  echo "  curl https://chat.keybuzz.io" ;;
            litellm)   echo "  curl https://llm.keybuzz.io" ;;
            qdrant)    echo "  curl https://qdrant.keybuzz.io" ;;
            superset)  echo "  curl https://superset.keybuzz.io" ;;
        esac
    fi
fi

echo ""
