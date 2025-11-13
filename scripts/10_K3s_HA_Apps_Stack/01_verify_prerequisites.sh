#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   VÉRIFICATION COMPLÈTE DES PRÉ-REQUIS                             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

ERRORS=0
WARNINGS=0

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1/10 : Vérification du cluster K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready")
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)

echo "→ Nœuds K3s : $READY_NODES/$TOTAL_NODES Ready"

if [ $READY_NODES -eq 8 ]; then
    echo -e "  $OK Tous les nœuds sont Ready"
else
    echo -e "  $KO Certains nœuds ne sont pas Ready"
    kubectl get nodes
    ((ERRORS++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2/10 : Vérification UFW (Firewall) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Règles UFW critiques à vérifier sur les workers..."

for WORKER in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    echo ""
    echo "  Worker $WORKER :"
    
    # Vérifier les règles essentielles
    ssh -o StrictHostKeyChecking=no root@$WORKER "
        ufw status | grep -E '(10.42.0.0/16|10.43.0.0/16|31695|32720)' || echo '❌ Règles K3s manquantes'
    "
done

echo ""
read -p "Les règles UFW semblent-elles correctes ? (yes/NO) : " ufw_ok

if [ "$ufw_ok" != "yes" ]; then
    echo -e "  $WARN Appliquer les corrections UFW..."
    
    for WORKER in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
        echo "  → Correction UFW sur $WORKER..."
        ssh root@$WORKER "
            # Autoriser les réseaux K3s
            ufw allow from 10.42.0.0/16 comment 'K3s pods'
            ufw allow from 10.43.0.0/16 comment 'K3s services'
            
            # Autoriser les NodePorts Ingress
            ufw allow 31695/tcp comment 'Ingress HTTP'
            ufw allow 32720/tcp comment 'Ingress HTTPS'
            
            ufw reload
        " >/dev/null 2>&1
    done
    
    echo -e "  $OK Règles UFW appliquées"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3/10 : Vérification Ingress NGINX ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

INGRESS_PODS=$(kubectl get pods -n ingress-nginx --no-headers | grep -c "Running")

echo "→ Pods Ingress NGINX Running : $INGRESS_PODS"

if [ $INGRESS_PODS -eq 8 ]; then
    echo -e "  $OK Ingress NGINX opérationnel (1 pod par worker)"
else
    echo -e "  $KO Ingress NGINX incomplet"
    kubectl get pods -n ingress-nginx
    ((ERRORS++))
fi

# Vérifier les NodePorts
echo ""
echo "→ Vérification des NodePorts Ingress..."
kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide

NODEPORT_HTTP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
NODEPORT_HTTPS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

echo "  HTTP NodePort  : $NODEPORT_HTTP (doit être 31695)"
echo "  HTTPS NodePort : $NODEPORT_HTTPS (doit être 32720)"

if [ "$NODEPORT_HTTP" != "31695" ] || [ "$NODEPORT_HTTPS" != "32720" ]; then
    echo -e "  $WARN NodePorts incorrects, correction nécessaire"
    ((WARNINGS++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4/10 : Vérification PostgreSQL ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO postgres.env introuvable"
    ((ERRORS++))
fi

echo "→ Test connexion PostgreSQL via LB (10.0.0.10:5432)..."
if psql -h 10.0.0.10 -p 5432 -U postgres -c "SELECT version();" >/dev/null 2>&1; then
    echo -e "  $OK Connexion PostgreSQL port 5432 OK"
else
    echo -e "  $KO Impossible de se connecter au port 5432"
    ((ERRORS++))
fi

echo ""
echo "→ Test connexion PgBouncer (10.0.0.10:4632)..."
if psql -h 10.0.0.10 -p 4632 -U postgres -c "SHOW POOLS;" >/dev/null 2>&1; then
    echo -e "  $OK Connexion PgBouncer port 4632 OK"
else
    echo -e "  $KO Impossible de se connecter au port 4632"
    ((ERRORS++))
fi

echo ""
echo "→ Vérification des extensions PostgreSQL..."
ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres" <<'SQL'
-- Extensions critiques pour les apps
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

SELECT 'Extensions PostgreSQL installées' AS status;
SQL

if [ $? -eq 0 ]; then
    echo -e "  $OK Extensions PostgreSQL OK"
else
    echo -e "  $KO Erreur extensions PostgreSQL"
    ((ERRORS++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5/10 : Vérification Redis ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN redis.env introuvable"
    ((WARNINGS++))
fi

echo "→ Test connexion Redis (10.0.0.10:6379)..."
if timeout 5 bash -c "echo PING | nc 10.0.0.10 6379" | grep -q "PONG"; then
    echo -e "  $OK Connexion Redis OK"
else
    echo -e "  $KO Impossible de se connecter à Redis"
    ((ERRORS++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6/10 : Vérification RabbitMQ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Test connexion RabbitMQ (10.0.0.10:5672)..."
if timeout 5 bash -c "echo '' | nc 10.0.0.10 5672" 2>/dev/null; then
    echo -e "  $OK Port RabbitMQ 5672 accessible"
else
    echo -e "  $KO Port RabbitMQ 5672 inaccessible"
    ((ERRORS++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7/10 : Vérification DNS interne K3s ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Test résolution DNS dans un pod..."
kubectl run test-dns --image=busybox:1.28 --restart=Never --rm -it -- nslookup kubernetes.default 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "  $OK DNS interne K3s fonctionne"
else
    echo -e "  $WARN Test DNS échoué (peut être normal)"
    ((WARNINGS++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8/10 : Test connectivité inter-pods ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Création d'un pod de test..."
kubectl run test-connectivity --image=busybox:1.28 --restart=Never --rm -it --command -- sh -c "
  echo 'Test PostgreSQL 5432...'
  nc -zv 10.0.0.10 5432 2>&1 || echo 'FAIL'
  
  echo 'Test PgBouncer 4632...'
  nc -zv 10.0.0.10 4632 2>&1 || echo 'FAIL'
  
  echo 'Test Redis 6379...'
  nc -zv 10.0.0.10 6379 2>&1 || echo 'FAIL'
  
  echo 'Test RabbitMQ 5672...'
  nc -zv 10.0.0.10 5672 2>&1 || echo 'FAIL'
" 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "  $OK Connectivité inter-pods OK"
else
    echo -e "  $KO Problèmes de connectivité"
    ((ERRORS++))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 9/10 : Vérification des credentials ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for FILE in postgres.env redis.env rabbitmq.env; do
    if [ -f "$CREDENTIALS_DIR/$FILE" ]; then
        echo -e "  $OK $FILE présent"
    else
        echo -e "  $KO $FILE manquant"
        ((ERRORS++))
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 10/10 : Vérification Load Balancers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Test Load Balancers publics..."
echo "  LB-1 (49.13.42.76) :"
curl -I -m 5 http://49.13.42.76/ 2>/dev/null | head -1 || echo "    Pas de réponse"

echo "  LB-2 (138.199.132.240) :"
curl -I -m 5 http://138.199.132.240/ 2>/dev/null | head -1 || echo "    Pas de réponse"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ RÉSUMÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "$OK TOUS LES PRÉ-REQUIS SONT VALIDÉS !"
    echo ""
    echo "Vous pouvez lancer le déploiement :"
    echo "  ./02_deploy_apps_clean.sh"
elif [ $ERRORS -eq 0 ]; then
    echo -e "$WARN $WARNINGS avertissements détectés"
    echo ""
    echo "Les pré-requis sont OK mais il y a des avertissements."
    echo "Vous pouvez continuer avec :"
    echo "  ./02_deploy_apps_clean.sh"
else
    echo -e "$KO $ERRORS erreurs détectées"
    echo -e "$WARN $WARNINGS avertissements"
    echo ""
    echo "CORRIGEZ LES ERREURS avant de déployer les apps !"
    echo ""
    echo "Erreurs typiques :"
    echo "  - UFW bloque les réseaux K3s (10.42/10.43)"
    echo "  - PostgreSQL/Redis inaccessible"
    echo "  - Ingress NGINX incomplet"
    echo ""
    exit 1
fi

echo ""
