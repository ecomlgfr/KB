#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  FIX WALDIR - Suppression du waldir séparé dans basebackup        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

echo ""
echo -e "$WARN Problème identifié :"
echo "  pg_basebackup essaie de créer un lien symbolique pg_wal"
echo "  → Échoue car le répertoire est un point de montage"
echo ""
echo -e "$OK Solution :"
echo "  Supprimer la ligne 'waldir' de la config Patroni"
echo "  → pg_basebackup créera pg_wal comme répertoire normal"
echo ""

# Vérifier que le leader est actif
echo "→ Vérification du leader (10.0.0.120)"
if ! ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT 1' -t" 2>/dev/null | grep -q 1; then
    echo -e "$KO Leader non accessible"
    exit 1
fi
echo -e "  $OK Leader actif"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
read -p "Continuer avec la correction de la config Patroni ? (yes/NO): " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Replicas à corriger
REPLICAS=("10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")

for replica in "${REPLICAS[@]}"; do
    IFS=':' read -r ip name <<< "$replica"
    
    echo ""
    echo "═══ Correction $name ($ip) ═══"
    echo ""
    
    ssh root@"$ip" bash -s "$name" <<'FIXWALDIR'
set -e

NODE_NAME="$1"
PATRONI_YML="/opt/keybuzz/patroni/config/patroni.yml"

echo "→ Arrêt du conteneur"
docker stop patroni 2>/dev/null || true
docker rm -f patroni 2>/dev/null || true
sleep 2
echo "  ✓ Conteneur arrêté"

echo "→ Modification de patroni.yml"
# Supprimer la section basebackup qui contient waldir
if grep -q "waldir:" "$PATRONI_YML"; then
    echo "  Suppression de la ligne waldir..."
    sed -i '/waldir:/d' "$PATRONI_YML"
    sed -i '/basebackup:/d' "$PATRONI_YML"
    echo "  ✓ Configuration modifiée"
else
    echo "  ✓ Pas de waldir dans la config"
fi

echo "→ Nettoyage complet du volume"
DATA_DIR="/opt/keybuzz/postgres/data"

# Arrêter tous les processus qui pourraient utiliser le répertoire
fuser -k "$DATA_DIR" 2>/dev/null || true
sleep 2

# Nettoyage brutal
find "$DATA_DIR" -mindepth 1 -delete 2>/dev/null || true
rm -rf "$DATA_DIR"/* "$DATA_DIR"/.[!.]* 2>/dev/null || true
rm -rf "$DATA_DIR"/pg_wal 2>/dev/null || true
unlink "$DATA_DIR"/pg_wal 2>/dev/null || true

# Vérification
REMAINING=$(ls -A "$DATA_DIR" 2>/dev/null | wc -l)
if [ "$REMAINING" -eq 0 ]; then
    echo "  ✓ Volume complètement vide"
else
    echo "  ⚠ Il reste $REMAINING éléments"
    ls -la "$DATA_DIR"
fi

echo "→ Nettoyage RAFT et archives"
rm -rf /opt/keybuzz/postgres/raft/* 2>/dev/null || true
rm -rf /opt/keybuzz/postgres/archive/* 2>/dev/null || true

echo "→ Permissions"
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 "$DATA_DIR"

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
FIXWALDIR
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $name corrigé"
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
echo "Attente basebackup (120 secondes)..."
echo "Le basebackup va maintenant créer pg_wal comme répertoire normal"
echo ""

for i in {120..1}; do
    echo -ne "  Temps restant: ${i}s\r"
    sleep 1
done
echo ""

echo ""
echo "═══ Vérification du cluster ═══"
echo ""

SUCCESS=0

for node in "10.0.0.120:db-master-01" "10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02"; do
    IFS=':' read -r ip name <<< "$node"
    echo -n "  $name ($ip): "
    
    if ! ssh root@"$ip" "docker ps | grep -q patroni"; then
        echo -e "$KO conteneur arrêté"
        continue
    fi
    
    if ssh root@"$ip" "docker exec patroni pg_isready -U postgres" 2>/dev/null | grep -q "accepting connections"; then
        IS_LEADER=$(ssh root@"$ip" "docker exec patroni psql -U postgres -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null" | xargs)
        
        if [ "$IS_LEADER" = "f" ]; then
            echo -e "$OK Leader"
        else
            echo -e "$OK Replica"
        fi
        ((SUCCESS++))
    else
        echo -e "$WARN En cours..."
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"

if [ $SUCCESS -eq 3 ]; then
    echo -e "$OK CLUSTER OPÉRATIONNEL ($SUCCESS/3 nœuds)"
    echo ""
    ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"
    echo ""
    curl -s http://10.0.0.120:8008/cluster | python3 -m json.tool 2>/dev/null
    echo ""
    echo "Prochaine étape: bash 05_haproxy_db_CORRECTED.sh"
    exit 0
else
    echo -e "$WARN Cluster en synchronisation ($SUCCESS/3 nœuds)"
    echo ""
    echo "Vérifier dans 2-3 minutes ou suivre les logs :"
    echo "  ssh root@10.0.0.121 'docker logs -f patroni'"
    exit 1
fi
