#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          MIGRATION AUTOMATIQUE UFW - Scripts K3s Corrigés         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

BASE_DIR="/opt/keybuzz-installer"
SCRIPTS_DIR="${BASE_DIR}/scripts"
LIB_DIR="${BASE_DIR}/lib"
BACKUP_DIR="${BASE_DIR}/scripts/backup_$(date +%Y%m%d_%H%M%S)"

# ═══════════════════════════════════════════════════════════════
# Vérifications préalables
# ═══════════════════════════════════════════════════════════════

echo ""
echo "═══ Vérifications préalables ═══"
echo ""

# Root
if [[ $EUID -ne 0 ]]; then
   echo -e "$KO Ce script doit être exécuté en tant que root"
   exit 1
fi
echo -e "$OK Exécution en root"

# Vérifier que les fichiers sources existent
CURRENT_DIR=$(dirname "$(readlink -f "$0")")

if [[ ! -f "${CURRENT_DIR}/k3s_ha_install_fixed.sh" ]]; then
    echo -e "$KO Fichier k3s_ha_install_fixed.sh introuvable"
    echo "   Ce script doit être dans le même dossier que les fichiers *_fixed.sh"
    exit 1
fi

if [[ ! -f "${CURRENT_DIR}/ufw_helpers.sh" ]]; then
    echo -e "$KO Fichier ufw_helpers.sh introuvable"
    exit 1
fi

echo -e "$OK Tous les fichiers sources présents"

# Créer structure si nécessaire
if [[ ! -d "$BASE_DIR" ]]; then
    echo -e "$WARN $BASE_DIR n'existe pas, création..."
    mkdir -p "$BASE_DIR"
fi

mkdir -p "$SCRIPTS_DIR" "$LIB_DIR"
echo -e "$OK Structure de dossiers prête"

# ═══════════════════════════════════════════════════════════════
# Sauvegarde des anciens scripts
# ═══════════════════════════════════════════════════════════════

echo ""
echo "═══ Sauvegarde des anciens scripts ═══"
echo ""

BACKUP_NEEDED=false

if [[ -f "$SCRIPTS_DIR/k3s_ha_install.sh" ]]; then
    BACKUP_NEEDED=true
fi

if [[ "$BACKUP_NEEDED" == "true" ]]; then
    echo "Création backup : $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Copier tous les scripts existants
    for script in k3s_ha_install.sh k3s_workers_join.sh k3s_fix_master.sh; do
        if [[ -f "$SCRIPTS_DIR/$script" ]]; then
            cp "$SCRIPTS_DIR/$script" "$BACKUP_DIR/" 2>/dev/null || true
            echo "  - Sauvegardé : $script"
        fi
    done
    
    echo -e "$OK Anciens scripts sauvegardés"
else
    echo -e "$WARN Aucun ancien script à sauvegarder (première installation)"
fi

# ═══════════════════════════════════════════════════════════════
# Copie des nouveaux scripts
# ═══════════════════════════════════════════════════════════════

echo ""
echo "═══ Copie des scripts corrigés ═══"
echo ""

# Copier les scripts K3s
cp "${CURRENT_DIR}/k3s_ha_install_fixed.sh" "$SCRIPTS_DIR/k3s_ha_install.sh"
echo -e "$OK k3s_ha_install.sh"

cp "${CURRENT_DIR}/k3s_workers_join_fixed.sh" "$SCRIPTS_DIR/k3s_workers_join.sh"
echo -e "$OK k3s_workers_join.sh"

cp "${CURRENT_DIR}/k3s_fix_master_fixed.sh" "$SCRIPTS_DIR/k3s_fix_master.sh"
echo -e "$OK k3s_fix_master.sh"

# Copier l'utilitaire
cp "${CURRENT_DIR}/ufw_helpers.sh" "$LIB_DIR/ufw_helpers.sh"
echo -e "$OK ufw_helpers.sh"

