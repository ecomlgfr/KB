#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        KEYBUZZ K3S + APPS - ORCHESTRATEUR DE DÉPLOIEMENT          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

BASE_DIR="/opt/keybuzz-installer"
SCRIPTS_DIR="${BASE_DIR}/scripts"
LOGS_DIR="${BASE_DIR}/logs"
LOGFILE="${LOGS_DIR}/orchestrator.log"

mkdir -p "$LOGS_DIR"

exec > >(tee -a "$LOGFILE") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Début orchestration déploiement K3s + Apps"
echo ""

# Fonction pour exécuter un script
run_script() {
    local SCRIPT_PATH="$1"
    local SCRIPT_NAME=$(basename "$SCRIPT_PATH")
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  EXÉCUTION : $SCRIPT_NAME"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        echo -e "$KO Script introuvable : $SCRIPT_PATH"
        return 1
    fi
    
    chmod +x "$SCRIPT_PATH"
    
    START_TIME=$(date +%s)
    
    if bash "$SCRIPT_PATH"; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        echo ""
        echo -e "$OK $SCRIPT_NAME terminé avec succès (durée: ${DURATION}s)"
        return 0
    else
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        echo ""
        echo -e "$KO $SCRIPT_NAME a échoué (durée: ${DURATION}s)"
        return 1
    fi
}

