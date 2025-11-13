#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  APPLY_ALL_PATCHES - Application complète des correctifs HA        ║"
echo "║                                                                    ║"
echo "║  Corrige les 3 problèmes majeurs identifiés:                      ║"
echo "║  1. Patroni etcd → RAFT (découplage K3s)                          ║"
echo "║  2. HAProxy "dumb" → Patroni-aware (failover auto)                ║"
echo "║  3. PgBouncer natif → Docker pool (homogène)                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PATCHES=(
    "PATCH_01_patroni_to_raft.sh"
    "PATCH_02_haproxy_patroni_aware.sh"
    "PATCH_03_pgbouncer_docker_pool.sh"
)

STEP_DELAY=10

echo ""
echo "Ce script va appliquer 3 patches successifs avec ${STEP_DELAY}s de délai."
echo ""
echo "Patches à appliquer:"
echo "  1. PATCH_01_patroni_to_raft.sh"
echo "     → Conversion Patroni de etcd vers RAFT natif"
echo "     → Suppression etcd Docker sur k3s-masters"
echo "     → Ouverture port 7000/tcp pour RAFT"
echo "     → Redémarrage cluster en mode RAFT"
echo ""
echo "  2. PATCH_02_haproxy_patroni_aware.sh"
echo "     → Reconfiguration HAProxy avec checks HTTP Patroni"
echo "     → :5432 suit automatiquement le master"
echo "     → :5433 balance sur les replicas actifs"
echo "     → Stats sécurisées avec authentification"
echo ""
echo "  3. PATCH_03_pgbouncer_docker_pool.sh"
echo "     → Suppression PgBouncer natif (package)"
echo "     → Installation PgBouncer Docker"
echo "     → Pooling vers HAProxy local (127.0.0.1:5432)"
echo "     → Auth SCRAM-SHA-256"
echo ""

# Vérifier que les patches existent
echo "Vérification des patches..."
ALL_FOUND=true
for patch in "${PATCHES[@]}"; do
    if [ -f "$SCRIPT_DIR/$patch" ]; then
        echo -e "  $OK $patch"
    else
        echo -e "  $KO $patch manquant"
        ALL_FOUND=false
    fi
done

if [ "$ALL_FOUND" = "false" ]; then
    echo ""
    echo -e "$KO Certains patches sont manquants"
    exit 1
fi

echo ""
echo "Prérequis:"
echo "  ✓ PostgreSQL/Patroni installé (avec etcd actuellement)"
echo "  ✓ HAProxy installé sur haproxy-01/02"
echo "  ✓ PgBouncer installé (natif ou Docker)"
echo "  ✓ Credentials dans /opt/keybuzz-installer/credentials/"
echo ""

# Vérifier les credentials
if [ ! -f /opt/keybuzz-installer/credentials/postgres.env ]; then
    echo -e "$KO Credentials postgres.env introuvables"
    echo "Lancez d'abord: ./02_postgres_patroni_pgvector.sh"
    exit 1
fi

echo -e "$OK Credentials trouvés"
echo ""

echo "⚠️  AVERTISSEMENT:"
echo "  • Les patches vont redémarrer Patroni (downtime ~1-2min)"
echo "  • Les connexions actives seront coupées"
echo "  • HAProxy et PgBouncer seront reconfigurés"
echo "  • Assurez-vous qu'aucune charge critique n'est en cours"
echo ""

read -p "Continuer avec l'application des patches? (y/N) " -r
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "DÉBUT DE L'APPLICATION DES PATCHES"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Timestamp de début
START_TIME=$(date +%s)

# ============================================================================
# PATCH 1: Patroni → RAFT
# ============================================================================
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                    PATCH 1/3: Patroni → RAFT                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

bash "$SCRIPT_DIR/PATCH_01_patroni_to_raft.sh"
PATCH1_STATUS=$?

if [ $PATCH1_STATUS -ne 0 ]; then
    echo ""
    echo -e "$KO Patch 1 échoué (code: $PATCH1_STATUS)"
    echo ""
    echo "Le cluster Patroni n'a pas pu être converti en RAFT."
    echo "Vérifiez les logs et relancez le patch individuellement."
    exit 1
fi

echo ""
echo -e "$OK Patch 1 terminé avec succès"
echo ""
echo "Attente ${STEP_DELAY}s avant patch 2..."
sleep $STEP_DELAY

# ============================================================================
# PATCH 2: HAProxy Patroni-aware
# ============================================================================
echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              PATCH 2/3: HAProxy Patroni-aware                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

bash "$SCRIPT_DIR/PATCH_02_haproxy_patroni_aware.sh"
PATCH2_STATUS=$?

if [ $PATCH2_STATUS -ne 0 ]; then
    echo ""
    echo -e "$WARN Patch 2 échoué (code: $PATCH2_STATUS)"
    echo ""
    echo "HAProxy n'a pas pu être reconfiguré."
    echo "Le cluster Patroni RAFT est OK, mais HAProxy n'est pas Patroni-aware."
    echo "Vous pouvez relancer le patch 2 individuellement."
    
    read -p "Continuer quand même avec le patch 3? (y/N) " -r
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo ""
echo -e "$OK Patch 2 terminé avec succès"
echo ""
echo "Attente ${STEP_DELAY}s avant patch 3..."
sleep $STEP_DELAY

# ============================================================================
# PATCH 3: PgBouncer Docker Pool
# ============================================================================
echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           PATCH 3/3: PgBouncer Docker Pool                         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

bash "$SCRIPT_DIR/PATCH_03_pgbouncer_docker_pool.sh"
PATCH3_STATUS=$?

