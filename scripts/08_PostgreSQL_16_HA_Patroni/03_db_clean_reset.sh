#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          03_DB_CLEAN_RESET - Nettoyage complet nœuds DB            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'; WARN='\033[0;33m⚠\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

DB_NODES=(db-master-01 db-slave-01 db-slave-02)

echo ""
echo "═══ Nettoyage des nœuds DB ═══"
echo ""
echo -e "$WARN Cette opération va :"
echo "  • Arrêter tous les conteneurs PostgreSQL/Patroni/etcd"
echo "  • PRÉSERVER les volumes de données"
echo "  • Nettoyer les configurations"
echo ""
read -p "Confirmer le nettoyage? (yes/NO): " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

for node in "${DB_NODES[@]}"; do
    IP=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    [ -z "$IP" ] && { echo -e "$KO $node IP introuvable"; continue; }
    
    echo ""
    echo "→ Nettoyage $node ($IP)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'CLEAN'
set -u

# Arrêter tous les conteneurs DB
docker stop patroni postgres etcd 2>/dev/null || true
docker rm -f patroni postgres etcd 2>/dev/null || true

# Nettoyer les configs (PAS les données)
rm -rf /opt/keybuzz/patroni/config/* 2>/dev/null || true
rm -rf /opt/keybuzz/postgres/raft/* 2>/dev/null || true
rm -f /opt/keybuzz/postgres/data/postmaster.pid 2>/dev/null || true

# Recréer la structure
mkdir -p /opt/keybuzz/postgres/{data,raft,archive,config,logs,status}
mkdir -p /opt/keybuzz/patroni/{config,logs}

# Permissions
chown -R 999:999 /opt/keybuzz/postgres 2>/dev/null || true
chmod 700 /opt/keybuzz/postgres/data 2>/dev/null || true
chmod 755 /opt/keybuzz/postgres/raft 2>/dev/null || true

# Vérifier le volume
if mountpoint -q /opt/keybuzz/postgres/data; then
    echo "  ✓ Volume monté (données préservées)"
    df -h /opt/keybuzz/postgres/data | tail -1
else
    echo "  ⚠ Volume non monté"
fi

# Nettoyer les images obsolètes
docker images | grep -E "(postgres|patroni|etcd)" | grep -v "postgres:16" | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true

echo "  ✓ Nettoyage terminé"
CLEAN
    
    [ $? -eq 0 ] && echo -e "  $OK" || echo -e "  $KO"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Nettoyage terminé"
echo ""
echo "Prochaine étape: ./04_postgres16_patroni_raft.sh"
echo "═══════════════════════════════════════════════════════════════════"
