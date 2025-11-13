#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       INSTALL_TEST_SCRIPTS - Installation des scripts de test      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓ OK\033[0m'
KO='\033[0;31m✗ KO\033[0m'
INFO='\033[0;36mℹ INFO\033[0m'

echo ""
echo "Ce script va installer les scripts de test sur install-01"
echo ""

# Vérifier que nous avons les fichiers nécessaires
REQUIRED_FILES=(
    "test_infrastructure_complete.sh"
    "test_failover_safe.sh"
    "test_performance_load.sh"
    "infrastructure_dashboard.sh"
    "README_TESTS.md"
)

MISSING=0
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo -e "$KO Fichier manquant: $file"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "❌ Certains fichiers sont manquants. Assurez-vous d'avoir tous les scripts."
    exit 1
fi

echo -e "$OK Tous les fichiers nécessaires sont présents"
echo ""

# Demander l'IP de install-01
read -p "Entrez l'IP de install-01 (ou hostname): " INSTALL_01_IP

if [ -z "$INSTALL_01_IP" ]; then
    echo "❌ IP/hostname requis"
    exit 1
fi

echo ""
echo -e "$INFO Test de connexion SSH à $INSTALL_01_IP..."

if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$INSTALL_01_IP" "echo OK" >/dev/null 2>&1; then
    echo -e "$KO Impossible de se connecter à $INSTALL_01_IP"
    echo "   Vérifiez:"
    echo "   - Que l'IP/hostname est correct"
    echo "   - Que vous avez accès SSH avec la clé"
    echo "   - Que le serveur est accessible"
    exit 1
fi

echo -e "$OK Connexion SSH établie"
echo ""

# Créer le répertoire de destination si nécessaire
echo -e "$INFO Création du répertoire /opt/keybuzz-installer/tests..."

ssh root@"$INSTALL_01_IP" "mkdir -p /opt/keybuzz-installer/tests" || {
    echo -e "$KO Impossible de créer le répertoire"
    exit 1
}

echo -e "$OK Répertoire créé"
echo ""

# Copier les scripts
echo -e "$INFO Copie des scripts vers install-01..."
echo ""

for file in "${REQUIRED_FILES[@]}"; do
    echo -n "  Copie de $file... "
    
    if scp -o StrictHostKeyChecking=no "$file" root@"$INSTALL_01_IP":/opt/keybuzz-installer/tests/ >/dev/null 2>&1; then
        echo -e "$OK"
    else
        echo -e "$KO"
        exit 1
    fi
done

echo ""

# Rendre les scripts exécutables
echo -e "$INFO Application des permissions d'exécution..."

ssh root@"$INSTALL_01_IP" "chmod +x /opt/keybuzz-installer/tests/*.sh" || {
    echo -e "$KO Impossible de définir les permissions"
    exit 1
}

echo -e "$OK Permissions appliquées"
echo ""

# Créer des liens symboliques dans /opt/keybuzz-installer
echo -e "$INFO Création de liens symboliques..."

ssh root@"$INSTALL_01_IP" bash <<'EOF'
cd /opt/keybuzz-installer
ln -sf tests/test_infrastructure_complete.sh test_infrastructure_complete.sh
ln -sf tests/test_failover_safe.sh test_failover_safe.sh
ln -sf tests/test_performance_load.sh test_performance_load.sh
ln -sf tests/infrastructure_dashboard.sh infrastructure_dashboard.sh
ln -sf tests/README_TESTS.md README_TESTS.md
EOF

echo -e "$OK Liens symboliques créés"
echo ""

# Vérifier l'installation
echo -e "$INFO Vérification de l'installation..."

INSTALL_OK=$(ssh root@"$INSTALL_01_IP" "ls -la /opt/keybuzz-installer/tests/*.sh 2>/dev/null | wc -l" || echo 0)

if [ "$INSTALL_OK" -eq 4 ]; then
    echo -e "$OK Installation réussie"
else
    echo -e "$KO Problème d'installation (seulement $INSTALL_OK/4 scripts trouvés)"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                   INSTALLATION TERMINÉE                            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ Scripts installés avec succès sur install-01 !"
echo ""
echo "📁 Emplacement: /opt/keybuzz-installer/tests/"
echo ""
echo "Scripts disponibles:"
echo "  • test_infrastructure_complete.sh  - Tests complets sans modification"
echo "  • test_failover_safe.sh            - Tests de failover (SAFE)"
echo "  • test_performance_load.sh         - Tests de charge et performance"
echo "  • infrastructure_dashboard.sh      - Dashboard en temps réel"
echo "  • README_TESTS.md                  - Documentation complète"
echo ""
echo "Pour commencer:"
echo ""
echo "  ssh root@$INSTALL_01_IP"
echo "  cd /opt/keybuzz-installer"
echo "  ./test_infrastructure_complete.sh"
echo ""
echo "Ou pour un dashboard rapide:"
echo ""
echo "  ssh root@$INSTALL_01_IP"
echo "  cd /opt/keybuzz-installer"
echo "  ./infrastructure_dashboard.sh"
echo ""
echo "📖 Consultez README_TESTS.md pour la documentation complète:"
echo "  ssh root@$INSTALL_01_IP"
echo "  cat /opt/keybuzz-installer/README_TESTS.md"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

exit 0
