#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    MASTER SCRIPT - Déploiement Chatwoot & Superset               ║"
echo "║    Séquence complète automatisée                                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

SCRIPTS_DIR="/opt/keybuzz-installer/scripts"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

[ ! -d "$SCRIPTS_DIR" ] && { echo -e "$KO Répertoire scripts introuvable"; exit 1; }
[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"

cd "$SCRIPTS_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Séquence de déploiement - KeyBuzz Applications"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo -e "${INFO} Cette séquence va :"
echo "  1. Diagnostiquer l'état actuel"
echo "  2. Déployer Chatwoot (Web + Worker)"
echo "  3. Déployer Superset"
echo "  4. Tester toutes les applications"
echo ""
echo "Durée estimée : 20-25 minutes"
echo ""

read -p "Continuer la séquence complète ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 1/4 : Diagnostic initial"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

LOG_FILE="$LOG_DIR/diagnostic_superset_${TIMESTAMP}.log"

if [ -f "./diagnostic_superset.sh" ]; then
    echo -e "${INFO} Exécution diagnostic_superset.sh ..."
    ./diagnostic_superset.sh 2>&1 | tee "$LOG_FILE"
    
    echo ""
    echo -e "${OK} Diagnostic terminé (log: $LOG_FILE)"
    echo ""
    
    read -p "Continuer avec le déploiement ? (yes/NO) : " confirm2
    [ "$confirm2" != "yes" ] && { echo "Arrêt après diagnostic"; exit 0; }
else
    echo -e "${WARN} Script diagnostic_superset.sh non trouvé, passage à l'étape suivante"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 2/4 : Déploiement Chatwoot"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

LOG_FILE="$LOG_DIR/deploy_chatwoot_${TIMESTAMP}.log"

if [ -f "./18_deploy_chatwoot_daemonset_FIXED.sh" ]; then
    echo -e "${INFO} Exécution 18_deploy_chatwoot_daemonset_FIXED.sh ..."
    echo ""
    
    # Lancer le script en mode non-interactif
    echo "yes" | ./18_deploy_chatwoot_daemonset_FIXED.sh 2>&1 | tee "$LOG_FILE"
    
    if [ ${PIPESTATUS[1]} -eq 0 ]; then
        echo ""
        echo -e "${OK} Chatwoot déployé avec succès (log: $LOG_FILE)"
    else
        echo ""
        echo -e "${KO} Erreur lors du déploiement Chatwoot"
        echo "Consulter le log : $LOG_FILE"
        
        read -p "Continuer malgré l'erreur ? (yes/NO) : " confirm3
        [ "$confirm3" != "yes" ] && { echo "Arrêt après Chatwoot"; exit 1; }
    fi
else
    echo -e "${KO} Script 18_deploy_chatwoot_daemonset_FIXED.sh non trouvé"
    exit 1
fi

echo ""
echo "Attente stabilisation Chatwoot (60s) ..."
sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 3/4 : Déploiement Superset"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

LOG_FILE="$LOG_DIR/deploy_superset_${TIMESTAMP}.log"

if [ -f "./17_deploy_superset_daemonset_FIXED.sh" ]; then
    echo -e "${INFO} Exécution 17_deploy_superset_daemonset_FIXED.sh ..."
    echo ""
    
    # Lancer le script en mode non-interactif
    echo "yes" | ./17_deploy_superset_daemonset_FIXED.sh 2>&1 | tee "$LOG_FILE"
    
    if [ ${PIPESTATUS[1]} -eq 0 ]; then
        echo ""
        echo -e "${OK} Superset déployé avec succès (log: $LOG_FILE)"
    else
        echo ""
        echo -e "${KO} Erreur lors du déploiement Superset"
        echo "Consulter le log : $LOG_FILE"
        
        read -p "Continuer vers les tests ? (yes/NO) : " confirm4
        [ "$confirm4" != "yes" ] && { echo "Arrêt après Superset"; exit 1; }
    fi
else
    echo -e "${KO} Script 17_deploy_superset_daemonset_FIXED.sh non trouvé"
    exit 1
fi

echo ""
echo "Attente stabilisation Superset (60s) ..."
sleep 60

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAPE 4/4 : Tests complets"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

LOG_FILE="$LOG_DIR/test_all_apps_${TIMESTAMP}.log"

if [ -f "./19_test_all_apps.sh" ]; then
    echo -e "${INFO} Exécution 19_test_all_apps.sh ..."
    echo ""
    
    ./19_test_all_apps.sh 2>&1 | tee "$LOG_FILE"
    
    echo ""
    echo -e "${OK} Tests terminés (log: $LOG_FILE)"
else
    echo -e "${WARN} Script 19_test_all_apps.sh non trouvé"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "SÉQUENCE TERMINÉE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Logs générés :"
echo "  → Diagnostic : $LOG_DIR/diagnostic_superset_${TIMESTAMP}.log"
echo "  → Chatwoot   : $LOG_DIR/deploy_chatwoot_${TIMESTAMP}.log"
echo "  → Superset   : $LOG_DIR/deploy_superset_${TIMESTAMP}.log"
echo "  → Tests      : $LOG_DIR/test_all_apps_${TIMESTAMP}.log"
echo ""
echo "Applications déployées :"
echo "  ✅ n8n       : http://n8n.keybuzz.io"
echo "  ✅ LiteLLM   : http://llm.keybuzz.io"
echo "  ✅ Qdrant    : http://qdrant.keybuzz.io"
echo "  ✅ Chatwoot  : http://chat.keybuzz.io"
echo "  ✅ Superset  : http://superset.keybuzz.io"
echo ""
echo "Credentials Superset :"
echo "  Username : admin"
echo "  Password : Admin123!"
echo "  Email    : admin@keybuzz.io"
echo ""
echo "Chatwoot :"
echo "  → Premier compte créé = admin automatiquement"
echo "  → Ouvrir http://chat.keybuzz.io pour setup initial"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "${OK} DÉPLOIEMENT RÉUSSI !"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