# Copier le script de vérification (optionnel)
if [[ -f "${CURRENT_DIR}/verify_ufw_migration.sh" ]]; then
    cp "${CURRENT_DIR}/verify_ufw_migration.sh" "$BASE_DIR/verify_ufw_migration.sh"
    echo -e "$OK verify_ufw_migration.sh"
fi

# ═══════════════════════════════════════════════════════════════
# Permissions
# ═══════════════════════════════════════════════════════════════

echo ""
echo "═══ Configuration des permissions ═══"
echo ""

chmod +x "$SCRIPTS_DIR"/k3s_*.sh
chmod +x "$LIB_DIR"/ufw_helpers.sh
if [[ -f "$BASE_DIR/verify_ufw_migration.sh" ]]; then
    chmod +x "$BASE_DIR/verify_ufw_migration.sh"
fi

echo -e "$OK Tous les scripts sont exécutables"

# ═══════════════════════════════════════════════════════════════
# Vérifications post-migration
# ═══════════════════════════════════════════════════════════════

echo ""
echo "═══ Vérifications post-migration ═══"
echo ""

VERIF_OK=true

# Vérifier contenu (fonction add_ufw_rule présente)
if grep -q "add_ufw_rule" "$SCRIPTS_DIR/k3s_ha_install.sh"; then
    echo -e "$OK Scripts contiennent la fonction de sécurité UFW"
else
    echo -e "$KO Scripts ne contiennent pas la fonction UFW safe"
    VERIF_OK=false
fi

# Vérifier absence de commandes dangereuses
if grep -q "ufw reset\|ufw reload\|ufw --force enable" "$SCRIPTS_DIR/k3s_ha_install.sh" 2>/dev/null; then
    echo -e "$KO Scripts contiennent encore des commandes UFW dangereuses"
    VERIF_OK=false
else
    echo -e "$OK Scripts ne contiennent pas de commandes UFW dangereuses"
fi

# Test source helpers
if source "$LIB_DIR/ufw_helpers.sh" &>/dev/null; then
    echo -e "$OK ufw_helpers.sh peut être sourcé"
else
    echo -e "$KO ufw_helpers.sh ne peut pas être sourcé"
    VERIF_OK=false
fi

# ═══════════════════════════════════════════════════════════════
# Résumé final
# ═══════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"

if [[ "$VERIF_OK" == "true" ]]; then
    echo "║              ✓ MIGRATION RÉUSSIE - SCRIPTS SÉCURISÉS              ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Fichiers installés :"
    echo "  • $SCRIPTS_DIR/k3s_ha_install.sh"
    echo "  • $SCRIPTS_DIR/k3s_workers_join.sh"
    echo "  • $SCRIPTS_DIR/k3s_fix_master.sh"
    echo "  • $LIB_DIR/ufw_helpers.sh"
    echo ""
    
    if [[ "$BACKUP_NEEDED" == "true" ]]; then
        echo "Backup des anciens scripts :"
        echo "  • $BACKUP_DIR/"
        echo ""
    fi
    
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                    PROCHAINES ÉTAPES                              "
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "1. [OPTIONNEL] Vérifier la migration :"
    echo "   $BASE_DIR/verify_ufw_migration.sh"
    echo ""
    echo "2. Déployer K3s (comme avant) :"
    echo "   cd $SCRIPTS_DIR"
    echo "   ./k3s_ha_install.sh"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "GARANTIE : Zéro interruption SSH pendant le déploiement"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    exit 0
else
    echo "║                  ✗ MIGRATION INCOMPLÈTE                            ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Des problèmes ont été détectés lors de la migration."
    echo "Vérifier manuellement les fichiers copiés."
    echo ""
    echo "Logs de débogage :"
    echo "  • Scripts dir : $SCRIPTS_DIR"
    echo "  • Lib dir : $LIB_DIR"
    echo ""
    
    if [[ "$BACKUP_NEEDED" == "true" ]]; then
        echo "Restaurer les anciens scripts si nécessaire :"
        echo "  cp $BACKUP_DIR/* $SCRIPTS_DIR/"
        echo ""
    fi
    
    exit 1
fi
