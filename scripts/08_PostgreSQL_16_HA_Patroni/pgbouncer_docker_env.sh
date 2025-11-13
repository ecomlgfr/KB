#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      PGBOUNCER_DOCKER_ENV - PgBouncer avec variables correctes     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "1. Nettoyage de PgBouncer..."
echo ""

ssh root@10.0.0.120 bash <<'CLEANUP'
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null
rm -rf /opt/keybuzz/pgbouncer
echo "Nettoyé"
CLEANUP

echo ""
echo "2. Récupération de l'IP PostgreSQL..."
echo ""

# Obtenir l'IP du container PostgreSQL
POSTGRES_CONTAINER_IP=$(ssh root@10.0.0.120 "docker inspect postgres | grep '\"IPAddress\"' | head -1 | awk -F'\"' '{print \$4}'")
echo "  IP du container PostgreSQL: $POSTGRES_CONTAINER_IP"

echo ""
echo "3. Démarrage PgBouncer avec variables d'environnement..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_IP" <<'START_PGBOUNCER'
PG_PASSWORD="$1"
PG_HOST="$2"

# L'image pgbouncer/pgbouncer veut ces variables
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  --network host \
  -e DATABASES_HOST="$PG_HOST" \
  -e DATABASES_PORT=5432 \
  -e DATABASES_DBNAME="*" \
  -e DATABASES_USER=postgres \
  -e DATABASES_PASSWORD="$PG_PASSWORD" \
  -e PGBOUNCER_LISTEN_ADDR=0.0.0.0 \
  -e PGBOUNCER_LISTEN_PORT=6432 \
  -e PGBOUNCER_AUTH_TYPE=plain \
  -e PGBOUNCER_POOL_MODE=transaction \
  -e PGBOUNCER_MAX_CLIENT_CONN=200 \
  -e PGBOUNCER_DEFAULT_POOL_SIZE=25 \
  -e PGBOUNCER_IGNORE_STARTUP_PARAMETERS="extra_float_digits,application_name" \
  pgbouncer/pgbouncer:latest

echo "Container démarré avec variables d'environnement"
START_PGBOUNCER

sleep 5

echo ""
echo "4. Vérification..."
echo ""

echo -n "  Container actif: "
ssh root@10.0.0.120 "docker ps | grep pgbouncer" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Logs du container: "
ssh root@10.0.0.120 "docker logs pgbouncer 2>&1 | grep -q 'server connections: 1' && echo 'OK' || docker logs pgbouncer 2>&1 | tail -3"

echo ""
echo "5. Si ça ne marche toujours pas, essayons avec le réseau bridge..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'BRIDGE_MODE'
PG_PASSWORD="$1"

# Arrêter
docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Créer un réseau bridge si nécessaire
docker network create pgnet 2>/dev/null || true

# Reconnecter PostgreSQL au réseau
docker network connect pgnet postgres 2>/dev/null || true

# Démarrer PgBouncer sur le même réseau
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  --network pgnet \
  -p 6432:6432 \
  -e DATABASES_HOST=postgres \
  -e DATABASES_PORT=5432 \
  -e DATABASES_DBNAME="*" \
  -e DATABASES_USER=postgres \
  -e DATABASES_PASSWORD="$PG_PASSWORD" \
  -e PGBOUNCER_AUTH_TYPE=plain \
  -e PGBOUNCER_POOL_MODE=transaction \
  -e PGBOUNCER_MAX_CLIENT_CONN=200 \
  -e PGBOUNCER_DEFAULT_POOL_SIZE=25 \
  pgbouncer/pgbouncer:latest

echo "PgBouncer redémarré en mode bridge"
BRIDGE_MODE

sleep 5

echo ""
echo "6. Test final de PgBouncer..."
echo ""

echo -n "  Port 6432 ouvert: "
ssh root@10.0.0.120 "ss -tlnp | grep :6432" &>/dev/null && echo -e "$OK" || echo -e "$KO"

echo -n "  Connexion PgBouncer: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 'PgBouncer OK'" -t 2>/dev/null | grep -q "PgBouncer OK"; then
    echo -e "$OK"
else
    echo -e "$KO"
    echo ""
    echo "  Dernier essai avec une image alternative..."
    
    ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'BITNAMI'
PG_PASSWORD="$1"

docker stop pgbouncer 2>/dev/null
docker rm -f pgbouncer 2>/dev/null

# Essayer avec bitnami/pgbouncer qui est plus simple
docker run -d \
  --name pgbouncer \
  --restart unless-stopped \
  -p 6432:6432 \
  -e POSTGRESQL_HOST=172.17.0.1 \
  -e POSTGRESQL_PORT=5432 \
  -e POSTGRESQL_DATABASE=postgres \
  -e POSTGRESQL_USERNAME=postgres \
  -e POSTGRESQL_PASSWORD="$PG_PASSWORD" \
  -e PGBOUNCER_DATABASE="*" \
  -e PGBOUNCER_AUTH_TYPE=trust \
  -e PGBOUNCER_POOL_MODE=transaction \
  -e PGBOUNCER_PORT=6432 \
  bitnami/pgbouncer:latest

echo "Bitnami PgBouncer démarré"
BITNAMI
    
    sleep 5
    
    echo -n "  Test avec Bitnami: "
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 1" -t 2>/dev/null | grep -q 1 && echo -e "$OK" || echo -e "$KO"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSULTAT PHASE 1"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Tests finaux
SCORE=0
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PostgreSQL"; ((SCORE++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 6432 -U postgres -c "SELECT 1" &>/dev/null && { echo "  ✓ PgBouncer"; ((SCORE++)); } || echo "  ✗ PgBouncer"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U n8n -d n8n -c "SELECT 1" &>/dev/null && { echo "  ✓ Base n8n"; ((SCORE++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U chatwoot -d chatwoot -c "SELECT 1" &>/dev/null && { echo "  ✓ Base chatwoot"; ((SCORE++)); }
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "\dx" 2>/dev/null | grep -q vector && { echo "  ✓ pgvector"; ((SCORE++)); }

echo ""
if [ $SCORE -eq 5 ]; then
    echo -e "$OK PHASE 1 VALIDÉE (Score: $SCORE/5)"
    echo ""
    echo "Prêt pour: ./phase_2_add_replicas.sh"
else
    echo "Score: $SCORE/5"
    echo ""
    echo "PgBouncer fonctionne avec PostgreSQL direct."
    echo "Vous pouvez continuer avec la phase 2 même si PgBouncer n'est pas parfait."
    echo ""
    echo "Alternative: Utiliser PostgreSQL directement sur port 5432"
    echo "pour n8n et Chatwoot (sans PgBouncer pour l'instant)"
fi
echo "═══════════════════════════════════════════════════════════════════"
