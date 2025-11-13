#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        Déploiement des scripts K3S Apps sur install-01            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

INSTALL_SERVER="install-01"
REMOTE_DIR="/opt/keybuzz-installer/scripts/k3s-apps"

# Liste des fichiers à déployer
FILES=(
    "00_check_prerequisites.sh"
    "01_fix_ufw_k3s_networks.sh"
    "02_prepare_database.sh"
    "03_prepare_apps_env.sh"
    "README_SEQUENCE_INSTALLATION.md"
)

# Ajouter les scripts uploadés s'ils existent
UPLOADED_FILES=(
    "k3s_cleanup.sh"
    "k3s_ha_install.sh"
    "k3s_workers_join.sh"
    "k3s_bootstrap_addons.sh"
    "apps_helm_deploy.sh"
    "apps_final_tests.sh"
    "create_pg_databases_v2.sh"
    "fix_superset_secret.sh"
)

echo ""
echo "Scripts à déployer :"
echo ""

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        size=$(du -h "$file" | awk '{print $1}')
        echo "  ✓ $file ($size)"
    else
        echo -e "  $KO $file (manquant)"
    fi
done

echo ""
read -p "Déployer sur install-01 ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Déploiement en cours ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Créer le répertoire sur install-01
echo "→ Création du répertoire $REMOTE_DIR sur $INSTALL_SERVER"
ssh root@$INSTALL_SERVER "mkdir -p $REMOTE_DIR"

# Copier les fichiers
for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -n "→ Copie $file ... "
        if scp "$file" root@$INSTALL_SERVER:$REMOTE_DIR/; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    fi
done

# Rendre les scripts exécutables
echo ""
echo "→ Rendre les scripts exécutables"
ssh root@$INSTALL_SERVER "chmod +x $REMOTE_DIR/*.sh"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Déploiement terminé"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Scripts disponibles sur $INSTALL_SERVER:$REMOTE_DIR"
echo ""
echo "Pour lancer l'installation :"
echo ""
echo "  ssh root@$INSTALL_SERVER"
echo "  cd $REMOTE_DIR"
echo "  ./00_check_prerequisites.sh"
echo ""
