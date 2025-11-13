#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        FORCE_SYNC_PASSWORD - Synchronisation forcée des mdp        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

# Charger les credentials actuels
source /opt/keybuzz-installer/credentials/postgres.env

echo ""
echo "Mot de passe cible: $POSTGRES_PASSWORD"
echo ""

echo "1. Arrêt complet du cluster..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Arrêt $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'STOP'
docker stop patroni pgbouncer 2>/dev/null
docker rm -f patroni pgbouncer 2>/dev/null
# Important: nettoyer le répertoire Raft pour forcer réinitialisation
rm -rf /opt/keybuzz/postgres/raft/*
STOP
    echo -e "$OK"
done

echo ""
echo "2. Nettoyage des données PostgreSQL (réinitialisation complète)..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  Nettoyage $ip: "
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CLEAN'
# Sauvegarder la config
cp /opt/keybuzz/patroni/config/patroni.yml /tmp/patroni.yml.bak 2>/dev/null

# Nettoyer TOUT
rm -rf /opt/keybuzz/postgres/data/*
rm -rf /opt/keybuzz/postgres/raft/*
rm -rf /var/lib/postgresql/data/* 2>/dev/null

# Recréer avec bonnes permissions
mkdir -p /opt/keybuzz/postgres/{data,raft}
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 /opt/keybuzz/postgres/data
chmod 700 /opt/keybuzz/postgres/raft
CLEAN
    echo -e "$OK"
done

echo ""
echo "3. Vérification que les configs Patroni ont le bon mot de passe..."
echo ""

for server in "10.0.0.120:db-master-01:true" "10.0.0.121:db-slave-01:false" "10.0.0.122:db-slave-02:false"; do
    IFS=':' read -r ip hostname is_master <<< "$server"
    echo -n "  Vérification config $hostname: "
    
    # Vérifier si le mot de passe est dans la config
    CONFIG_PWD=$(ssh root@"$ip" "grep -A1 'password:' /opt/keybuzz/patroni/config/patroni.yml | tail -1 | sed \"s/.*password: '//\" | sed \"s/'.*//\"" 2>/dev/null | head -1)
    
    if [ "$CONFIG_PWD" = "$POSTGRES_PASSWORD" ]; then
        echo -e "$OK (mot de passe correct)"
    else
        echo -e "$KO (mot de passe incorrect: $CONFIG_PWD)"
        echo "    Mise à jour de la configuration..."
        
        # Mettre à jour la config avec le bon mot de passe
        ssh root@"$ip" "sed -i \"s/password: '.*'/password: '$POSTGRES_PASSWORD'/g\" /opt/keybuzz/patroni/config/patroni.yml"
    fi
done

echo ""
echo "4. Démarrage simultané du cluster avec configs corrigées..."
echo ""

# Démarrer les 3 nœuds ENSEMBLE (important pour Raft)
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'START' 2>/dev/null &
# S'assurer des permissions
chown -R 999:999 /opt/keybuzz/postgres
chown 999:999 /opt/keybuzz/patroni/config/patroni.yml

# Démarrer Patroni
docker run -d \
  --name patroni \
  --hostname $(hostname) \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni:17-raft
START
done

wait
echo -e "  $OK Containers lancés"

echo ""
echo "5. Attente de l'initialisation du cluster (60s)..."
echo -n "  "
for i in {1..60}; do
    echo -n "."
    sleep 1
    if [ $((i % 20)) -eq 0 ]; then
        echo ""
        echo -n "  "
    fi
done
echo ""

echo ""
echo "6. Vérification du cluster..."
echo ""

# Identifier le leader
LEADER_IP=""
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    STATE=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    role = d.get('role', '')
    state = d.get('state', '')
    print(f'{state}/{role}')
    if role in ['master', 'leader']:
        print('LEADER')
except:
    print('ERROR')