if [ $PATCH3_STATUS -ne 0 ]; then
    echo ""
    echo -e "$WARN Patch 3 échoué (code: $PATCH3_STATUS)"
    echo ""
    echo "PgBouncer Docker n'a pas pu être installé."
    echo "Les patches 1 et 2 sont OK."
    echo "Vous pouvez relancer le patch 3 individuellement."
else
    echo ""
    echo -e "$OK Patch 3 terminé avec succès"
fi

# Timestamp de fin
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              TOUS LES PATCHES APPLIQUÉS                            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

echo "Résumé:"
echo "  Patch 1 (Patroni → RAFT):        $([ $PATCH1_STATUS -eq 0 ] && echo -e "$OK" || echo -e "$KO")"
echo "  Patch 2 (HAProxy Patroni-aware): $([ $PATCH2_STATUS -eq 0 ] && echo -e "$OK" || echo -e "$KO")"
echo "  Patch 3 (PgBouncer Docker Pool): $([ $PATCH3_STATUS -eq 0 ] && echo -e "$OK" || echo -e "$KO")"
echo ""
echo "Durée totale: ${MINUTES}m ${SECONDS}s"
echo ""

echo "Architecture finale:"
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║         Application / Clients            ║"
echo "  ╚══════════════════════════════════════════╝"
echo "                    ↓"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Load Balancer Hetzner 10.0.0.10:4632  ║"
echo "  ║         (à configurer manuellement)      ║"
echo "  ╚══════════════════════════════════════════╝"
echo "          ↓                    ↓"
echo "  ╔════════════════╗    ╔════════════════╗"
echo "  ║  haproxy-01    ║    ║  haproxy-02    ║"
echo "  ║  PgBouncer     ║    ║  PgBouncer     ║"
echo "  ║  :6432 (pool)  ║    ║  :6432 (pool)  ║"
echo "  ╚════════════════╝    ╚════════════════╝"
echo "          ↓                    ↓"
echo "      127.0.0.1:5432      127.0.0.1:5432"
echo "          ↓                    ↓"
echo "  ╔════════════════╗    ╔════════════════╗"
echo "  ║  HAProxy       ║    ║  HAProxy       ║"
echo "  ║  :5432 (write) ║    ║  :5432 (write) ║"
echo "  ║  :5433 (read)  ║    ║  :5433 (read)  ║"
echo "  ╚════════════════╝    ╚════════════════╝"
echo "          ↓ (check /master)   ↓"
echo "  ╔════════════════╗    ╔════════════════╗    ╔════════════════╗"
echo "  ║ db-master-01   ║    ║ db-slave-01    ║    ║ db-slave-02    ║"
echo "  ║ Patroni RAFT   ║←→  ║ Patroni RAFT   ║←→  ║ Patroni RAFT   ║"
echo "  ║ :5432 :7000    ║    ║ :5432 :7000    ║    ║ :5432 :7000    ║"
echo "  ╚════════════════╝    ╚════════════════╝    ╚════════════════╝"
echo ""

echo "Avantages obtenus:"
echo "  ✓ Patroni RAFT natif (découplé de K3s)"
echo "  ✓ HAProxy suit le master Patroni automatiquement (<5s)"
echo "  ✓ Failover transparent pour les applications"
echo "  ✓ PgBouncer pool les connexions (défense connection storms)"
echo "  ✓ Double HA: proxy down → LB bascule, master down → Patroni bascule"
echo "  ✓ Stack 100% Docker (homogène)"
echo ""

echo "Tests de validation:"
echo ""
echo "1. Test connexion via PgBouncer:"
echo "   PGPASSWORD='$POSTGRES_PASSWORD' psql -h \$(awk -F'\$'\t' '\$2==\"haproxy-01\" {print \$3}' /opt/keybuzz-installer/inventory/servers.tsv) -p 6432 -U postgres -d postgres -c 'SELECT 1'"
echo ""
echo "2. Test failover Patroni:"
echo "   curl -X POST http://10.0.0.120:8008/switchover -d '{\"leader\":\"db-master-01\",\"candidate\":\"db-slave-01\"}'"
echo "   # Attendre 5s"
echo "   # Vérifier que :5432 suit le nouveau master"
echo ""
echo "3. Vérifier stats HAProxy:"
echo "   curl -s -u admin:<password> http://10.0.0.11:8404/ | grep -A5 'be_postgres_master'"
echo ""

echo "Configuration Load Balancer Hetzner (manuel):"
echo "  1. Console Hetzner → Load Balancers"
echo "  2. Créer target group 'pgbouncer-pool'"
echo "  3. Ajouter haproxy-01:6432 et haproxy-02:6432"
echo "  4. Health check: TCP 6432, interval 10s"
echo "  5. Service: 10.0.0.10:4632 → target group"
echo "  6. Algorithme: Round Robin"
echo ""

echo "Configuration application finale:"
echo ""
echo "DB_HOST=10.0.0.10"
echo "DB_PORT=4632"
echo "DB_USER=postgres"
echo "DB_PASSWORD=\${POSTGRES_PASSWORD}"
echo "DB_NAME=postgres"
echo "DB_POOL_SIZE=1  # PgBouncer gère le pool"
echo ""

echo "Credentials:"
echo "  • PostgreSQL: /opt/keybuzz-installer/credentials/postgres.env"
echo "  • HAProxy Stats: /opt/keybuzz-installer/credentials/haproxy.env"
echo ""

if [ $PATCH1_STATUS -eq 0 ] && [ $PATCH2_STATUS -eq 0 ] && [ $PATCH3_STATUS -eq 0 ]; then
    echo -e "$OK STACK HA COMPLÈTE ET OPÉRATIONNELLE"
    exit 0
else
    echo -e "$WARN PATCHES PARTIELLEMENT APPLIQUÉS"
    echo ""
    echo "Certains patches ont échoué. Relancez-les individuellement."
    exit 1
fi
