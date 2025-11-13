#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         Vérification des prérequis K3S Apps Installation          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification cluster K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable"
    exit 1
fi

echo -n "→ Cluster K3s accessible ... "
if ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes" >/dev/null 2>&1; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo ""
    echo "Le cluster K3s n'est pas accessible. Installez-le d'abord :"
    echo "  ./k3s_ha_install.sh"
    echo "  ./k3s_workers_join.sh"
    echo "  ./k3s_bootstrap_addons.sh"
    exit 1
fi

echo -n "→ Nombre de nœuds ... "
NODE_COUNT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes --no-headers | wc -l" 2>/dev/null || echo "0")
if [ "$NODE_COUNT" -ge 8 ]; then
    echo -e "$OK ($NODE_COUNT nœuds)"
else
    echo -e "$WARN ($NODE_COUNT nœuds, attendu 8)"
fi

echo -n "→ Metrics-server opérationnel ... "
if ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n kube-system | grep metrics-server | grep -q Running" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN (optionnel mais recommandé)"
fi

echo -n "→ Ingress NGINX installé ... "
if ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get ns ingress-nginx" >/dev/null 2>&1; then
    echo -e "$OK"
else
    echo -e "$INFO (sera installé via ./09_deploy_ingress_daemonset.sh)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Vérification data-plane ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# PostgreSQL
echo -n "→ PostgreSQL credentials (postgres.env) ... "
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    echo -e "$OK"
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO"
    echo ""
    echo "Fichier manquant : $CREDENTIALS_DIR/postgres.env"
    exit 1
fi

echo -n "→ PostgreSQL port 5432 (RW) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/5432" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo ""
    echo "PostgreSQL n'est pas accessible sur 10.0.0.10:5432"
    exit 1
fi

echo -n "→ PostgreSQL port 5433 (RO) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/5433" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN (optionnel)"
fi

echo -n "→ PgBouncer port 6432 (POOL) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/6432" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo ""
    echo "PgBouncer n'est pas accessible sur 10.0.0.10:6432"
    exit 1
fi

# Redis
echo -n "→ Redis credentials (redis.env) ... "
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    echo -e "$OK"
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$KO"
    echo ""
    echo "Fichier manquant : $CREDENTIALS_DIR/redis.env"
    exit 1
fi

echo -n "→ Redis port 6379 ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/6379" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo ""
    echo "Redis n'est pas accessible sur 10.0.0.10:6379"
    exit 1
fi

# RabbitMQ (optionnel pour maintenant)
echo -n "→ RabbitMQ credentials (rabbitmq.env) ... "
if [ -f "$CREDENTIALS_DIR/rabbitmq.env" ]; then
    echo -e "$OK"
    source "$CREDENTIALS_DIR/rabbitmq.env"
else
    echo -e "$WARN (optionnel pour n8n/Chatwoot)"
fi

echo -n "→ RabbitMQ port 5672 (AMQP) ... "
if timeout 3 bash -c "</dev/tcp/10.0.0.10/5672" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN (optionnel)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Vérification firewall UFW ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

IP_WORKER=$(awk -F'\t' '$2=="k3s-worker-01" {print $3}' "$SERVERS_TSV")

echo "Test depuis k3s-worker-01 ($IP_WORKER) :"
echo ""

echo -n "→ UFW autorise 10.0.0.0/16 ... "
if ssh -o StrictHostKeyChecking=no root@"$IP_WORKER" "ufw status | grep -q '10.0.0.0/16'" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN"
fi

echo -n "→ UFW autorise 10.42.0.0/16 (pods K3s) ... "
if ssh -o StrictHostKeyChecking=no root@"$IP_WORKER" "ufw status | grep -q '10.42.0.0/16'" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO (CRITIQUE - pods ne pourront pas communiquer)"
    echo ""
    echo "Exécutez ./01_fix_ufw_k3s_networks.sh pour corriger"
    exit 1
fi

echo -n "→ UFW autorise 10.43.0.0/16 (services K3s) ... "
if ssh -o StrictHostKeyChecking=no root@"$IP_WORKER" "ufw status | grep -q '10.43.0.0/16'" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO (CRITIQUE - services ne seront pas accessibles)"
    echo ""
    echo "Exécutez ./01_fix_ufw_k3s_networks.sh pour corriger"
    exit 1
fi

echo -n "→ UFW autorise ports NodePort 31695/32720 ... "
if ssh -o StrictHostKeyChecking=no root@"$IP_WORKER" "ufw status | grep -E '31695|32720'" 2>/dev/null | grep -q ALLOW; then
    echo -e "$OK"
else
    echo -e "$WARN (nécessaire pour Ingress HTTP/HTTPS)"
    echo ""
    echo "Déjà configuré par k3s_bootstrap_addons.sh normalement"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Résumé ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🎯 ARCHITECTURE VALIDÉE :"
echo ""
echo "  K3s Cluster HA : $NODE_COUNT nœuds (3 masters + 5 workers)"
echo "  PostgreSQL 16  : 10.0.0.10:5432 (RW) / :5433 (RO) / :6432 (PgBouncer)"
echo "  Redis Sentinel : 10.0.0.10:6379"
echo "  RabbitMQ       : 10.0.0.10:5672 (optionnel)"
echo ""
echo "📋 STRINGS DE CONNEXION POUR LES APPS :"
echo ""
echo "  PostgreSQL (recommandé) :"
echo "    postgresql://postgres:PASSWORD@10.0.0.10:6432/votre_database"
echo ""
echo "  Redis :"
echo "    redis://10.0.0.10:6379"
echo ""
echo "  RabbitMQ :"
echo "    amqp://admin:PASSWORD@10.0.0.10:5672"
echo ""
echo "⏭️  PROCHAINES ÉTAPES :"
echo ""
echo "  1. ./01_fix_ufw_k3s_networks.sh      # Finaliser UFW (si pas encore fait)"
echo "  2. ./02_prepare_database.sh          # Créer databases apps"
echo "  3. ./08_fix_ufw_nodeports_urgent.sh  # Contournement VXLAN"
echo "  4. ./09_deploy_ingress_daemonset.sh  # Ingress NGINX DaemonSet"
echo "  5. ./10_deploy_apps_hostnetwork.sh   # n8n + LiteLLM + Qdrant"
echo "  6. ./11_configure_ingress_routes.sh  # Routes Ingress"
echo ""
