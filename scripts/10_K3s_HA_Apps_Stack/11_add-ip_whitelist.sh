#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       IP Whitelist pour Ingress NGINX                             ║"
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
    cat <<'EOF'
Usage: $0 [OPTIONS]

Ajouter/Retirer une IP whitelist sur les Ingress

Options:
  --app <name>       Application (n8n, chatwoot, litellm, qdrant, superset, all)
  --ips <ips>        Liste d'IPs autorisées (séparées par des virgules)
  --cidr <cidr>      CIDR autorisé (ex: 203.0.113.0/24)
  --remove           Retirer la whitelist
  --help             Afficher cette aide

Exemples:
  # Autoriser une seule IP
  $0 --app superset --ips 203.0.113.42

  # Autoriser plusieurs IPs
  $0 --app qdrant --ips 203.0.113.42,198.51.100.10

  # Autoriser un réseau entier
  $0 --app all --cidr 203.0.113.0/24

  # Autoriser réseau interne Hetzner + votre IP
  $0 --app litellm --ips 203.0.113.42 --cidr 10.0.0.0/16

  # Retirer la whitelist
  $0 --app superset --remove

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
IPS=""
CIDR=""
REMOVE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            APP="$2"
            shift 2
            ;;
        --ips)
            IPS="$2"
            shift 2
            ;;
        --cidr)
            CIDR="$2"
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

if [ "$REMOVE" = false ] && [ -z "$IPS" ] && [ -z "$CIDR" ]; then
    echo -e "$KO Aucune IP ou CIDR spécifié"
    usage
fi

# ═══════════════════════════════════════════════════════════════════════════
# Construire la liste d'IPs autorisées
# ═══════════════════════════════════════════════════════════════════════════

WHITELIST=""

if [ -n "$IPS" ]; then
    WHITELIST="$IPS"
fi

if [ -n "$CIDR" ]; then
    if [ -n "$WHITELIST" ]; then
        WHITELIST="$WHITELIST,$CIDR"
    else
        WHITELIST="$CIDR"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Fonction pour gérer la whitelist sur une app
# ═══════════════════════════════════════════════════════════════════════════

manage_whitelist() {
    local app="$1"
    local namespace="$app"
    
    echo ""
    echo "═══ Application: $app ═══"
    echo ""
    
    if [ "$REMOVE" = true ]; then
        # ─── Retirer la whitelist ─────────────────────────────────────────
        
        echo "→ Suppression de la whitelist sur $app"
        
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
set -u

# Retirer l'annotation du Ingress
kubectl annotate ingress $app -n $namespace \
    nginx.ingress.kubernetes.io/whitelist-source-range- 2>/dev/null || true

echo "  ✓ Whitelist retirée"
EOF
        
    else
        # ─── Ajouter la whitelist ─────────────────────────────────────────
        
        echo "→ Ajout de la whitelist sur $app"
        echo "  IPs autorisées : $WHITELIST"
        
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
set -u

# Ajouter l'annotation au Ingress
kubectl annotate ingress $app -n $namespace \
    nginx.ingress.kubernetes.io/whitelist-source-range="$WHITELIST" \
    --overwrite

echo "  ✓ Whitelist ajoutée"
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
    echo "Action : Retirer la whitelist IP"
else
    echo "Action : Ajouter une whitelist IP"
    echo "  IPs autorisées : $WHITELIST"
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
        manage_whitelist "$app"
    done
else
    manage_whitelist "$APP"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Configuration terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$REMOVE" = false ]; then
    echo "IPs autorisées : $WHITELIST"
    echo ""
    echo "Test d'accès depuis une IP autorisée :"
    if [ "$APP" = "all" ]; then
        echo "  curl https://n8n.keybuzz.io"
        echo "  curl https://chat.keybuzz.io"
    else
        case "$APP" in
            n8n)       echo "  curl https://n8n.keybuzz.io" ;;
            chatwoot)  echo "  curl https://chat.keybuzz.io" ;;
            litellm)   echo "  curl https://llm.keybuzz.io" ;;
            qdrant)    echo "  curl https://qdrant.keybuzz.io" ;;
            superset)  echo "  curl https://superset.keybuzz.io" ;;
        esac
    fi
    echo ""
    echo "⚠️  Les IPs non autorisées recevront une erreur 403 Forbidden"
else
    echo "La whitelist a été retirée. Toutes les IPs peuvent maintenant accéder."
fi

echo ""
