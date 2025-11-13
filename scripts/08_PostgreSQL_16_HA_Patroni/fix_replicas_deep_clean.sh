#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║      FIX REPLICAS DEEP CLEAN - Nettoyage profond depuis l'hôte    ║"
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

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo -e "$WARN Ce script va effectuer un nettoyage PROFOND :"
echo "  1. Arrêter les conteneurs replicas"
echo "  2. Démonter temporairement les volumes (si besoin)"
echo "  3. Nettoyer COMPLÈTEMENT les données depuis l'hôte"
echo "  4. Remonter les volumes"
echo "  5. Redémarrer les replicas avec basebackup propre"
echo ""
read -p "Continuer ? (yes/NO): " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Replicas à corriger
REPLICAS=("10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")

for replica in "${REPLICAS[@]}"; do
    IFS=':' read -r ip name <<< "$replica"
    
    echo ""
    echo "═══ Nettoyage profond $name ($ip) ═══"
    echo ""
    
    ssh root@"$ip" bash -s "$name" <<'DEEPCLEAN'
set -e

NODE_NAME="$1"
DATA_DIR="/opt/keybuzz/postgres/data"

echo "→ Arrêt du conteneur Patroni"
docker stop patroni 2>/dev/null || true
docker rm -f patroni 2>/dev/null || true
sleep 2
echo "  ✓ Conteneur arrêté"

echo "→ Vérification du point de montage"
if mountpoint -q "$DATA_DIR"; then
    echo "  ✓ Volume monté sur $DATA_DIR"
    
    # Obtenir le device
    DEVICE=$(df "$DATA_DIR" | tail -1 | awk '{print $1}')
    echo "    Device: $DEVICE"
    
    # Nettoyer TOUS les fichiers (y compris pg_wal)
    echo "→ Nettoyage COMPLET des données (depuis l'hôte)"
    echo "  Suppression de tous les fichiers et répertoires..."
    
    # Forcer la suppression de tout, y compris les liens symboliques
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    
    # Double vérification : si pg_wal existe encore
    if [ -e "$DATA_DIR/pg_wal" ] || [ -L "$DATA_DIR/pg_wal" ]; then
        echo "  Suppression forcée de pg_wal..."
        rm -rf "$DATA_DIR/pg_wal" 2>/dev/null || true
        unlink "$DATA_DIR/pg_wal" 2>/dev/null || true
    fi
    
    # Vérifier que c'est vraiment vide
    REMAINING=$(ls -A "$DATA_DIR" 2>/dev/null | wc -l)
    if [ "$REMAINING" -eq 0 ]; then
        echo "  ✓ Répertoire complètement vide"
    else
        echo "  ⚠ Il reste $REMAINING fichiers/répertoires"
        ls -la "$DATA_DIR"
        
        # Tentative ultime
        echo "  Tentative ultime de nettoyage..."
        cd /tmp
        umount "$DATA_DIR" 2>/dev/null || true
        sleep 2
        rm -rf "$DATA_DIR"/*
        rm -rf "$DATA_DIR"/.[!.]* 2>/dev/null || true
        mount "$DEVICE" "$DATA_DIR"
        
        REMAINING=$(ls -A "$DATA_DIR" 2>/dev/null | wc -l)
        if [ "$REMAINING" -eq 0 ]; then
            echo "  ✓ Nettoyage réussi après démontage"
        else
            echo "  ✗ Impossible de nettoyer complètement"
            exit 1
        fi
    fi
else
    echo "  ✗ Volume non monté"
    exit 1
fi

echo "→ Nettoyage RAFT"
rm -rf /opt/keybuzz/postgres/raft/* 2>/dev/null || true
echo "  ✓ RAFT nettoyé"

echo "→ Nettoyage archive"
rm -rf /opt/keybuzz/postgres/archive/* 2>/dev/null || true
echo "  ✓ Archive nettoyé"

echo "→ Vérification permissions"
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 "$DATA_DIR"
chmod 755 /opt/keybuzz/postgres/raft
chmod 755 /opt/keybuzz/postgres/archive
echo "  ✓ Permissions OK"

echo "→ Vérification finale"
ls -la "$DATA_DIR"
echo ""

echo "→ Redémarrage du conteneur"
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
DEEPCLEAN
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $name nettoyé et redémarré"
    else
        echo -e "  $KO Échec sur $name"
        exit 1
    fi
    
    echo ""
    echo "  Pause de 10s avant le prochain nœud..."
    sleep 10
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Attente basebackup et synchronisation (90 secondes)..."
echo ""

for i in {90..1}; do
    echo -ne "  Temps restant: ${i}s\r"
    sleep 1
done
echo ""

echo ""
echo "═══ Vérification du cluster ═══"
echo ""

SUCCESS=0
declare -A NODE_STATUS

for node in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip name <<< "$node"
    echo -n "  $name ($ip): "
    
    # Test conteneur
    if ! ssh root@"$ip" "docker ps | grep -q patroni"; then
        echo -e "$KO conteneur arrêté"
        NODE_STATUS[$name]="stopped"
        continue
    fi
    
    # Test connexion
    if ssh root@"$ip" "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
        
        # Vérifier le rôle
        IS_LEADER=$(ssh root@"$ip" "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
        
        if [ "$IS_LEADER" = "f" ]; then
            echo -e "$OK Leader"
            NODE_STATUS[$name]="leader"
        else
            echo -e "$OK Replica"
            NODE_STATUS[$name]="replica"
        fi
        ((SUCCESS++))
    else
        echo -e "$KO Non prêt"
        NODE_STATUS[$name]="not_ready"
        
        # Afficher les dernières lignes des logs
        echo "    Derniers logs:"
        ssh root@"$ip" "docker logs patroni 2>&1 | tail -15" | sed 's/^/      /'
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"

if [ $SUCCESS -eq 3 ]; then
    echo -e "$OK CLUSTER OPÉRATIONNEL ($SUCCESS/3 nœuds)"
    echo ""
    echo "Vérification de la réplication PostgreSQL:"
    ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;'"
    echo ""
    echo "État du cluster Patroni:"
    curl -s http://10.0.0.120:8008/cluster | python3 -m json.tool 2>/dev/null || curl -s http://10.0.0.120:8008/cluster
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Prochaine étape: bash 05_haproxy_db_CORRECTED.sh"
    exit 0
elif [ $SUCCESS -eq 2 ]; then
    echo -e "$WARN CLUSTER PARTIELLEMENT OPÉRATIONNEL ($SUCCESS/3 nœuds)"
    echo ""
    echo "Conseil: Attendez encore 60-90 secondes, le basebackup peut prendre du temps."
    echo "Ensuite, relancez: ./diagnose_cluster.sh"
    exit 1
else
    echo -e "$KO CLUSTER NON OPÉRATIONNEL ($SUCCESS/3 nœuds)"
    echo ""
    echo "Pour débugger, exécutez:"
    echo "  ./diagnose_cluster.sh"
    echo ""
    echo "Logs détaillés des replicas:"
    for node in "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
        IFS=':' read -r ip name <<< "$node"
        if [ "${NODE_STATUS[$name]:-}" != "leader" ] && [ "${NODE_STATUS[$name]:-}" != "replica" ]; then
            echo ""
            echo "=== $name ===" 
            ssh root@"$ip" "docker logs patroni 2>&1 | tail -30"
        fi
    done
    exit 1
fi
