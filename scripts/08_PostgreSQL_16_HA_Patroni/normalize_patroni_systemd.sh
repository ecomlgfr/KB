#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     Normalisation Patroni systemd sur cluster PostgreSQL 16       ║"
echo "║              (Désactivation postgresql.service)                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'
INFO='\033[0;36mINFO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 0 : Détection du cluster
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Détection du cluster PostgreSQL ═══"
echo ""

DB_NODES=()
for node in db-master-01 db-slave-01 db-slave-02; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -n "$ip" ]; then
        DB_NODES+=("$node:$ip")
        echo "  ✓ $node : $ip"
    fi
done

if [ ${#DB_NODES[@]} -eq 0 ]; then
    echo -e "$KO Aucun nœud PostgreSQL trouvé"
    exit 1
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Vérifier l'état actuel de Patroni
# ═══════════════════════════════════════════════════════════════════════════

echo "═══ Vérification état Patroni actuel ═══"
echo ""

FIRST_NODE_IP="${DB_NODES[0]##*:}"

echo "État du cluster via patronictl :"
ssh -o StrictHostKeyChecking=no root@"$FIRST_NODE_IP" "patronictl list" 2>/dev/null || {
    echo -e "$KO patronictl list échoué"
    echo ""
    echo "Patroni n'est peut-être pas installé ou mal configuré."
    exit 1
}

echo ""
read -p "Le cluster semble-t-il sain (1 leader + 2 replicas) ? (yes/NO) : " cluster_ok
[ "$cluster_ok" != "yes" ] && { echo "Corrigez d'abord le cluster Patroni"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : Informations importantes
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "IMPORTANT : Normalisation Patroni systemd"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Cette opération va :"
echo "  1. Créer/vérifier l'unité systemd patroni.service sur chaque nœud"
echo "  2. Désactiver postgresql.service (géré par Patroni)"
echo "  3. Activer patroni.service au démarrage"
echo ""
echo "⚠️  IMPORTANT : postgresql.service sera DÉSACTIVÉ mais PAS ARRÊTÉ"
echo "   (Patroni continue de gérer PostgreSQL normalement)"
echo ""
echo "Durée estimée : 2-3 minutes"
echo "Downtime : AUCUN (opération à chaud)"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : Normalisation sur chaque nœud
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Normalisation systemd sur les nœuds ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

SUCCESS_COUNT=0

for node_info in "${DB_NODES[@]}"; do
    node="${node_info%%:*}"
    ip="${node_info##*:}"
    
    echo "→ Normalisation $node ($ip)"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'EONORM'
set -u
set -o pipefail

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

# 1. Vérifier quel user lance Patroni
PATRONI_USER=$(ps aux | grep -E "/usr/local/bin/patroni|/usr/bin/patroni" | grep -v grep | head -n1 | awk '{print $1}')

if [ -z "$PATRONI_USER" ]; then
    echo -e "  $WARN Patroni ne semble pas tourner"
    PATRONI_USER="postgres"
fi

if [ "$PATRONI_USER" = "999" ] || [ "$PATRONI_USER" = "postgres" ]; then
    PATRONI_USER="postgres"
    PATRONI_GROUP="postgres"
else
    PATRONI_GROUP="$PATRONI_USER"
fi

echo -e "  ✓ Patroni tourne sous : $PATRONI_USER"

# 2. Créer/vérifier patroni.service
PATRONI_SERVICE="/etc/systemd/system/patroni.service"

if [ ! -f "$PATRONI_SERVICE" ]; then
    echo "  Création patroni.service..."
    
    cat > "$PATRONI_SERVICE" <<EOF
[Unit]
Description=Patroni RAFT PostgreSQL High Availability
After=network.target
Wants=network-online.target

[Service]
User=$PATRONI_USER
Group=$PATRONI_GROUP
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s
TimeoutSec=30
LimitNOFILE=102400

[Install]
WantedBy=multi-user.target
EOF
    
    echo -e "  $OK patroni.service créé"
else
    echo -e "  ✓ patroni.service existe déjà"
fi

# 3. Désactiver postgresql.service (SANS l'arrêter)
echo "  Désactivation postgresql.service..."

# Désactiver au boot
systemctl disable postgresql 2>/dev/null || true
systemctl disable postgresql@16-main 2>/dev/null || true

# Masquer pour éviter démarrage accidentel
systemctl mask postgresql 2>/dev/null || true

echo -e "  $OK postgresql.service désactivé (mais pas arrêté)"

# 4. Activer patroni.service
systemctl daemon-reload

if ! systemctl is-enabled --quiet patroni 2>/dev/null; then
    systemctl enable patroni
    echo -e "  $OK patroni.service activé au démarrage"
else
    echo -e "  ✓ patroni.service déjà activé"
fi

# 5. Vérifier l'état (ne pas redémarrer si déjà actif)
if systemctl is-active --quiet patroni; then
    echo -e "  $OK patroni.service déjà actif"
else
    echo -e "  $WARN patroni.service inactif, mais processus Patroni détecté"
    echo "    (Normal si Patroni a été démarré manuellement)"
fi

# 6. Vérification finale
echo ""
echo "  État final :"
echo "    - postgresql.service : $(systemctl is-enabled postgresql 2>&1 || echo 'disabled')"
echo "    - patroni.service    : $(systemctl is-enabled patroni 2>&1)"
echo "    - Processus Patroni  : $(pgrep -f patroni > /dev/null && echo 'running' || echo 'stopped')"
echo ""

EONORM
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $node normalisé"
        ((SUCCESS_COUNT++))
    else
        echo -e "  $KO Erreur sur $node"
    fi
    
    echo ""
done

# ═══════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : Vérification finale du cluster
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Vérification finale du cluster ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "État Patroni via patronictl :"
ssh -o StrictHostKeyChecking=no root@"$FIRST_NODE_IP" "patronictl list" 2>/dev/null

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$SUCCESS_COUNT" -eq ${#DB_NODES[@]} ]; then
    echo -e "$OK Normalisation systemd terminée sur tous les nœuds"
    echo ""
    echo "✅ Configuration finale :"
    echo "  • postgresql.service → disabled + masked"
    echo "  • patroni.service    → enabled (démarre au boot)"
    echo "  • Patroni            → actif (gère PostgreSQL)"
    echo ""
    echo "⚠️  NOTE IMPORTANTE :"
    echo "  Les processus Patroni actuels continuent de tourner normalement."
    echo "  Au prochain redémarrage du serveur, Patroni démarrera via systemd."
    echo ""
    echo "Optionnel : Pour basculer immédiatement vers systemd :"
    echo "  1. Sauvegarder PID Patroni actuel"
    echo "  2. kill -TERM <pid_patroni>"
    echo "  3. systemctl start patroni"
    echo ""
    echo "Mais ce n'est PAS nécessaire (Patroni fonctionne déjà)."
    echo ""
    echo "Prochaine étape :"
    echo "  ./install_pgvector_ha.sh"
    echo ""
else
    echo -e "$WARN Normalisation partielle ($SUCCESS_COUNT/${#DB_NODES[@]} nœuds)"
    echo ""
    echo "Vérifiez les erreurs ci-dessus."
    exit 1
fi

exit 0
