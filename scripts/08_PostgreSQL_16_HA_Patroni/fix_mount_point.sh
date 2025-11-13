#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX MOUNT POINT - Correction du point de montage Docker        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

echo ""
echo -e "$WARN Problème identifié :"
echo "  Le volume est monté directement sur /var/lib/postgresql/data"
echo "  → Le conteneur ne peut pas renommer ce répertoire (point de montage)"
echo ""
echo -e "$OK Solution :"
echo "  Monter le volume sur /var/lib/postgresql (parent)"
echo "  → PostgreSQL créera /var/lib/postgresql/data automatiquement"
echo ""

# Vérifier que le leader est bien actif
echo "→ Vérification du leader (10.0.0.120)"
if ! ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT 1' -t" 2>/dev/null | grep -q 1; then
    echo -e "$KO Leader non accessible"
    exit 1
fi
echo -e "  $OK Leader actif"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
read -p "Continuer avec la correction du point de montage ? (yes/NO): " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Replicas à corriger
REPLICAS=("10.0.0.121:db-slave-01" "10.0.0.122:db-slave-02")

for replica in "${REPLICAS[@]}"; do
    IFS=':' read -r ip name <<< "$replica"
    
    echo ""
    echo "═══ Correction $name ($ip) ═══"
    echo ""
    
    ssh root@"$ip" bash -s "$name" <<'FIXMOUNT'
set -e

NODE_NAME="$1"
OLD_MOUNT="/opt/keybuzz/postgres/data"
NEW_MOUNT="/opt/keybuzz/postgres"

echo "→ Arrêt du conteneur"
docker stop patroni 2>/dev/null || true
docker rm -f patroni 2>/dev/null || true
sleep 2
echo "  ✓ Conteneur arrêté"

echo "→ Vérification des montages actuels"
df -h | grep postgres

# Le volume est actuellement monté sur /opt/keybuzz/postgres/data
# On va le laisser tel quel mais changer le montage Docker

echo "→ Nettoyage complet du volume"
find "$OLD_MOUNT" -mindepth 1 -delete 2>/dev/null || true
rm -rf "$OLD_MOUNT"/* "$OLD_MOUNT"/.[!.]* 2>/dev/null || true

# Vérification
REMAINING=$(ls -A "$OLD_MOUNT" 2>/dev/null | wc -l)
if [ "$REMAINING" -eq 0 ]; then
    echo "  ✓ Volume complètement vide"
else
    echo "  ✗ Il reste $REMAINING fichiers"
    ls -la "$OLD_MOUNT"
    exit 1
fi

echo "→ Nettoyage RAFT et archives"
rm -rf /opt/keybuzz/postgres/raft/* 2>/dev/null || true
rm -rf /opt/keybuzz/postgres/archive/* 2>/dev/null || true

echo "→ Permissions"
chown -R 999:999 /opt/keybuzz/postgres
chmod 700 "$OLD_MOUNT"

echo "→ Redémarrage avec nouveau point de montage"
echo "  Ancien: -v $OLD_MOUNT:/var/lib/postgresql/data"
echo "  Nouveau: -v $NEW_MOUNT:/var/lib/postgresql"

# Créer le nouveau conteneur avec le montage sur le parent
docker run -d \
  --name patroni \
  --hostname $NODE_NAME \
  --network host \
  --restart unless-stopped \
  -v /opt/keybuzz/postgres:/var/lib/postgresql \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg16-raft:latest >/dev/null 2>&1

sleep 3
if docker ps | grep -q patroni; then
    echo "  ✓ Conteneur redémarré avec nouveau montage"
else
    echo "  ✗ Échec redémarrage"
    docker logs patroni 2>&1 | tail -20
    exit 1
fi
FIXMOUNT
    
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
echo "Attente basebackup et synchronisation (120 secondes)..."
echo "Le basebackup peut maintenant créer /var/lib/postgresql/data proprement"
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
        echo -e "$WARN En cours..."
        # Afficher les 5 dernières lignes pour voir la progression
        ssh root@"$ip" "docker logs patroni 2>&1 | tail -5" | sed 's/^/      /' | grep -E "(bootstrap|basebackup|streaming|replica)"
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
    curl -s http://10.0.0.120:8008/cluster | python3 -m json.tool 2>/dev/null
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Prochaine étape: bash 05_haproxy_db_CORRECTED.sh"
    exit 0
else
    echo -e "$WARN CLUSTER EN SYNCHRONISATION ($SUCCESS/3 nœuds)"
    echo ""
    echo "Les replicas sont probablement en train de faire le basebackup."
    echo ""
    echo "Attendez 2-3 minutes supplémentaires et vérifiez :"
    echo "  curl -s http://10.0.0.120:8008/cluster | python3 -m json.tool"
    echo ""
    echo "Ou suivez les logs :"
    echo "  ssh root@10.0.0.121 'docker logs -f patroni'"
    echo "  ssh root@10.0.0.122 'docker logs -f patroni'"
    exit 1
fi
