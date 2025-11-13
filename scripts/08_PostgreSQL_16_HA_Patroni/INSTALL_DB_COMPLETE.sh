#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                                                                    ║"
echo "║       KEYBUZZ - INSTALLATION COMPLÈTE INFRASTRUCTURE DB            ║"
echo "║                                                                    ║"
echo "║  PostgreSQL 16 + Patroni RAFT + HAProxy + PgBouncer + Keepalived  ║"
echo "║                                                                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Vérifications préalables
if [ "$EUID" -ne 0 ]; then
    echo -e "$KO Ce script doit être exécuté en root"
    exit 1
fi

if [ ! -f "/opt/keybuzz-installer/inventory/servers.tsv" ]; then
    echo -e "$KO Fichier servers.tsv introuvable"
    exit 1
fi

# Créer les répertoires nécessaires
mkdir -p /opt/keybuzz-installer/{logs,credentials}
mkdir -p /opt/keybuzz/{postgres,haproxy,pgbouncer}/{data,config,logs,status}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_MASTER="/opt/keybuzz-installer/logs/install_master_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_MASTER") 2>&1

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Installation Master Log: $LOG_MASTER"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Variables de contrôle
SKIP_CLEAN=false
SKIP_TESTS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-clean) SKIP_CLEAN=true; shift ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-clean    Sauter le nettoyage initial"
            echo "  --skip-tests    Sauter les tests finaux"
            echo "  --help          Afficher cette aide"
            exit 0
            ;;
        *) shift ;;
    esac
done

echo "Configuration:"
echo "  • Nettoyage initial: $([[ $SKIP_CLEAN == true ]] && echo 'NON' || echo 'OUI')"
echo "  • Tests finaux: $([[ $SKIP_TESTS == true ]] && echo 'NON' || echo 'OUI')"
echo ""

# Fonction pour exécuter un script
run_script() {
    local script="$1"
    local description="$2"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  ÉTAPE: $description"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "$script" ]; then
        echo -e "$KO Script introuvable: $script"
        return 1
    fi
    
    chmod +x "$script"
    
    if bash "$script"; then
        echo ""
        echo -e "$OK $description - TERMINÉ"
        return 0
    else
        echo ""
        echo -e "$KO $description - ÉCHEC"
        return 1
    fi
}

# Début de l'installation
START_TIME=$(date +%s)

echo ""
echo "🚀 DÉBUT DE L'INSTALLATION"
echo "   $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Étape 1: Préparation des volumes (déjà fait via 02_db_prep_storage.sh)
echo "═══ Étape 1: Vérification des volumes ═══"
echo ""
echo "Les volumes doivent avoir été préparés avec:"
echo "  ./02_db_prep_storage.sh --host db-master-01"
echo "  ./02_db_prep_storage.sh --host db-slave-01"
echo "  ./02_db_prep_storage.sh --host db-slave-02"
echo ""
read -p "Les volumes sont-ils préparés? (yes/NO): " volumes_ready
if [ "$volumes_ready" != "yes" ]; then
    echo -e "$KO Veuillez d'abord préparer les volumes"
    exit 1
fi

# Étape 2: Nettoyage (optionnel)
if [ "$SKIP_CLEAN" = false ]; then
    if ! run_script "$SCRIPTS_DIR/03_db_clean_reset.sh" "Nettoyage des nœuds DB"; then
        echo -e "$WARN Nettoyage échoué, mais on continue..."
    fi
else
    echo "Nettoyage initial sauté (--skip-clean)"
fi

# Étape 3: PostgreSQL 16 + Patroni RAFT
if ! run_script "$SCRIPTS_DIR/04_postgres16_patroni_raft.sh" "PostgreSQL 16 + Patroni RAFT"; then
    echo -e "$KO Installation PostgreSQL échouée"
    exit 1
fi

# Pause pour stabilisation
echo ""
echo "⏸️  Pause de stabilisation (15 secondes)..."
sleep 15

# Étape 4: HAProxy
if ! run_script "$SCRIPTS_DIR/05_haproxy_db.sh" "HAProxy avec détection Patroni"; then
    echo -e "$KO Installation HAProxy échouée"
    exit 1
fi

# Pause
echo ""
echo "⏸️  Pause de stabilisation (10 secondes)..."
sleep 10

# Étape 5: Keepalived
if ! run_script "$SCRIPTS_DIR/06_keepalived_vip.sh" "Keepalived pour VIP"; then
    echo -e "$WARN Installation Keepalived échouée, mais on continue..."
fi

# Pause
echo ""
echo "⏸️  Pause de stabilisation (10 secondes)..."
sleep 10

# Étape 6: PgBouncer
if ! run_script "$SCRIPTS_DIR/07_pgbouncer_scram.sh" "PgBouncer avec SCRAM"; then
    echo -e "$KO Installation PgBouncer échouée"
    exit 1
fi

# Pause
echo ""
echo "⏸️  Pause de stabilisation (10 secondes)..."
sleep 10

# Étape 7: Tests (optionnel)
if [ "$SKIP_TESTS" = false ]; then
    if ! run_script "$SCRIPTS_DIR/08_test_infrastructure.sh" "Tests de l'infrastructure"; then
        echo -e "$WARN Tests échoués, mais l'infrastructure peut être opérationnelle"
    fi
else
    echo "Tests finaux sautés (--skip-tests)"
fi

# Fin de l'installation
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK INSTALLATION COMPLÈTE TERMINÉE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Durée totale: ${MINUTES}m ${SECONDS}s"
echo "Date de fin: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "📁 Fichiers importants:"
echo "  • Credentials: /opt/keybuzz-installer/credentials/postgres.env"
echo "  • Résumé: /opt/keybuzz-installer/credentials/data-layer-summary.txt"
echo "  • Log master: $LOG_MASTER"
echo ""
echo "🔗 Points d'accès:"
echo "  • VIP: postgresql://postgres:****@10.0.0.10:6432/keybuzz"
echo "  • HAProxy Stats: http://10.0.0.11:8404/stats"
echo "  • Patroni API: http://10.0.0.120:8008/cluster"
echo ""
echo "📚 Documentation:"
echo "  • Lire le README_DB_INSTALLATION.md pour plus de détails"
echo "  • Tests de failover: ./test_failover.sh"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