# Fonction pour demander confirmation
confirm() {
    local PROMPT="$1"
    read -p "$PROMPT [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Menu principal
echo "OPTIONS DE DÉPLOIEMENT :"
echo ""
echo "1. Déploiement COMPLET (tous les scripts)"
echo "2. Déploiement K3s uniquement (masters + workers + addons)"
echo "3. Déploiement Apps uniquement (prépare + deploy + tests)"
echo "4. Exécution script spécifique"
echo "5. Tests uniquement"
echo ""
read -p "Choix [1-5] : " CHOICE

case $CHOICE in
    1)
        echo ""
        echo "═══ DÉPLOIEMENT COMPLET SÉLECTIONNÉ ═══"
        echo ""
        echo "Séquence complète :"
        echo "  1. k3s_ha_install.sh (masters)"
        echo "  2. k3s_workers_join.sh (workers)"
        echo "  3. k3s_bootstrap_addons.sh (addons)"
        echo "  4. apps_prepare_env.sh (secrets + DB)"
        echo "  5. apps_helm_deploy.sh (applications)"
        echo "  6. 08_test_full_stack.sh (tests)"
        echo ""
        
        if ! confirm "Continuer ?"; then
            echo "Annulé"
            exit 0
        fi
        
        # Vérification prérequis
        echo ""
        echo "═══ Vérification prérequis ═══"
        
        if [[ ! -f "${BASE_DIR}/inventory/servers.tsv" ]]; then
            echo -e "$KO servers.tsv introuvable"
            exit 1
        fi
        
        if [[ ! -f "${BASE_DIR}/credentials/postgres.env" ]]; then
            echo -e "$WARN postgres.env introuvable - data-plane non déployé ?"
            if ! confirm "Continuer quand même ?"; then
                exit 1
            fi
        fi
        
        # Exécution séquence complète
        TOTAL_START=$(date +%s)
        
        run_script "${SCRIPTS_DIR}/k3s_ha_install.sh" || exit 1
        sleep 5
        
        run_script "${SCRIPTS_DIR}/k3s_workers_join.sh" || exit 1
        sleep 5
        
        run_script "${SCRIPTS_DIR}/k3s_bootstrap_addons.sh" || exit 1
        sleep 5
        
        run_script "${SCRIPTS_DIR}/apps_prepare_env.sh" || exit 1
        sleep 5
        
        run_script "${SCRIPTS_DIR}/apps_helm_deploy.sh" || exit 1
        sleep 5
        
        run_script "${SCRIPTS_DIR}/08_test_full_stack.sh"
        TEST_EXIT=$?
        
        TOTAL_END=$(date +%s)
        TOTAL_DURATION=$((TOTAL_END - TOTAL_START))
        TOTAL_MINUTES=$((TOTAL_DURATION / 60))
        TOTAL_SECONDS=$((TOTAL_DURATION % 60))
        
        echo ""
        echo "╔════════════════════════════════════════════════════════════════════╗"
        echo "║               DÉPLOIEMENT COMPLET TERMINÉ                          ║"
        echo "╚════════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Durée totale : ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
        echo ""
        
        if [[ $TEST_EXIT -eq 0 ]]; then
            echo -e "$OK Tous les tests ont réussi - GO PRODUCTION"
        else
            echo -e "$KO Certains tests ont échoué - NO-GO PRODUCTION"
        fi
        
        echo ""
        echo "Résumé complet : ${BASE_DIR}/credentials/app-stack-summary.txt"
        ;;
        
    2)
        echo ""
        echo "═══ DÉPLOIEMENT K3s UNIQUEMENT ═══"
        
        if ! confirm "Continuer ?"; then
            exit 0
        fi
        
        run_script "${SCRIPTS_DIR}/k3s_ha_install.sh" || exit 1
        sleep 5
        run_script "${SCRIPTS_DIR}/k3s_workers_join.sh" || exit 1
        sleep 5
        run_script "${SCRIPTS_DIR}/k3s_bootstrap_addons.sh" || exit 1
        
        echo ""
        echo -e "$OK K3s déployé avec succès"
        ;;
        
    3)
        echo ""
        echo "═══ DÉPLOIEMENT APPS UNIQUEMENT ═══"
        
        # Vérifier que K3s est présent
        if ! kubectl get nodes &>/dev/null; then
            echo -e "$KO Cluster K3s non accessible"
            echo "Déployer d'abord K3s avec l'option 2"
            exit 1
        fi
        
        if ! confirm "Continuer ?"; then
            exit 0
        fi
        
        run_script "${SCRIPTS_DIR}/apps_prepare_env.sh" || exit 1
        sleep 5
        run_script "${SCRIPTS_DIR}/apps_helm_deploy.sh" || exit 1
        sleep 5
        run_script "${SCRIPTS_DIR}/08_test_full_stack.sh"
        
        echo ""
        echo -e "$OK Apps déployées"
        ;;
        
    4)
        echo ""
        echo "═══ SCRIPTS DISPONIBLES ═══"
        echo ""
        
        SCRIPTS=(
            "${SCRIPTS_DIR}/k3s_ha_install.sh"
            "${SCRIPTS_DIR}/k3s_workers_join.sh"
            "${SCRIPTS_DIR}/k3s_bootstrap_addons.sh"
            "${SCRIPTS_DIR}/apps_prepare_env.sh"
            "${SCRIPTS_DIR}/apps_helm_deploy.sh"
            "${SCRIPTS_DIR}/08_test_full_stack.sh"
        )
        
        for i in "${!SCRIPTS[@]}"; do
            echo "$((i+1)). $(basename "${SCRIPTS[$i]}")"
        done
        
        echo ""
        read -p "Sélectionner un script [1-${#SCRIPTS[@]}] : " SCRIPT_CHOICE
        
        if [[ "$SCRIPT_CHOICE" =~ ^[0-9]+$ ]] && [[ "$SCRIPT_CHOICE" -ge 1 ]] && [[ "$SCRIPT_CHOICE" -le ${#SCRIPTS[@]} ]]; then
            SELECTED_SCRIPT="${SCRIPTS[$((SCRIPT_CHOICE-1))]}"
            run_script "$SELECTED_SCRIPT"
        else
            echo -e "$KO Choix invalide"
            exit 1
        fi
        ;;
        
    5)
        echo ""
        echo "═══ TESTS UNIQUEMENT ═══"
        
        if ! kubectl get nodes &>/dev/null; then
            echo -e "$KO Cluster K3s non accessible"
            exit 1
        fi
        
        if ! confirm "Lancer les tests ?"; then
            exit 0
        fi
        
        run_script "${SCRIPTS_DIR}/08_test_full_stack.sh"
        ;;
        
    *)
        echo -e "$KO Choix invalide"
        exit 1
        ;;
esac

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Orchestration terminée"
echo ""
echo "Logs détaillés : $LOGFILE"
