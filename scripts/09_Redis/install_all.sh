#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       INSTALL_ALL - Installation automatique Redis + RabbitMQ      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'; KO='\033[0;31mKO\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "Installation complète Redis HA + RabbitMQ HA"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Répertoire: $SCRIPT_DIR"
echo ""

# ═══════════════════════════════════════════════════════════════════
# VÉRIFICATIONS PRÉALABLES
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ Vérifications préalables                                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ ! -f "$SCRIPT_DIR/redis_ha_install_final_PATCHED.sh" ]; then
    echo -e "$KO redis_ha_install_final_PATCHED.sh introuvable"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/rabbitmq_ha_install_PATCHED.sh" ]; then
    echo -e "$KO rabbitmq_ha_install_PATCHED.sh introuvable"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/diagnostic_redis_rmq_V2.sh" ]; then
    echo -e "$KO diagnostic_redis_rmq_V2.sh introuvable"
    exit 1
fi

echo -e "  $OK Tous les scripts sont présents"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1: NETTOYAGE (OPTIONNEL)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Nettoyage des anciens containers (optionnel)          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

read -p "Voulez-vous nettoyer les anciens containers ? (o/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Oo]$ ]]; then
    if [ -f "$SCRIPT_DIR/cleanup_redis_rabbitmq.sh" ]; then
        chmod +x "$SCRIPT_DIR/cleanup_redis_rabbitmq.sh"
        "$SCRIPT_DIR/cleanup_redis_rabbitmq.sh"
    else
        echo "  ⚠️  cleanup_redis_rabbitmq.sh introuvable, on passe"
    fi
else
    echo "  → Nettoyage ignoré"
fi

echo ""
sleep 2

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2: INSTALLATION REDIS HA
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Installation Redis HA (3 nœuds + Sentinel + Watcher)  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

chmod +x "$SCRIPT_DIR/redis_ha_install_final_PATCHED.sh"

if "$SCRIPT_DIR/redis_ha_install_final_PATCHED.sh"; then
    echo ""
    echo -e "$OK Redis HA installé avec succès"
else
    echo ""
    echo -e "$KO Échec installation Redis HA"
    exit 1
fi

echo ""
sleep 5

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3: INSTALLATION RABBITMQ HA
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Installation RabbitMQ HA (3 nœuds + Quorum)           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

chmod +x "$SCRIPT_DIR/rabbitmq_ha_install_PATCHED.sh"

if "$SCRIPT_DIR/rabbitmq_ha_install_PATCHED.sh"; then
    echo ""
    echo -e "$OK RabbitMQ HA installé avec succès"
else
    echo ""
    echo -e "$KO Échec installation RabbitMQ HA"
    exit 1
fi

echo ""
sleep 5

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4: ATTENTE STABILISATION
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Attente stabilisation des services (30s)              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

for i in {30..1}; do
    echo -ne "  Attente: $i secondes restantes...\r"
    sleep 1
done
echo -e "\n  $OK Services stabilisés"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 5: DIAGNOSTIC COMPLET
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Diagnostic complet (15 tests)                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

chmod +x "$SCRIPT_DIR/diagnostic_redis_rmq_V2.sh"

if "$SCRIPT_DIR/diagnostic_redis_rmq_V2.sh"; then
    echo ""
    echo -e "$OK Diagnostic réussi"
else
    echo ""
    echo -e "$KO Diagnostic a détecté des problèmes"
    echo "  Vérifier les logs pour plus de détails"
    exit 1
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ INSTALLATION COMPLÈTE TERMINÉE                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "  ✅ Redis HA installé et opérationnel"
echo "     • Endpoint: 10.0.0.10:6379"
echo "     • Watcher Sentinel: ACTIF"
echo "     • Bind IP privée: SÉCURISÉ"
echo ""
echo "  ✅ RabbitMQ HA installé et opérationnel"
echo "     • Endpoint AMQP: 10.0.0.10:5672"
echo "     • Management UI: 10.0.0.10:15672 (SSH tunnel)"
echo "     • Quorum par défaut: ACTIVÉ"
echo ""

echo "  📁 Credentials:"
echo "     • Redis: /opt/keybuzz-installer/credentials/redis.env"
echo "     • RabbitMQ: /opt/keybuzz-installer/credentials/rabbitmq.env"
echo ""

echo "  📚 Documentation:"
echo "     • Configuration n8n/Chatwoot: README_N8N_CHATWOOT.md"
echo "     • Détails techniques: CORRECTIFS_APPLIQUES.md"
echo ""

echo "  🧪 Tests manuels recommandés:"
echo "     1. Test Redis PING:"
echo "        redis-cli -h 10.0.0.10 -p 6379 -a \"\$(grep REDIS_PASSWORD /opt/keybuzz-installer/credentials/redis.env | cut -d'\"' -f2)\" PING"
echo ""
echo "     2. Test RabbitMQ Management UI (via SSH tunnel):"
echo "        ssh -L 15672:10.0.0.10:15672 root@<install-01-public-ip>"
echo "        Puis: http://localhost:15672"
echo ""
echo "     3. Test Redis Failover:"
echo "        Voir README.md section 'Test 1: Redis Failover automatique'"
echo ""

echo -e "$OK Installation terminée avec succès ! 🎉"
echo ""
