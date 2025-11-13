#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Vérification Prérequis - Chatwoot & Superset                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification PostgreSQL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Trouver l'IP VIP PostgreSQL
PG_VIP="10.0.0.10"

echo "VIP PostgreSQL : $PG_VIP"
echo ""

# Charger credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO PostgreSQL credentials non trouvés"
    exit 1
fi

echo -n "→ Connexion PostgreSQL (port 5432) ... "
if timeout 3 bash -c "</dev/tcp/$PG_VIP/5432" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "  PostgreSQL inaccessible sur $PG_VIP:5432"
    exit 1
fi

echo -n "→ PgBouncer (port 6432) ... "
if timeout 3 bash -c "</dev/tcp/$PG_VIP/6432" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$WARN (optionnel)"
fi

echo -n "→ Base chatwoot existe ... "
PG_NODE=$(awk -F'\t' '$6=="patroni" {print $3; exit}' "$SERVERS_TSV")
[ -z "$PG_NODE" ] && PG_NODE="$PG_VIP"

ssh -o StrictHostKeyChecking=no root@"$PG_NODE" bash <<CHECKDB
export PGPASSWORD='${POSTGRES_PASSWORD}'
if docker ps 2>/dev/null | grep -q postgres; then
    PG_CONTAINER=\$(docker ps | grep postgres | awk '{print \$1}' | head -n1)
    if docker exec -e PGPASSWORD='${POSTGRES_PASSWORD}' \$PG_CONTAINER psql -U postgres -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw chatwoot; then
        exit 0
    else
        exit 1
    fi
else
    if psql -U postgres -h localhost -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw chatwoot; then
        exit 0
    else
        exit 1
    fi
fi
CHECKDB

if [ $? -eq 0 ]; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "  Base chatwoot n'existe pas. Exécutez ./02_prepare_database.sh"
    exit 1
fi

echo -n "→ Extension pgvector installée ... "
ssh -o StrictHostKeyChecking=no root@"$PG_NODE" bash <<CHECKEXT
export PGPASSWORD='${POSTGRES_PASSWORD}'
if docker ps 2>/dev/null | grep -q postgres; then
    PG_CONTAINER=\$(docker ps | grep postgres | awk '{print \$1}' | head -n1)
    if docker exec -e PGPASSWORD='${POSTGRES_PASSWORD}' \$PG_CONTAINER psql -U postgres -d chatwoot -c "SELECT * FROM pg_extension WHERE extname='vector';" 2>/dev/null | grep -q vector; then
        exit 0
    else
        exit 1
    fi
else
    if psql -U postgres -h localhost -d chatwoot -c "SELECT * FROM pg_extension WHERE extname='vector';" 2>/dev/null | grep -q vector; then
        exit 0
    else
        exit 1
    fi
fi
CHECKEXT

if [ $? -eq 0 ]; then
    echo -e "$OK"
else
    echo -e "$WARN"
    echo "  Extension pgvector manquante. Sera installée automatiquement."
fi

echo -n "→ Base superset existe ... "
ssh -o StrictHostKeyChecking=no root@"$PG_NODE" bash <<CHECKDB2
export PGPASSWORD='${POSTGRES_PASSWORD}'
if docker ps 2>/dev/null | grep -q postgres; then
    PG_CONTAINER=\$(docker ps | grep postgres | awk '{print \$1}' | head -n1)
    if docker exec -e PGPASSWORD='${POSTGRES_PASSWORD}' \$PG_CONTAINER psql -U postgres -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw superset; then
        exit 0
    else
        exit 1
    fi
else
    if psql -U postgres -h localhost -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw superset; then
        exit 0
    else
        exit 1
    fi
fi
CHECKDB2

if [ $? -eq 0 ]; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "  Base superset n'existe pas. Exécutez ./02_prepare_database.sh"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Vérification Redis ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

REDIS_VIP="10.0.0.10"

echo "VIP Redis : $REDIS_VIP"
echo ""

# Charger Redis credentials
if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN Redis credentials non trouvés"
    REDIS_PASSWORD="keybuzz2025"
fi

echo -n "→ Redis HAProxy (port 6379) ... "
if timeout 3 bash -c "</dev/tcp/$REDIS_VIP/6379" 2>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "  Redis inaccessible sur $REDIS_VIP:6379"
    echo "  Chatwoot nécessite Redis via HAProxy (non Sentinel-aware)"
    exit 1
fi

echo -n "→ Test authentification Redis ... "
REDIS_NODE=$(awk -F'\t' '$6=="redis" {print $3; exit}' "$SERVERS_TSV")
[ -z "$REDIS_NODE" ] && REDIS_NODE="$REDIS_VIP"

redis_test=$(ssh -o StrictHostKeyChecking=no root@"$REDIS_NODE" \
    "redis-cli -h $REDIS_VIP -p 6379 -a '$REDIS_PASSWORD' PING 2>/dev/null" || echo "")

if [ "$redis_test" = "PONG" ]; then
    echo -e "$OK"
else
    echo -e "$WARN (Auth possible requise)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Vérification RabbitMQ (optionnel) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

RMQ_VIP="10.0.0.10"

echo -n "→ RabbitMQ (port 5672) ... "
if timeout 3 bash -c "</dev/tcp/$RMQ_VIP/5672" 2>/dev/null; then
    echo -e "$OK"
    
    if [ -f "$CREDENTIALS_DIR/rabbitmq.env" ]; then
        source "$CREDENTIALS_DIR/rabbitmq.env"
        echo "  RabbitMQ disponible (peut être utilisé par Chatwoot)"
    fi
else
    echo -e "$WARN (optionnel - Redis suffit pour Chatwoot)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Vérification Cluster K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo -n "→ Cluster accessible ... "
if kubectl get nodes >/dev/null 2>&1; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo "  kubectl non configuré ou cluster inaccessible"
    exit 1
fi

READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready)
echo "  Nœuds Ready : $READY_NODES"

echo -n "→ Ingress NGINX opérationnel ... "
INGRESS_PODS=$(kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | grep -c Running)
if [ "$INGRESS_PODS" -ge 5 ]; then
    echo -e "$OK ($INGRESS_PODS pods)"
else
    echo -e "$WARN ($INGRESS_PODS pods, attendu 8)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSUMÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<SUMMARY
✅ Prérequis vérifiés :
  - PostgreSQL : Accessible (VIP $PG_VIP)
  - Base chatwoot : Existe
  - Base superset : Existe
  - Redis HAProxy : Accessible (VIP $REDIS_VIP)
  - Cluster K3s : Opérationnel ($READY_NODES nodes)
  - Ingress NGINX : Opérationnel ($INGRESS_PODS pods)

⚠️  Notes importantes :

CHATWOOT :
  - Utilise Redis via HAProxy (port 6379)
  - Nécessite plusieurs composants (web, workers, sidekiq)
  - Migrations DB automatiques au premier démarrage
  - Configuration complexe (40+ variables d'environnement)

SUPERSET :
  - Nécessite init DB (superset db upgrade)
  - Nécessite création user admin
  - Correction erreur de port appliquée

Prochaine étape :
  ./14_deploy_chatwoot.sh

SUMMARY

exit 0
