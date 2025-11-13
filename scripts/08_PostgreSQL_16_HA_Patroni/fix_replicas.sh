#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           FIX REPLICAS - Rejoindre le cluster existant            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

# Vérifier que le leader est bien actif
echo ""
echo "→ Vérification du leader (10.0.0.120)"
if ! ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT 1' -t" 2>/dev/null | grep -q 1; then
    echo -e "$KO Leader non accessible"
    exit 1
fi
echo -e "  $OK Leader actif"

# Vérifier l'API Patroni
echo ""
echo "→ Vérification API Patroni"
if ! curl -s http://10.0.0.120:8008/health 2>/dev/null | grep -q "running"; then
    echo -e "$KO API Patroni non accessible"
    exit 1
fi
echo -e "  $OK API Patroni active"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo -e "$WARN Ce script va :"
echo "  1. Arrêter les conteneurs replicas"
echo "  2. Supprimer les données PostgreSQL des replicas (PAS le leader !)"
echo "  3. Nettoyer les données RAFT"
echo "  4. Redémarrer les replicas qui vont se synchroniser via basebackup"
echo ""
read -p "Continuer ? (yes/NO): " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Replicas à corriger
REPLICAS=("10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")

for replica in "${REPLICAS[@]}"; do
    IFS=':' read -r ip name <<< "$replica"
    
    echo ""
    echo "═══ Correction $name ($ip) ═══"
    echo ""
    
    # 1. Arrêter le conteneur
    echo "→ Arrêt du conteneur"
    ssh root@"$ip" "docker stop patroni 2>/dev/null; docker rm -f patroni 2>/dev/null" || true
    echo -e "  $OK Conteneur arrêté"
    
    # 2. Nettoyer les données PostgreSQL (garder le répertoire)
    echo "→ Nettoyage des données PostgreSQL"
    ssh root@"$ip" bash <<'CLEAN'
# Vérifier que le volume est monté
if ! mountpoint -q /opt/keybuzz/postgres/data; then
    echo "  ✗ Volume non monté"
    exit 1
fi

# Supprimer TOUT sauf le répertoire lui-même
find /opt/keybuzz/postgres/data -mindepth 1 -delete 2>/dev/null || true

echo "  ✓ Données supprimées"
CLEAN
    
    # 3. Nettoyer RAFT
    echo "→ Nettoyage RAFT"
    ssh root@"$ip" "rm -rf /opt/keybuzz/postgres/raft/* 2>/dev/null" || true
    echo -e "  $OK RAFT nettoyé"
    
    # 4. Vérifier les permissions
    echo "→ Vérification permissions"
    ssh root@"$ip" bash <<'PERMS'
chown -R 999:999 /opt/keybuzz/postgres 2>/dev/null || true
chmod 700 /opt/keybuzz/postgres/data 2>/dev/null || true
chmod 755 /opt/keybuzz/postgres/raft 2>/dev/null || true
echo "  ✓ Permissions OK"
PERMS
    
    # 5. Redémarrer le conteneur
    echo "→ Redémarrage du conteneur"
    ssh root@"$ip" bash -s "$name" <<'START'
NODE_NAME="$1"

docker run -d \
  --name patroni \
  --hostname $NODE_NAME \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/postgres/archive:/opt/keybuzz/postgres/archive \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg16-raft:latest >/dev/null 2>&1

sleep 3
if docker ps | grep -q patroni; then
    echo "  ✓ Conteneur redémarré"
else
    echo "  ✗ Échec redémarrage"
    docker logs patroni 2>&1 | tail -20
    exit 1
fi
START
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK Replica redémarrée"
    else
        echo -e "  $KO Échec"
        exit 1
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Attente synchronisation des replicas (60 secondes)..."
sleep 60

echo ""
echo "═══ Vérification du cluster ═══"
echo ""

SUCCESS=0
for node in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip name <<< "$node"
    echo -n "  $name ($ip): "
    
    # Test conteneur
    if ! ssh root@"$ip" "docker ps | grep -q patroni"; then
        echo -e "$KO conteneur arrêté"
        continue
    fi
    
    # Test connexion
    if ssh root@"$ip" "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
        
        # Vérifier le rôle
        IS_LEADER=$(ssh root@"$ip" "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
        
        if [ "$IS_LEADER" = "f" ]; then
            echo -e "$OK Leader"
        else
            echo -e "$OK Replica"
        fi
        ((SUCCESS++))
    else
        echo -e "$KO Non prêt"
        echo "    Logs (10 dernières lignes):"
        ssh root@"$ip" "docker logs patroni 2>&1 | tail -10" | sed 's/^/      /'
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"

if [ $SUCCESS -eq 3 ]; then
    echo -e "$OK CLUSTER OPÉRATIONNEL ($SUCCESS/3 nœuds)"
    echo ""
    echo "Vérification de la réplication:"
    ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"
    echo ""
    echo "API Patroni:"
    curl -s http://10.0.0.120:8008/cluster | python3 -m json.tool 2>/dev/null || curl -s http://10.0.0.120:8008/cluster
    exit 0
else
    echo -e "$WARN CLUSTER PARTIELLEMENT OPÉRATIONNEL ($SUCCESS/3 nœuds)"
    echo ""
    echo "Pour plus de détails, exécuter: ./diagnose_cluster.sh"
    exit 1
fi
