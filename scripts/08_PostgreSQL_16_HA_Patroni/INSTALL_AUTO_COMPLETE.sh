#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   INSTALLATION AUTOMATIQUE - PostgreSQL 16 HA Complete Stack      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SCRIPT_DIR="/opt/keybuzz-installer/scripts/08_PostgreSQL_16_HA_Patroni"

echo ""
echo "Ce script va installer automatiquement :"
echo "  1. HAProxy avec API Patroni (haproxy-01, haproxy-02)"
echo "  2. PgBouncer avec SCRAM-SHA-256"
echo "  3. Tests complets de l'infrastructure"
echo ""

# Vérifier que nous sommes dans le bon répertoire
if [ ! -d "$SCRIPT_DIR" ]; then
    echo -e "$KO Répertoire $SCRIPT_DIR introuvable"
    exit 1
fi

cd "$SCRIPT_DIR" || exit 1

# Vérifier que les scripts sont présents
MISSING=0

for SCRIPT in "05_haproxy_patroni_FINAL.sh" "06_pgbouncer_scram_FINAL.sh" "07_test_infrastructure_FINAL.sh"; do
    if [ ! -f "$SCRIPT" ]; then
        echo -e "$KO Script manquant: $SCRIPT"
        ((MISSING++))
    fi
done

if [ $MISSING -gt 0 ]; then
    echo ""
    echo "⚠  $MISSING script(s) manquant(s)"
    echo ""
    echo "Les scripts doivent être copiés depuis /mnt/user-data/outputs/ vers $SCRIPT_DIR"
    echo ""
    echo "Commandes pour copier :"
    echo "  cp /mnt/user-data/outputs/05_haproxy_patroni_FINAL.sh $SCRIPT_DIR/"
    echo "  cp /mnt/user-data/outputs/06_pgbouncer_scram_FINAL.sh $SCRIPT_DIR/"
    echo "  cp /mnt/user-data/outputs/07_test_infrastructure_FINAL.sh $SCRIPT_DIR/"
    echo ""
    exit 1
fi

# Rendre tous les scripts exécutables
chmod +x 05_haproxy_patroni_FINAL.sh
chmod +x 06_pgbouncer_scram_FINAL.sh
chmod +x 07_test_infrastructure_FINAL.sh

echo -e "$OK Tous les scripts sont présents"
echo ""

# Vérifier que Patroni est opérationnel
echo "→ Vérification préalable du cluster Patroni..."
SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_MASTER_IP=$(awk -F'\t' '$2=="db-master-01" {print $3}' "$SERVERS_TSV")

if ! curl -sf "http://${DB_MASTER_IP}:8008/" >/dev/null 2>&1; then
    echo -e "$KO Patroni API non accessible sur $DB_MASTER_IP:8008"
    echo ""
    echo "Patroni doit être opérationnel avant d'installer HAProxy."
    echo "Vérifiez: curl http://${DB_MASTER_IP}:8008/cluster"
    exit 1
fi

CLUSTER_SIZE=$(curl -s "http://${DB_MASTER_IP}:8008/cluster" | grep -o '"members"' | wc -l)
if [ "$CLUSTER_SIZE" -lt 1 ]; then
    echo -e "$KO Cluster Patroni non opérationnel"
    exit 1
fi

echo -e "  $OK Cluster Patroni opérationnel"
echo ""

read -p "Continuer l'installation automatique? (yes/NO): " CONFIRM
[ "$CONFIRM" != "yes" ] && { echo "Installation annulée"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "                    DÉBUT DE L'INSTALLATION"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ============================================================================
# ÉTAPE 1 : HAProxy
# ============================================================================

echo "▓▓▓ ÉTAPE 1/3 : Installation HAProxy ▓▓▓"
echo ""

if bash 05_haproxy_patroni_FINAL.sh; then
    echo ""
    echo -e "$OK HAProxy installé avec succès"
else
    echo ""
    echo -e "$KO Échec installation HAProxy"
    echo ""
    echo "Vérifiez les logs dans /opt/keybuzz-installer/logs/"
    exit 1
fi

echo ""
echo "  ⏳ Pause 10 secondes avant PgBouncer..."
sleep 10

# ============================================================================
# ÉTAPE 2 : PgBouncer
# ============================================================================

echo ""
echo "▓▓▓ ÉTAPE 2/3 : Installation PgBouncer ▓▓▓"
echo ""

if bash 06_pgbouncer_scram_FINAL.sh; then
    echo ""
    echo -e "$OK PgBouncer installé avec succès"
else
    echo ""
    echo -e "$KO Échec installation PgBouncer"
    echo ""
    echo "Vérifiez les logs dans /opt/keybuzz-installer/logs/"
    exit 1
fi

echo ""
echo "  ⏳ Pause 10 secondes avant les tests..."
sleep 10

# ============================================================================
# ÉTAPE 3 : Tests
# ============================================================================

echo ""
echo "▓▓▓ ÉTAPE 3/3 : Tests complets ▓▓▓"
echo ""

if bash 07_test_infrastructure_FINAL.sh; then
    echo ""
    echo -e "$OK Tests terminés"
else
    echo ""
    echo -e "$WARN Certains tests ont échoué"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "                    FIN DE L'INSTALLATION"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Résumé des services
echo "📊 SERVICES INSTALLÉS:"
echo ""
echo "  ✓ HAProxy (haproxy-01, haproxy-02)"
echo "    • Write: port 5432"
echo "    • Read: port 5433"
echo "    • Stats: port 8404"
echo ""
echo "  ✓ PgBouncer (sur les 2 proxies)"
echo "    • Pool: port 6432"
echo "    • Auth: SCRAM-SHA-256"
echo ""
echo "  ✓ Patroni Cluster (détection automatique)"
echo "    • API: port 8008"
echo "    • RAFT: port 7000"
echo ""

# Prochaines étapes
echo "📋 PROCHAINES ÉTAPES:"
echo ""
echo "  1. Configurer le Load Balancer Hetzner (10.0.0.10)"
echo "     Targets: haproxy-01 (10.0.0.11), haproxy-02 (10.0.0.12)"
echo "     Ports: 5432, 5433, 6432"
echo "     Health Check: TCP sur port 8404"
echo ""
echo "  2. Tester via le Load Balancer:"
echo "     PGPASSWORD='\$POSTGRES_PASSWORD' psql -h 10.0.0.10 -p 6432 -U postgres -d postgres"
echo ""
echo "  3. Créer les databases applicatives:"
echo "     CREATE DATABASE chatwoot;"
echo "     CREATE DATABASE n8n;"
echo "     -- etc."
echo ""
echo "  4. Configurer les applications pour utiliser 10.0.0.10"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "📚 Documentation complète:"
echo "   • Guide de démarrage: GUIDE_DEMARRAGE_RAPIDE.md"
echo "   • Détails techniques: SITUATION_ET_SOLUTION_HAPROXY.md"
echo ""
echo "🎉 Installation PostgreSQL 16 HA terminée avec succès !"
echo ""
