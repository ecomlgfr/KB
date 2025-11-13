#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       Activer/Désactiver l'accès aux applications                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
BACKUP_DIR="/opt/keybuzz-installer/backups/ingress"

# ═══════════════════════════════════════════════════════════════════════════
# Usage
# ═══════════════════════════════════════════════════════════════════════════

usage() {
    cat <<'EOF'
Usage: $0 [OPTIONS]

Activer ou désactiver l'accès à une application

Options:
  --app <n>       Application (n8n, chatwoot, litellm, qdrant, superset, all)
  --enable        Activer l'accès (créer l'Ingress)
  --disable       Désactiver l'accès (supprimer l'Ingress)
  --status        Afficher l'état actuel
  --help          Afficher cette aide

Exemples:
  # Désactiver l'accès à superset (maintenance)
  $0 --app superset --disable

  # Réactiver l'accès à superset
  $0 --app superset --enable

  # Désactiver toutes les applications
  $0 --app all --disable

  # Afficher l'état de qdrant
  $0 --app qdrant --status

  # Afficher l'état de toutes les apps
  $0 --app all --status

Applications supportées:
  - n8n         : Workflow automation
  - chatwoot    : Customer support
  - litellm     : LLM Router
  - qdrant      : Vector database
  - superset    : Business Intelligence
  - all         : Toutes les applications ci-dessus

Note:
  Les configurations Ingress sont sauvegardées dans :
  $BACKUP_DIR

EOF
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Parsing arguments
# ═══════════════════════════════════════════════════════════════════════════

APP=""
ACTION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            APP="$2"
            shift 2
            ;;
        --enable)
            ACTION="enable"
            shift
            ;;
        --disable)
            ACTION="disable"
            shift
            ;;
        --status)
            ACTION="status"
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

if [ -z "$ACTION" ]; then
    echo -e "$KO Action non spécifiée (--enable, --disable, ou --status)"
    usage
fi

# ═══════════════════════════════════════════════════════════════════════════
# Fonction pour gérer l'accès à une app
# ═══════════════════════════════════════════════════════════════════════════

manage_access() {
    local app="$1"
    local namespace="$app"
    local action="$2"
    
    echo ""
    echo "═══ Application: $app ═══"
    echo ""
    
    case "$action" in
        status)
            # ─── Afficher l'état ──────────────────────────────────────────
            
            ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
set -u

if kubectl get ingress $app -n $namespace >/dev/null 2>&1; then
    echo "  État : ✅ ACTIF (Ingress existe)"
    echo ""
    kubectl get ingress $app -n $namespace
else
    echo "  État : ❌ DÉSACTIVÉ (Ingress supprimé)"
    
    # Vérifier si backup existe
    if [ -f "$BACKUP_DIR/${app}.yaml" ]; then
        echo "  Backup : ✅ Disponible"
        echo "  Localisation : $BACKUP_DIR/${app}.yaml"
    else
        echo "  Backup : ❌ Non trouvé"
    fi
fi
EOF
            ;;
            
        disable)
            # ─── Désactiver l'accès ───────────────────────────────────────
            
            echo "→ Désactivation de l'accès à $app"
            
            ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
set -u

# Créer le répertoire de backup
mkdir -p "$BACKUP_DIR"

# Sauvegarder la configuration Ingress
if kubectl get ingress $app -n $namespace >/dev/null 2>&1; then
    kubectl get ingress $app -n $namespace -o yaml > "$BACKUP_DIR/${app}.yaml"
    echo "  ✓ Configuration sauvegardée"
    
    # Supprimer l'Ingress
    kubectl delete ingress $app -n $namespace
    echo "  ✓ Ingress supprimé"
else
    echo "  ⚠️  Ingress déjà supprimé"
fi
EOF
            
            if [ $? -eq 0 ]; then
                echo -e "  $OK Accès désactivé pour $app"
                echo "  → L'application n'est plus accessible depuis Internet"
            else
                echo -e "  $KO Erreur lors de la désactivation"
            fi
            ;;
            
        enable)
            # ─── Activer l'accès ──────────────────────────────────────────
            
            echo "→ Activation de l'accès à $app"
            
            ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
set -u

# Vérifier si l'Ingress existe déjà
if kubectl get ingress $app -n $namespace >/dev/null 2>&1; then
    echo "  ⚠️  Ingress déjà actif"
    exit 0
fi

# Restaurer depuis le backup si disponible
if [ -f "$BACKUP_DIR/${app}.yaml" ]; then
    kubectl apply -f "$BACKUP_DIR/${app}.yaml"
    echo "  ✓ Configuration restaurée depuis backup"
else
    # Créer un Ingress par défaut
    echo "  ⚠️  Pas de backup trouvé, création d'un Ingress par défaut..."
    
    # Déterminer le host et le service selon l'app
    case "$app" in
        n8n)
            HOST="n8n.keybuzz.io"
            SERVICE="n8n"
            PORT="5678"
            ;;
        chatwoot)
            HOST="chat.keybuzz.io"
            SERVICE="chatwoot-web"
            PORT="3000"
            ;;
        litellm)
            HOST="llm.keybuzz.io"
            SERVICE="litellm"
            PORT="4000"
            ;;
        qdrant)
            HOST="qdrant.keybuzz.io"
            SERVICE="qdrant"
            PORT="6333"
            ;;
        superset)
            HOST="superset.keybuzz.io"
            SERVICE="superset"
            PORT="8088"
            ;;
        *)
            echo "  ✗ Application inconnue : $app"
            exit 1
            ;;
    esac
    
    cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $app
  namespace: $namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - host: \$HOST
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: \$SERVICE
            port:
              number: \$PORT
YAML
    
    echo "  ✓ Ingress créé"
fi
EOF
            
            if [ $? -eq 0 ]; then
                echo -e "  $OK Accès activé pour $app"
                echo "  → L'application est maintenant accessible depuis Internet"
            else
                echo -e "  $KO Erreur lors de l'activation"
            fi
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# Exécution
# ═══════════════════════════════════════════════════════════════════════════

echo ""
case "$ACTION" in
    status)
        echo "Action : Afficher l'état"
        ;;
    enable)
        echo "Action : Activer l'accès"
        ;;
    disable)
        echo "Action : Désactiver l'accès"
        ;;
esac

if [ "$APP" = "all" ]; then
    echo "  Applications : n8n, chatwoot, litellm, qdrant, superset"
else
    echo "  Application : $APP"
fi

if [ "$ACTION" != "status" ]; then
    echo ""
    read -p "Continuer ? (yes/NO) : " confirm
    [ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Exécution en cours ═══"
echo "═══════════════════════════════════════════════════════════════════"

if [ "$APP" = "all" ]; then
    for app in n8n chatwoot litellm qdrant superset; do
        manage_access "$app" "$ACTION"
    done
else
    manage_access "$APP" "$ACTION"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Opération terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$ACTION" = "disable" ]; then
    echo "✅ Accès désactivé"
    echo ""
    echo "Les applications ne sont plus accessibles depuis Internet."
    echo "Les pods continuent de tourner normalement."
    echo ""
    echo "Pour réactiver l'accès :"
    echo "  $0 --app $APP --enable"
elif [ "$ACTION" = "enable" ]; then
    echo "✅ Accès activé"
    echo ""
    echo "Les applications sont maintenant accessibles depuis Internet."
    echo ""
    echo "Test d'accès :"
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
fi

echo ""
