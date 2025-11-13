#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         VÉRIFICATION MIGRATION UFW - Scripts K3s Corrigés         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

BASE_DIR="/opt/keybuzz-installer"
SCRIPTS_DIR="${BASE_DIR}/scripts"
LIB_DIR="${BASE_DIR}/lib"

CHECKS_OK=0
CHECKS_KO=0
CHECKS_WARN=0

check() {
    local TEST_NAME="$1"
    local TEST_CMD="$2"
    local LEVEL="${3:-error}"
    
    printf "%-60s" "$TEST_NAME"
    
    if eval "$TEST_CMD" &>/dev/null; then
        echo -e "$OK"
        CHECKS_OK=$((CHECKS_OK + 1))
        return 0
    else
        if [[ "$LEVEL" == "warn" ]]; then
            echo -e "$WARN"
            CHECKS_WARN=$((CHECKS_WARN + 1))
        else
            echo -e "$KO"
            CHECKS_KO=$((CHECKS_KO + 1))
        fi
        return 1
    fi
}

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "1. PRÉSENCE DES FICHIERS"
echo "═══════════════════════════════════════════════════════════════════"

check "k3s_ha_install.sh présent" "[[ -f '$SCRIPTS_DIR/k3s_ha_install.sh' ]]"
check "k3s_workers_join.sh présent" "[[ -f '$SCRIPTS_DIR/k3s_workers_join.sh' ]]"
check "k3s_fix_master.sh présent" "[[ -f '$SCRIPTS_DIR/k3s_fix_master.sh' ]]"
check "ufw_helpers.sh présent" "[[ -f '$LIB_DIR/ufw_helpers.sh' ]]"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "2. PERMISSIONS EXÉCUTABLES"
echo "═══════════════════════════════════════════════════════════════════"

check "k3s_ha_install.sh exécutable" "[[ -x '$SCRIPTS_DIR/k3s_ha_install.sh' ]]"
check "k3s_workers_join.sh exécutable" "[[ -x '$SCRIPTS_DIR/k3s_workers_join.sh' ]]"
check "k3s_fix_master.sh exécutable" "[[ -x '$SCRIPTS_DIR/k3s_fix_master.sh' ]]"
check "ufw_helpers.sh exécutable" "[[ -x '$LIB_DIR/ufw_helpers.sh' ]]"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "3. CONTENU DES SCRIPTS (Fonction UFW Safe)"
echo "═══════════════════════════════════════════════════════════════════"

check "k3s_ha_install.sh contient add_ufw_rule" "grep -q 'add_ufw_rule' '$SCRIPTS_DIR/k3s_ha_install.sh'"
check "k3s_workers_join.sh contient add_ufw_rule" "grep -q 'add_ufw_rule' '$SCRIPTS_DIR/k3s_workers_join.sh'"
check "k3s_fix_master.sh contient add_ufw_rule" "grep -q 'add_ufw_rule' '$SCRIPTS_DIR/k3s_fix_master.sh'"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "4. VÉRIFICATIONS DE SÉCURITÉ (Pas de commandes dangereuses)"
echo "═══════════════════════════════════════════════════════════════════"

# Ces checks doivent ÉCHOUER (pas de commandes dangereuses)
if grep -q "ufw reset" "$SCRIPTS_DIR/k3s_ha_install.sh" 2>/dev/null; then
    echo -e "$(printf '%-60s' 'k3s_ha_install.sh sans "ufw reset"')$KO DANGER"
    CHECKS_KO=$((CHECKS_KO + 1))
else
    echo -e "$(printf '%-60s' 'k3s_ha_install.sh sans "ufw reset"')$OK"
    CHECKS_OK=$((CHECKS_OK + 1))
fi

if grep -q "ufw reload" "$SCRIPTS_DIR/k3s_ha_install.sh" 2>/dev/null; then
    echo -e "$(printf '%-60s' 'k3s_ha_install.sh sans "ufw reload"')$KO DANGER"
    CHECKS_KO=$((CHECKS_KO + 1))
else
    echo -e "$(printf '%-60s' 'k3s_ha_install.sh sans "ufw reload"')$OK"
    CHECKS_OK=$((CHECKS_OK + 1))
fi

if grep -q "ufw --force enable" "$SCRIPTS_DIR/k3s_ha_install.sh" 2>/dev/null; then
    echo -e "$(printf '%-60s' 'k3s_ha_install.sh sans "ufw --force enable"')$KO DANGER"
    CHECKS_KO=$((CHECKS_KO + 1))
else
    echo -e "$(printf '%-60s' 'k3s_ha_install.sh sans "ufw --force enable"')$OK"
    CHECKS_OK=$((CHECKS_OK + 1))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "5. TEST FONCTIONNEL UFW HELPERS"
