#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        KEYBUZZ K3S - VÉRIFICATION PRÉREQUIS DÉPLOIEMENT           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

BASE_DIR="/opt/keybuzz-installer"
CHECKS_OK=0
CHECKS_KO=0
CHECKS_WARN=0

# Fonction de test
check() {
    local TEST_NAME="$1"
    local TEST_CMD="$2"
    local LEVEL="${3:-error}"  # error ou warn
    
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
echo "1. FICHIERS & STRUCTURE"
echo "═══════════════════════════════════════════════════════════════════"

check "Structure /opt/keybuzz-installer/" "[[ -d '$BASE_DIR' ]]"
check "Inventaire servers.tsv" "[[ -f '$BASE_DIR/inventory/servers.tsv' ]]"
check "Dossier credentials/" "[[ -d '$BASE_DIR/credentials' ]]"
check "Dossier logs/" "[[ -d '$BASE_DIR/logs' ]]"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "2. DATA-PLANE (OBLIGATOIRE)"
echo "═══════════════════════════════════════════════════════════════════"

check "Credentials postgres.env" "[[ -f '$BASE_DIR/credentials/postgres.env' ]]"
check "Credentials redis.env" "[[ -f '$BASE_DIR/credentials/redis.env' ]]"
check "Credentials rabbitmq.env" "[[ -f '$BASE_DIR/credentials/rabbitmq.env' ]]"

# Test connexion PostgreSQL
if [[ -f "$BASE_DIR/credentials/postgres.env" ]]; then
    source "$BASE_DIR/credentials/postgres.env"
    check "PostgreSQL accessible (10.0.0.10:4632)" "timeout 3 bash -c '</dev/tcp/10.0.0.10/4632'"
    check "PostgreSQL RW accessible (:5432)" "timeout 3 bash -c '</dev/tcp/10.0.0.10/5432'"
    check "PostgreSQL RO accessible (:5433)" "timeout 3 bash -c '</dev/tcp/10.0.0.10/5433'"
fi

# Test connexion Redis
check "Redis accessible (10.0.0.10:6379)" "timeout 3 bash -c '</dev/tcp/10.0.0.10/6379'"

# Test connexion RabbitMQ
check "RabbitMQ accessible (10.0.0.10:5672)" "timeout 3 bash -c '</dev/tcp/10.0.0.10/5672'"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "3. LOAD BALANCERS"
echo "═══════════════════════════════════════════════════════════════════"

check "LB K3s API #1 (10.0.0.5:6443)" "timeout 3 bash -c '</dev/tcp/10.0.0.5/6443'" warn
check "LB K3s API #2 (10.0.0.6:6443)" "timeout 3 bash -c '</dev/tcp/10.0.0.6/6443'" warn
check "LB Data (10.0.0.10:4632)" "timeout 3 bash -c '</dev/tcp/10.0.0.10/4632'"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "4. SERVEURS K3s"
echo "═══════════════════════════════════════════════════════════════════"

if [[ -f "$BASE_DIR/inventory/servers.tsv" ]]; then
    # Masters
    MASTER_01_IP=$(awk -F'\t' '$2=="k3s-master-01"{print $3}' "$BASE_DIR/inventory/servers.tsv")
    MASTER_02_IP=$(awk -F'\t' '$2=="k3s-master-02"{print $3}' "$BASE_DIR/inventory/servers.tsv")
    MASTER_03_IP=$(awk -F'\t' '$2=="k3s-master-03"{print $3}' "$BASE_DIR/inventory/servers.tsv")
    
    if [[ -n "$MASTER_01_IP" ]]; then
        check "k3s-master-01 SSH ($MASTER_01_IP)" "ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@$MASTER_01_IP 'echo ok'"
        check "k3s-master-01 RAM ≥ 4 Go" "ssh -o StrictHostKeyChecking=no root@$MASTER_01_IP \"[[ \\\$(free -g | awk '/^Mem:/{print \\\$2}') -ge 4 ]]\"" warn
    fi
    
    if [[ -n "$MASTER_02_IP" ]]; then
        check "k3s-master-02 SSH ($MASTER_02_IP)" "ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@$MASTER_02_IP 'echo ok'"
    fi
    
    if [[ -n "$MASTER_03_IP" ]]; then
        check "k3s-master-03 SSH ($MASTER_03_IP)" "ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@$MASTER_03_IP 'echo ok'"
    fi
    
    # Workers
    for i in {1..5}; do
        WORKER_IP=$(awk -F'\t' -v w="k3s-worker-0$i" '$2==w{print $3}' "$BASE_DIR/inventory/servers.tsv")
        if [[ -n "$WORKER_IP" ]]; then
            check "k3s-worker-0$i SSH ($WORKER_IP)" "ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@$WORKER_IP 'echo ok'"
            check "k3s-worker-0$i RAM ≥ 8 Go" "ssh -o StrictHostKeyChecking=no root@$WORKER_IP \"[[ \\\$(free -g | awk '/^Mem:/{print \\\$2}') -ge 8 ]]\"" warn
        fi
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "5. OUTILS SYSTÈME"
echo "═══════════════════════════════════════════════════════════════════"

check "curl installé" "command -v curl"
check "jq installé" "command -v jq" warn
check "kubectl installé" "command -v kubectl" warn
check "helm installé" "command -v helm" warn
check "psql (PostgreSQL client)" "command -v psql" warn
check "redis-cli" "command -v redis-cli" warn

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "6. CLÉS SSH"
echo "═══════════════════════════════════════════════════════════════════"

check "Clé SSH privée (/root/.ssh/id_ed25519)" "[[ -f /root/.ssh/id_ed25519 ]]"
check "Clé SSH publique (/root/.ssh/id_ed25519.pub)" "[[ -f /root/.ssh/id_ed25519.pub ]]"
check "Permissions clé privée (600)" "[[ \$(stat -c '%a' /root/.ssh/id_ed25519 2>/dev/null) == '600' ]]" warn

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "7. RÉSEAU"
echo "═══════════════════════════════════════════════════════════════════"

check "Résolution DNS" "ping -c 1 8.8.8.8" warn
check "Accès internet (github.com)" "curl -s -o /dev/null -w '%{http_code}' https://github.com | grep -q 200" warn

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
    echo "║                    ✓ PRÊT POUR LE DÉPLOIEMENT                     ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Lancer le déploiement avec :"
    echo "  ./deploy_keybuzz_stack.sh"
    echo ""
    exit 0
else
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║                 ✗ PRÉREQUIS NON SATISFAITS                         ║"
    echo "║              Corriger les erreurs avant déploiement               ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Actions requises :"
    echo ""
    
    if [[ ! -f "$BASE_DIR/credentials/postgres.env" ]]; then
        echo "  • Déployer le data-plane (PostgreSQL + Patroni)"
    fi
    
    if [[ ! -f "$BASE_DIR/inventory/servers.tsv" ]]; then
        echo "  • Créer le fichier servers.tsv avec les IPs des nœuds"
    fi
    
    if [[ $CHECKS_KO -gt 0 ]]; then
        echo "  • Vérifier la connectivité SSH vers tous les nœuds"
        echo "  • Vérifier l'accessibilité des services data-plane"
    fi
    
    echo ""
    exit 1
fi
