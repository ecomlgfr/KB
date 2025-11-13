#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         TEST_FAILOVER_SAFE - Test Failover Sans Blocage Réseau     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)

# Charger credentials
if [ -f /opt/keybuzz-installer/credentials/secrets.json ]; then
    PATRONI_PASSWORD=$(jq -r '.patroni.password // .postgres.password' /opt/keybuzz-installer/credentials/secrets.json)
else
    source /opt/keybuzz-installer/credentials/postgres.env
    PATRONI_PASSWORD="${PATRONI_PASSWORD:-$POSTGRES_PASSWORD}"
fi

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo ""
echo "═══ Test de Failover Sécurisé (sans blocage réseau) ═══"
echo ""

# 1. État initial
echo "1. État initial du cluster:"
CLUSTER_INFO=$(curl -s -u patroni:$PATRONI_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null)
echo "$CLUSTER_INFO" | jq '.members[] | {name: .name, role: .role, state: .state, lag: .lag}'

# Identifier le leader
LEADER=""
LEADER_IP=""
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    ROLE=$(curl -s -u patroni:$PATRONI_PASSWORD "http://$ip:8008/patroni" 2>/dev/null | jq -r '.role // ""')
    if [[ "$ROLE" == "master" ]] || [[ "$ROLE" == "leader" ]] || [[ "$ROLE" == "primary" ]]; then
        LEADER="$node"
        LEADER_IP="$ip"
        echo ""
        echo -e "Leader actuel: $OK $LEADER ($LEADER_IP)"
        break
    fi
done

if [ -z "$LEADER" ]; then
    echo -e "$KO Aucun leader trouvé"
    exit 1
fi

echo ""
echo "2. Test de failover par ARRÊT PROPRE du container"
echo -e "${WARN} Cette méthode:"
echo "  • Arrête le container Patroni sur $LEADER"
echo "  • Laisse le réseau intact (SSH reste accessible)"
echo "  • Permet un redémarrage automatique après 60s"
echo ""
read -p "Continuer? (yes/NO): " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# 3. Créer un script de redémarrage automatique
echo ""
echo "3. Installation du redémarrage automatique..."
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" bash <<'AUTO_RESTART'
cat > /tmp/auto_restart_patroni.sh <<'SCRIPT'
#!/bin/bash
sleep 60
if ! docker ps | grep -q patroni; then
    docker start patroni 2>/dev/null || \
    docker run -d --name patroni --hostname $(hostname) --network host --restart unless-stopped \
      -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
      -v /opt/keybuzz/patroni/config:/etc/patroni \
      patroni-pg17:latest
fi
rm -f /tmp/auto_restart_patroni.sh
SCRIPT
chmod +x /tmp/auto_restart_patroni.sh
nohup /tmp/auto_restart_patroni.sh > /dev/null 2>&1 &
echo "Script de redémarrage lancé (60s)"
AUTO_RESTART

# 4. Arrêter le container du leader
echo ""
echo "4. Arrêt du container Patroni sur $LEADER..."
ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" "docker stop patroni" 2>/dev/null

echo "  Attente élection nouveau leader (30s)..."
sleep 30

# 5. Vérifier nouveau leader
echo ""
echo "5. Identification du nouveau leader..."
NEW_LEADER=""
NEW_LEADER_IP=""

for node in "${DB_NODES[@]}"; do
    [ "$node" = "$LEADER" ] && continue
    ip="${NODE_IPS[$node]}"
    
    ROLE=$(curl -s -u patroni:$PATRONI_PASSWORD "http://$ip:8008/patroni" 2>/dev/null | jq -r '.role // ""')
    if [[ "$ROLE" == "master" ]] || [[ "$ROLE" == "leader" ]] || [[ "$ROLE" == "primary" ]]; then
        NEW_LEADER="$node"
        NEW_LEADER_IP="$ip"
        echo -e "  Nouveau leader: $OK $NEW_LEADER ($NEW_LEADER_IP)"
        break
    fi
done

if [ -z "$NEW_LEADER" ]; then
    echo -e "  $KO Failover échoué"
    echo "  Redémarrage manuel du leader..."
    ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" "docker start patroni" 2>/dev/null
    exit 1
fi

# 6. Test d'écriture
echo ""
echo "6. Test d'écriture sur nouveau leader..."
ssh -o StrictHostKeyChecking=no root@"$NEW_LEADER_IP" \
    "docker exec patroni psql -U postgres -d postgres -c \"
    CREATE TABLE IF NOT EXISTS test_failover (id serial, ts timestamp default now(), leader text);
    INSERT INTO test_failover (leader) VALUES ('$NEW_LEADER') RETURNING *;
    \"" 2>/dev/null

# 7. Attendre redémarrage automatique
echo ""
echo "7. Attente redémarrage automatique de $LEADER (30s restantes)..."
sleep 30

# 8. Vérifier état final
echo ""
echo "8. État final du cluster:"
FINAL_STATE=$(curl -s -u patroni:$PATRONI_PASSWORD "http://${NODE_IPS[db-master-01]}:8008/cluster" 2>/dev/null)

if [ -n "$FINAL_STATE" ]; then
    echo "$FINAL_STATE" | jq '.members[] | {name: .name, role: .role, state: .state, lag: .lag}'
    
    # Vérifier que l'ancien leader est revenu comme replica
    OLD_LEADER_STATE=$(echo "$FINAL_STATE" | jq -r ".members[] | select(.name==\"$LEADER\") | .state")
    if [[ "$OLD_LEADER_STATE" == "streaming" ]] || [[ "$OLD_LEADER_STATE" == "running" ]]; then
        echo ""
        echo -e "$OK L'ancien leader ($LEADER) est de retour"
    else
        echo ""
        echo -e "$WARN L'ancien leader ($LEADER) n'est pas encore revenu"
        echo "  Vérification manuelle..."
        ssh -o StrictHostKeyChecking=no root@"$LEADER_IP" "docker ps | grep patroni || docker start patroni"
    fi
else
    echo -e "$WARN Impossible de récupérer l'état du cluster"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK TEST DE FAILOVER SÉCURISÉ TERMINÉ"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Résumé:"
echo "  • Méthode: Arrêt container (pas de blocage réseau)"
echo "  • Ancien leader: $LEADER"
echo "  • Nouveau leader: $NEW_LEADER"
echo "  • Temps de bascule: ~30 secondes"
echo "  • Redémarrage automatique: Oui (après 60s)"
echo ""
echo "Pour revenir à l'état initial (optionnel):"
echo "  curl -u patroni:$PATRONI_PASSWORD -X POST http://$NEW_LEADER_IP:8008/switchover \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"leader\":\"$NEW_LEADER\",\"candidate\":\"$LEADER\"}'"
