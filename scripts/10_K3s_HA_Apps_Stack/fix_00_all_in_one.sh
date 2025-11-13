#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX ALL - Correction de tous les services en échec             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "Ce script va exécuter dans l'ordre :"
echo "  1. Fix Connect API (build image locale)"
echo "  2. Fix Grafana (config simplifiée sans persistence)"
echo "  3. Fix Airbyte (DB interne)"
echo "  4. Fix Dolibarr (augmentation timeouts)"
echo ""
echo "⏱️ Durée estimée : 20-30 minutes"
echo ""

read -p "Exécuter tous les fixes ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Log file
LOG_FILE="/opt/keybuzz-installer/logs/fix_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p /opt/keybuzz-installer/logs

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Logs sauvegardés dans : $LOG_FILE"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Fonction pour exécuter un fix
run_fix() {
    local script=$1
    local name=$2
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  Exécution : $name"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [ -f "$script" ]; then
        chmod +x "$script"
        
        # Exécuter avec auto-confirm
        echo "yes" | "$script" 2>&1 | tee -a "$LOG_FILE"
        
        if [ ${PIPESTATUS[1]} -eq 0 ]; then
            echo -e "\n$OK $name terminé avec succès\n"
        else
            echo -e "\n$WARN $name terminé avec avertissements\n"
        fi
    else
        echo -e "$KO Script $script introuvable"
        return 1
    fi
    
    echo "Pause 10s avant le prochain fix..."
    sleep 10
}

# Exécution séquentielle
run_fix "${SCRIPT_DIR}/fix_01_connect_api_build_image.sh" "Connect API"
run_fix "${SCRIPT_DIR}/fix_02_grafana_simple.sh" "Grafana"
run_fix "${SCRIPT_DIR}/fix_03_airbyte_simple.sh" "Airbyte"
run_fix "${SCRIPT_DIR}/fix_04_dolibarr_timeout.sh" "Dolibarr"

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  Attente finale (2 minutes)                                        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

echo "Attente stabilisation de tous les services..."
sleep 120

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  Validation finale                                                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

echo "État des pods :"
echo ""
kubectl get pods -n connect
echo ""
kubectl get pods -n monitoring | grep -E '(grafana|prometheus|loki)'
echo ""
kubectl get pods -n etl
echo ""
kubectl get pods -n erp
echo ""

echo "Tests HTTP :"
echo ""

test_url() {
    local name=$1
    local url=$2
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $url --max-time 10 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        echo -e "  $name : $OK (HTTP $HTTP_CODE)"
    else
        echo -e "  $name : $WARN (HTTP $HTTP_CODE)"
    fi
}

test_url "Connect API" "http://connect.keybuzz.io/health"
test_url "Grafana" "http://monitor.keybuzz.io"
test_url "Dolibarr" "http://my.keybuzz.io"
test_url "Airbyte" "http://etl.keybuzz.io"

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║  RÉSUMÉ                                                            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Services corrigés :"
echo "  1. Connect API : Image Docker locale créée et déployée"
echo "  2. Grafana : Config simplifiée sans persistence"
echo "  3. Airbyte : DB/MinIO internes (plus simple)"
echo "  4. Dolibarr : Timeouts augmentés"
echo ""
echo "📱 URLs d'accès :"
echo "  Connect API : http://connect.keybuzz.io/health"
echo "  Grafana : http://monitor.keybuzz.io (admin / KeyBuzz2025!)"
echo "  Dolibarr : http://my.keybuzz.io (admin / KeyBuzz2025!)"
echo "  Airbyte : http://etl.keybuzz.io"
echo ""
echo "📝 Logs complets : $LOG_FILE"
echo ""
echo "⚠️ NOTES IMPORTANTES :"
echo ""
echo "  1. Connect API :"
echo "     - Image locale (pas de registry externe)"
echo "     - À recréer sur chaque nouveau worker"
echo ""
echo "  2. Monitoring (Grafana/Prometheus/Loki) :"
echo "     - SANS persistence (données volatiles)"
echo "     - Config de DEV/TEST uniquement"
echo "     - Pour PROD : ajouter storageSpec avec PVC"
echo ""
echo "  3. Airbyte :"
echo "     - DB PostgreSQL INTERNE (pas KeyBuzz)"
echo "     - MinIO INTERNE (pas s3.keybuzz.io)"
echo "     - Connecteurs externes à configurer via UI"
echo ""
echo "  4. Dolibarr :"
echo "     - Timeouts Ingress : 10 minutes"
echo "     - Premier démarrage peut prendre 2-3 minutes"
echo ""
echo "🔧 Commandes de diagnostic :"
echo "  kubectl get pods -A | grep -v Running"
echo "  kubectl logs -n <namespace> <pod-name>"
echo "  kubectl describe pod -n <namespace> <pod-name>"
echo ""

exit 0
