#!/usr/bin/env bash

###############################################################################
# Script: run_fix_from_install01.sh
# Description: Wrapper pour exécuter fix_k3s_apps_issues.sh depuis install-01
# Auteur: KeyBuzz Infrastructure Team
# Date: 2025-11-17
###############################################################################

set -u
set -o pipefail

# ╔════════════════════════════════════════════════════════════════════╗
# ║  CONFIGURATION (depuis servers.tsv)                                ║
# ╚════════════════════════════════════════════════════════════════════╝

# install-01 : 91.98.128.153 / 10.0.0.20 / install-01.keybuzz.io
INSTALL01_IP="${INSTALL01_IP:-10.0.0.20}"
INSTALL01_USER="${INSTALL01_USER:-root}"

# Chemin vers le script de fix
SCRIPT_NAME="fix_k3s_apps_issues.sh"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$SCRIPT_NAME"
REMOTE_PATH="/tmp/$SCRIPT_NAME"

# Couleurs
OK="✓"
KO="✗"
INFO="ℹ"
WARN="⚠"

# ╔════════════════════════════════════════════════════════════════════╗
# ║  FONCTIONS                                                         ║
# ╚════════════════════════════════════════════════════════════════════╝

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# ╔════════════════════════════════════════════════════════════════════╗
# ║  VÉRIFICATIONS                                                     ║
# ╚════════════════════════════════════════════════════════════════════╝

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  Exécution du script de correction K3s depuis install-01          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Vérifier que le script existe
if [ ! -f "$SCRIPT_PATH" ]; then
    log "$KO Script non trouvé: $SCRIPT_PATH"
    exit 1
fi

log "$INFO Connexion à install-01 ($INSTALL01_IP - install-01.keybuzz.io)..."

# Tester la connexion SSH
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$INSTALL01_USER@$INSTALL01_IP" "echo OK" &>/dev/null; then
    log "$KO Impossible de se connecter à install-01"
    log ""
    log "Vérifiez:"
    log "  1. L'IP de install-01 est correcte: $INSTALL01_IP"
    log "  2. Les clés SSH sont configurées"
    log "  3. Le firewall autorise SSH (port 22)"
    log ""
    log "Informations depuis servers.tsv:"
    log "  Hostname: install-01.keybuzz.io"
    log "  IP Wireguard: 10.0.0.20"
    log "  IP Publique: 91.98.128.153"
    log ""
    log "Pour définir une IP différente:"
    log "  export INSTALL01_IP=<ip_de_install01>"
    log "  $0"
    exit 1
fi

log "$OK Connexion SSH établie"

# ╔════════════════════════════════════════════════════════════════════╗
# ║  COPIE DU SCRIPT                                                   ║
# ╚════════════════════════════════════════════════════════════════════╝

log "$INFO Copie du script sur install-01..."
if ! scp -o StrictHostKeyChecking=no "$SCRIPT_PATH" "$INSTALL01_USER@$INSTALL01_IP:$REMOTE_PATH" &>/dev/null; then
    log "$KO Erreur lors de la copie du script"
    exit 1
fi

log "$OK Script copié"

# ╔════════════════════════════════════════════════════════════════════╗
# ║  EXÉCUTION À DISTANCE                                              ║
# ╚════════════════════════════════════════════════════════════════════╝

log "$INFO Exécution du script sur install-01..."
log ""
log "════════════════════════════════════════════════════════════════════"
log "                    OUTPUT DU SCRIPT                                "
log "════════════════════════════════════════════════════════════════════"
echo ""

# Exécuter le script à distance et afficher la sortie en temps réel
ssh -o StrictHostKeyChecking=no "$INSTALL01_USER@$INSTALL01_IP" "chmod +x $REMOTE_PATH && $REMOTE_PATH"
EXIT_CODE=$?

echo ""
log "════════════════════════════════════════════════════════════════════"
log "                    FIN DE L'EXÉCUTION                              "
log "════════════════════════════════════════════════════════════════════"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    log "$OK Script exécuté avec succès"
    log ""
    log "Le log complet est disponible sur install-01:"
    log "  /opt/keybuzz-installer/logs/fix_k3s_apps_*.log"
    log ""
    log "Pour vérifier l'état des services:"
    log "  ssh $INSTALL01_USER@$INSTALL01_IP"
    log "  kubectl get pods -A"
else
    log "$KO Le script a rencontré des erreurs (exit code: $EXIT_CODE)"
    log ""
    log "Consultez les logs sur install-01:"
    log "  ssh $INSTALL01_USER@$INSTALL01_IP"
    log "  tail -f /opt/keybuzz-installer/logs/fix_k3s_apps_*.log"
fi

# Nettoyage optionnel
log "$INFO Nettoyage du script temporaire..."
ssh -o StrictHostKeyChecking=no "$INSTALL01_USER@$INSTALL01_IP" "rm -f $REMOTE_PATH" &>/dev/null

exit $EXIT_CODE
