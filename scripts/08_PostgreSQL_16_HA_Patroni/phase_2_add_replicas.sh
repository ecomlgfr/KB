#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     PHASE_2_ADD_REPLICAS - Ajout progressif des replicas          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "STRATÉGIE: Ajouter les replicas un par un avec streaming replication"
echo "           Tester après chaque ajout"
echo ""

# Vérifier que la phase 1 est complète
if [ ! -f "/opt/keybuzz-installer/credentials/cluster_state.txt" ]; then
    echo -e "$KO Phase 1 non complétée. Lancer d'abord phase_1_standalone.sh"
    exit 1
fi

echo "1. Vérification du master (db-master-01)..."
echo ""

echo -n "  Master PostgreSQL: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres -c "SELECT 1" &>/dev/null; then
    echo -e "$OK"
else
    echo -e "$KO Master non accessible"
    exit 1
fi

# ========================================
# Configuration du master pour la réplication
# ========================================
echo ""
echo "2. Configuration du master pour la réplication..."
echo ""

ssh root@10.0.0.120 bash -s "$POSTGRES_PASSWORD" <<'CONFIG_MASTER'
PG_PASSWORD="$1"

# Créer l'utilisateur replicator
docker exec postgres psql -U postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = 'replicator') THEN
        CREATE USER replicator WITH REPLICATION PASSWORD '$PG_PASSWORD';
    ELSE
        ALTER USER replicator PASSWORD '$PG_PASSWORD';
    END IF;
END
\$\$;

-- Vérifier
SELECT usename, userepl FROM pg_user WHERE usename = 'replicator';
SQL

# Configurer PostgreSQL pour la réplication
docker exec postgres bash -c "cat >> /var/lib/postgresql/data/postgresql.conf" <<EOF

# Streaming Replication Settings
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 128MB
hot_standby = on
hot_standby_feedback = on
EOF

# Configurer pg_hba.conf pour permettre la réplication
docker exec postgres bash -c "cat >> /var/lib/postgresql/data/pg_hba.conf" <<EOF

# Replication connections
host    replication     replicator      10.0.0.121/32           md5
host    replication     replicator      10.0.0.122/32           md5
host    all             all             10.0.0.121/32           md5
host    all             all             10.0.0.122/32           md5
EOF

# Redémarrer PostgreSQL pour appliquer les changements
docker restart postgres

echo "Master configuré pour la réplication"
CONFIG_MASTER

echo "  Attente du redémarrage (10s)..."
sleep 10

# ========================================
# AJOUT DU PREMIER REPLICA (db-slave-01)
# ========================================
echo ""
echo "3. Ajout du premier replica (db-slave-01)..."
echo ""

ssh root@10.0.0.121 bash -s "$POSTGRES_PASSWORD" <<'SETUP_REPLICA1'
PG_PASSWORD="$1"
MASTER_IP="10.0.0.120"