" 2>/dev/null)
    
    echo "  $ip: $STATE"
    
    if echo "$STATE" | grep -q "LEADER"; then
        LEADER_IP="$ip"
    fi
done

if [ -n "$LEADER_IP" ]; then
    echo ""
    echo -e "  $OK Leader identifié: $LEADER_IP"
    
    echo ""
    echo "7. Test de connexion avec le nouveau mot de passe..."
    echo ""
    
    # Test local d'abord
    echo -n "  Test local sur le leader: "
    if ssh root@"$LEADER_IP" "docker exec patroni psql -U postgres -c 'SELECT version()' | grep -q PostgreSQL" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
    
    # Test distant
    echo -n "  Test distant avec psql: "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres -c "SELECT 'SUCCESS'" -t 2>/dev/null | grep -q SUCCESS; then
        echo -e "$OK Connexion réussie!"
    else
        echo -e "$KO"
        
        # Si échec, afficher l'erreur
        ERROR=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres -c "SELECT 1" 2>&1)
        echo "    Erreur: $(echo "$ERROR" | grep -E "FATAL|ERROR" | head -1)"
    fi
    
    echo ""
    echo "8. Configuration PgBouncer simplifiée..."
    echo ""
    
    # Reconfigurer PgBouncer sur le leader seulement pour le moment
    echo -n "  PgBouncer sur leader: "
    ssh root@"$LEADER_IP" bash -s "$POSTGRES_PASSWORD" "$LEADER_IP" <<'PGBOUNCER'
PG_PASSWORD="$1"
LOCAL_IP="$2"

# Hash MD5 du mot de passe
MD5_HASH=$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d' ' -f1)

# Créer userlist simple
cat > /opt/keybuzz/pgbouncer/config/userlist.txt <<EOF
"postgres" "md5${MD5_HASH}"
EOF

# Config minimale
cat > /opt/keybuzz/pgbouncer/config/pgbouncer.ini <<EOF
[databases]
postgres = host=${LOCAL_IP} port=5432 dbname=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = session
max_client_conn = 100
default_pool_size = 20
admin_users = postgres
ignore_startup_parameters = extra_float_digits
EOF

chmod 600 /opt/keybuzz/pgbouncer/config/userlist.txt

# Redémarrer PgBouncer
docker stop pgbouncer 2>/dev/null
docker rm pgbouncer 2>/dev/null

docker run -d \
  --name pgbouncer \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/pgbouncer/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
  -v /opt/keybuzz/pgbouncer/config/userlist.txt:/etc/pgbouncer/userlist.txt:ro \
  pgbouncer:latest
PGBOUNCER
    echo -e "$OK"
    
    sleep 3
    
    # Test PgBouncer
    echo -n "  Test PgBouncer (port 6432): "
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$LEADER_IP" -p 6432 -U postgres -d postgres -c "SELECT 'PGBOUNCER_OK'" -t 2>/dev/null | grep -q PGBOUNCER_OK; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
else
    echo ""
    echo -e "  $KO Aucun leader trouvé. Le cluster ne s'est pas initialisé correctement."
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"

if [ -n "$LEADER_IP" ]; then
    echo -e "$OK Cluster PostgreSQL HA opérationnel"
    echo ""
    echo "Connexions fonctionnelles:"
    echo "  PostgreSQL: psql -h $LEADER_IP -p 5432 -U postgres"
    echo "  PgBouncer: psql -h $LEADER_IP -p 6432 -U postgres"
    echo "  Password: $POSTGRES_PASSWORD"
    echo ""
    echo "État du cluster:"
    curl -s "http://$LEADER_IP:8008/cluster" 2>/dev/null | python3 -m json.tool 2>/dev/null | head -20
else
    echo -e "$KO Le cluster a besoin d'être réinitialisé"
    echo ""
    echo "Relancez ce script ou vérifiez les logs:"
    echo "  ssh root@10.0.0.120 'docker logs patroni'"
fi

echo "═══════════════════════════════════════════════════════════════════"