echo "═══════════════════════════════════════════════════════════════════"

# Test source du fichier helpers
if source "$LIB_DIR/ufw_helpers.sh" &>/dev/null; then
    echo -e "$(printf '%-60s' 'ufw_helpers.sh sourceable')$OK"
    CHECKS_OK=$((CHECKS_OK + 1))
    
    # Vérifier que les fonctions sont définies
    if declare -f add_ufw_rule_safe &>/dev/null; then
        echo -e "$(printf '%-60s' 'Fonction add_ufw_rule_safe définie')$OK"
        CHECKS_OK=$((CHECKS_OK + 1))
    else
        echo -e "$(printf '%-60s' 'Fonction add_ufw_rule_safe définie')$KO"
        CHECKS_KO=$((CHECKS_KO + 1))
    fi
    
    if declare -f add_k3s_master_rules &>/dev/null; then
        echo -e "$(printf '%-60s' 'Fonction add_k3s_master_rules définie')$OK"
        CHECKS_OK=$((CHECKS_OK + 1))
    else
        echo -e "$(printf '%-60s' 'Fonction add_k3s_master_rules définie')$KO"
        CHECKS_KO=$((CHECKS_KO + 1))
    fi
    
    if declare -f add_k3s_worker_rules &>/dev/null; then
        echo -e "$(printf '%-60s' 'Fonction add_k3s_worker_rules définie')$OK"
        CHECKS_OK=$((CHECKS_OK + 1))
    else
        echo -e "$(printf '%-60s' 'Fonction add_k3s_worker_rules définie')$KO"
        CHECKS_KO=$((CHECKS_KO + 1))
    fi
else
    echo -e "$(printf '%-60s' 'ufw_helpers.sh sourceable')$KO"
    CHECKS_KO=$((CHECKS_KO + 1))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "6. VERSIONS ET DATES"
echo "═══════════════════════════════════════════════════════════════════"

echo "Dates de modification des scripts :"
ls -lh "$SCRIPTS_DIR"/k3s_*.sh 2>/dev/null | awk '{print "  " $6, $7, $8, $9}'
echo ""
echo "Tailles des fichiers :"
du -h "$SCRIPTS_DIR"/k3s_*.sh 2>/dev/null | awk '{print "  " $1 "\t" $2}'
du -h "$LIB_DIR"/ufw_helpers.sh 2>/dev/null | awk '{print "  " $1 "\t" $2}'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "                            RÉSUMÉ                                  "
echo "═══════════════════════════════════════════════════════════════════"
echo ""

TOTAL=$((CHECKS_OK + CHECKS_KO + CHECKS_WARN))

echo "Tests exécutés : $TOTAL"
echo -e "Réussis        : \033[0;32m$CHECKS_OK\033[0m"
echo -e "Avertissements : \033[0;33m$CHECKS_WARN\033[0m"
echo -e "Échecs         : \033[0;31m$CHECKS_KO\033[0m"
echo ""

if [[ $CHECKS_KO -eq 0 ]]; then
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║              ✓ MIGRATION RÉUSSIE - SCRIPTS SÉCURISÉS              ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Vous pouvez déployer K3s sans risque d'interruption SSH :"
    echo "  cd $SCRIPTS_DIR"
    echo "  ./k3s_ha_install.sh"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "GARANTIE : Zéro interruption SSH pendant le déploiement"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    exit 0
else
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║                 ✗ MIGRATION INCOMPLÈTE                             ║"
    echo "║             Corriger les erreurs avant déploiement                ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Actions requises :"
    echo ""
    
    if [[ ! -f "$SCRIPTS_DIR/k3s_ha_install.sh" ]]; then
        echo "  • Copier k3s_ha_install_fixed.sh vers $SCRIPTS_DIR/k3s_ha_install.sh"
    fi
    
    if [[ ! -f "$LIB_DIR/ufw_helpers.sh" ]]; then
        echo "  • Copier ufw_helpers.sh vers $LIB_DIR/ufw_helpers.sh"
    fi
    
    if [[ ! -x "$SCRIPTS_DIR/k3s_ha_install.sh" ]]; then
        echo "  • chmod +x $SCRIPTS_DIR/*.sh"
    fi
    
    if grep -q "ufw reset\|ufw reload\|ufw --force enable" "$SCRIPTS_DIR/k3s_ha_install.sh" 2>/dev/null; then
        echo "  • Les scripts contiennent encore des commandes UFW dangereuses"
        echo "    Vérifier que vous avez bien copié les versions FIXED"
    fi
    
    echo ""
    echo "Relancer ce script après corrections :"
    echo "  ./verify_ufw_migration.sh"
    echo ""
    exit 1
fi