# Nettoyer
docker stop postgres 2>/dev/null
docker rm -f postgres 2>/dev/null
rm -rf /opt/keybuzz/postgres/data/*

# Créer les répertoires
mkdir -p /opt/keybuzz/postgres/{data,logs,archive}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data

# Faire un backup du master avec pg_basebackup
echo "Copie des données depuis le master..."
PGPASSWORD="$PG_PASSWORD" pg_basebackup \
  -h "$MASTER_IP" \
  -p 5432 \
  -U replicator \
  -D /opt/keybuzz/postgres/data \
  -Fp -Xs -P -R \
  -X stream \
  -c fast

# Ajuster les permissions
chown -R 999:999 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/data

# Créer standby.signal
touch /opt/keybuzz/postgres/data/standby.signal

# Configuration de connexion au master
cat > /opt/keybuzz/postgres/data/postgresql.auto.conf <<EOF
primary_conninfo = 'host=$MASTER_IP port=5432 user=replicator password=$PG_PASSWORD'
primary_slot_name = 'replica1'
EOF

# Démarrer le replica
docker run -d \
  --name postgres \
  --hostname db-slave-01 \
  --restart unless-stopped \
  -p 5432:5432 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/logs:/var/log/postgresql \
  postgres:17

echo "Replica 1 démarré"
SETUP_REPLICA1

echo "  Attente du démarrage (15s)..."
sleep 15

echo -n "  Test replica 1: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.121 -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "t"; then
    echo -e "$OK En mode recovery (replica)"
else
    echo -e "$KO"
fi

# ========================================
# TEST DE LA RÉPLICATION SUR REPLICA 1
# ========================================
echo ""
echo "4. Test de réplication sur replica 1..."
echo ""

# Créer une table test sur le master
echo -n "  Création table test sur master: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres <<SQL 2>/dev/null
CREATE TABLE IF NOT EXISTS replication_test (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO replication_test (data) VALUES ('Test Phase 2 - Replica 1');
SQL
echo -e "$OK"

sleep 3

echo -n "  Vérification sur replica 1: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.121 -p 5432 -U postgres -c "SELECT data FROM replication_test" -t 2>/dev/null | grep -q "Test Phase 2"; then
    echo -e "$OK Réplication fonctionnelle"
else
    echo -e "$KO Réplication non fonctionnelle"
fi

# ========================================
# AJOUT DU DEUXIÈME REPLICA (db-slave-02)
# ========================================
echo ""
echo "5. Ajout du deuxième replica (db-slave-02)..."
echo ""

ssh root@10.0.0.122 bash -s "$POSTGRES_PASSWORD" <<'SETUP_REPLICA2'
PG_PASSWORD="$1"
MASTER_IP="10.0.0.120"

# Nettoyer
docker stop postgres 2>/dev/null
docker rm -f postgres 2>/dev/null
rm -rf /opt/keybuzz/postgres/data/*

# Créer les répertoires
mkdir -p /opt/keybuzz/postgres/{data,logs,archive}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data

# Faire un backup du master
echo "Copie des données depuis le master..."
PGPASSWORD="$PG_PASSWORD" pg_basebackup \
  -h "$MASTER_IP" \
  -p 5432 \
  -U replicator \
  -D /opt/keybuzz/postgres/data \
  -Fp -Xs -P -R \
  -X stream \
  -c fast

# Ajuster les permissions
chown -R 999:999 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/data

# Créer standby.signal
touch /opt/keybuzz/postgres/data/standby.signal

# Configuration
cat > /opt/keybuzz/postgres/data/postgresql.auto.conf <<EOF
primary_conninfo = 'host=$MASTER_IP port=5432 user=replicator password=$PG_PASSWORD'
primary_slot_name = 'replica2'
EOF

# Démarrer le replica
docker run -d \
  --name postgres \
  --hostname db-slave-02 \
  --restart unless-stopped \
  -p 5432:5432 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/logs:/var/log/postgresql \
  postgres:17

echo "Replica 2 démarré"
SETUP_REPLICA2

echo "  Attente du démarrage (15s)..."
sleep 15

echo -n "  Test replica 2: "
if PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.122 -p 5432 -U postgres -c "SELECT pg_is_in_recovery()" -t 2>/dev/null | grep -q "t"; then
    echo -e "$OK En mode recovery (replica)"
else
    echo -e "$KO"
fi

# ========================================
# TEST FINAL DE RÉPLICATION
# ========================================
echo ""
echo "6. Test final de réplication sur tous les nœuds..."
echo ""

# Insérer une nouvelle ligne sur le master
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.120 -p 5432 -U postgres <<SQL 2>/dev/null
INSERT INTO replication_test (data) VALUES ('Test final - Tous les replicas');
SQL

sleep 3

echo -n "  Replica 1 synchronisé: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.121 -p 5432 -U postgres -c "SELECT COUNT(*) FROM replication_test" -t 2>/dev/null | grep -q "2" && echo -e "$OK" || echo -e "$KO"

echo -n "  Replica 2 synchronisé: "
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 10.0.0.122 -p 5432 -U postgres -c "SELECT COUNT(*) FROM replication_test" -t 2>/dev/null | grep -q "2" && echo -e "$OK" || echo -e "$KO"

# ========================================
# ÉTAT DE LA RÉPLICATION
# ========================================
echo ""
echo "7. État de la réplication..."
echo ""

ssh root@10.0.0.120 bash <<'REPLICATION_STATUS'
docker exec postgres psql -U postgres -c "
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    replay_lag
FROM pg_stat_replication;"
REPLICATION_STATUS

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "PHASE 2 COMPLÉTÉE - Cluster avec réplication streaming"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Configuration actuelle:"
echo "  • Master: db-master-01 (10.0.0.120)"
echo "  • Replica 1: db-slave-01 (10.0.0.121) - Read-only"
echo "  • Replica 2: db-slave-02 (10.0.0.122) - Read-only"
echo ""
echo "Réplication: Streaming replication active"
echo "Mot de passe: $POSTGRES_PASSWORD"
echo ""
echo "Test de connexion:"
echo "  Master: PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.120 -p 5432 -U postgres"
echo "  Replica: PGPASSWORD='$POSTGRES_PASSWORD' psql -h 10.0.0.121 -p 5432 -U postgres"
echo ""
echo "PROCHAINE ÉTAPE: Une fois validé, lancer:"
echo "  ./phase_3_convert_to_patroni.sh"
echo "  (convertira le cluster en Patroni pour la haute disponibilité)"
echo ""
echo "═══════════════════════════════════════════════════════════════════"

# Mettre à jour l'état
echo "PHASE_2_COMPLETE" >> /opt/keybuzz-installer/credentials/cluster_state.txt
echo "REPLICAS_ADDED=2" >> /opt/keybuzz-installer/credentials/cluster_state.txt
