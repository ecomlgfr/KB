#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC COMPLET CLUSTER K3S - KeyBuzz                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/home/user/KB/logs/diagnostic_${TIMESTAMP}"
mkdir -p "$LOG_DIR"

echo ""
echo "📊 Collecte des informations de diagnostic..."
echo "📁 Dossier de logs : $LOG_DIR"
echo ""

# ═══════════════════════════════════════════════════════════════════
# 1. ÉTAT GÉNÉRAL DU CLUSTER
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 1. ÉTAT GÉNÉRAL DU CLUSTER                                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Nœuds du cluster..."
kubectl get nodes -o wide > "$LOG_DIR/nodes.txt"
kubectl get nodes -o wide
echo ""

echo "→ Tous les pods (par namespace)..."
kubectl get pods -A -o wide > "$LOG_DIR/all_pods.txt"
echo ""

echo "→ Statistiques par statut..."
cat > "$LOG_DIR/pod_stats.txt" <<'STATS'
=== STATISTIQUES DES PODS ===
STATS

kubectl get pods -A --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c | tee -a "$LOG_DIR/pod_stats.txt"
echo ""

# ═══════════════════════════════════════════════════════════════════
# 2. PROBLÈMES IDENTIFIÉS
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 2. PODS EN PROBLÈME (Non-Running)                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null > "$LOG_DIR/problematic_pods.txt"

if [ -s "$LOG_DIR/problematic_pods.txt" ]; then
    cat "$LOG_DIR/problematic_pods.txt"

    PROBLEM_COUNT=$(wc -l < "$LOG_DIR/problematic_pods.txt")
    echo ""
    echo -e "$WARN $PROBLEM_COUNT pods en problème détectés"
else
    echo -e "$OK Aucun pod en problème"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# 3. DIAGNOSTIC VAULT (namespace: vault)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 3. DIAGNOSTIC VAULT                                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

mkdir -p "$LOG_DIR/vault"

echo "→ État des pods Vault..."
kubectl get pods -n vault -o wide > "$LOG_DIR/vault/pods.txt"
kubectl get pods -n vault -o wide
echo ""

VAULT_PODS=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep -v "Running.*0/" | head -3)
if [ -n "$VAULT_PODS" ]; then
    echo "→ Pods Vault en problème :"
    echo "$VAULT_PODS"
    echo ""

    echo "→ Récupération des logs des pods en échec..."
    for pod in $(kubectl get pods -n vault --no-headers 2>/dev/null | grep -v "Running.*0/" | awk '{print $1}' | head -3); do
        echo "  • $pod"
        kubectl logs -n vault "$pod" --tail=100 > "$LOG_DIR/vault/logs_${pod}.txt" 2>&1
        kubectl describe pod -n vault "$pod" > "$LOG_DIR/vault/describe_${pod}.txt" 2>&1
    done
    echo ""

    echo "→ Analyse du premier pod..."
    FIRST_POD=$(kubectl get pods -n vault --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$FIRST_POD" ]; then
        echo "  Pod: $FIRST_POD"
        echo ""
        echo "  Logs (30 dernières lignes) :"
        kubectl logs -n vault "$FIRST_POD" --tail=30 2>&1 | head -40
        echo ""

        echo "  Test vault status..."
        kubectl exec -n vault "$FIRST_POD" -- vault status 2>&1 | tee "$LOG_DIR/vault/vault_status.txt" || echo "  Erreur lors de vault status"
    fi
else
    echo -e "$OK Tous les pods Vault sont Running"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# 4. DIAGNOSTIC WAZUH (namespace: wazuh)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 4. DIAGNOSTIC WAZUH                                           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

mkdir -p "$LOG_DIR/wazuh"

echo "→ État des pods Wazuh..."
kubectl get pods -n wazuh -o wide > "$LOG_DIR/wazuh/pods.txt"
kubectl get pods -n wazuh -o wide
echo ""

# Wazuh Indexer
INDEXER_POD=$(kubectl get pods -n wazuh -l app=wazuh-indexer --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$INDEXER_POD" ]; then
    echo "→ Diagnostic Wazuh Indexer ($INDEXER_POD)..."
    kubectl logs -n wazuh "$INDEXER_POD" --tail=50 > "$LOG_DIR/wazuh/indexer_logs.txt" 2>&1
    kubectl describe pod -n wazuh "$INDEXER_POD" > "$LOG_DIR/wazuh/indexer_describe.txt" 2>&1

    echo "  Logs (20 dernières lignes) :"
    tail -20 "$LOG_DIR/wazuh/indexer_logs.txt"
    echo ""

    echo "  Test HTTP Indexer..."
    kubectl exec -n wazuh "$INDEXER_POD" -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:9200 2>&1 || echo "  Erreur connexion HTTP"
    echo ""
fi

# Wazuh Manager
MANAGER_PODS=$(kubectl get pods -n wazuh -l app=wazuh-manager --no-headers 2>/dev/null | wc -l)
if [ "$MANAGER_PODS" -gt 0 ]; then
    echo "→ Diagnostic Wazuh Manager ($MANAGER_PODS pods)..."

    FIRST_MANAGER=$(kubectl get pods -n wazuh -l app=wazuh-manager --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$FIRST_MANAGER" ]; then
        echo "  Analyse du premier pod: $FIRST_MANAGER"
        kubectl logs -n wazuh "$FIRST_MANAGER" --tail=100 > "$LOG_DIR/wazuh/manager_logs_${FIRST_MANAGER}.txt" 2>&1
        kubectl describe pod -n wazuh "$FIRST_MANAGER" > "$LOG_DIR/wazuh/manager_describe_${FIRST_MANAGER}.txt" 2>&1

        echo "  Logs (30 dernières lignes) :"
        tail -30 "$LOG_DIR/wazuh/manager_logs_${FIRST_MANAGER}.txt"
        echo ""
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# 5. DIAGNOSTIC ERPNEXT (namespace: erpnext)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 5. DIAGNOSTIC ERPNEXT                                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

mkdir -p "$LOG_DIR/erpnext"

echo "→ État des pods ERPNext..."
kubectl get pods -n erpnext -o wide > "$LOG_DIR/erpnext/pods.txt"
kubectl get pods -n erpnext -o wide
echo ""

SOCKETIO_POD=$(kubectl get pods -n erpnext -l app.kubernetes.io/component=socketio --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$SOCKETIO_POD" ]; then
    echo "→ Diagnostic ERPNext socketio ($SOCKETIO_POD)..."
    kubectl logs -n erpnext "$SOCKETIO_POD" --tail=100 > "$LOG_DIR/erpnext/socketio_logs.txt" 2>&1
    kubectl describe pod -n erpnext "$SOCKETIO_POD" > "$LOG_DIR/erpnext/socketio_describe.txt" 2>&1

    echo "  Logs (40 dernières lignes) :"
    tail -40 "$LOG_DIR/erpnext/socketio_logs.txt"
    echo ""

    echo "  Statut du pod :"
    kubectl get pod -n erpnext "$SOCKETIO_POD"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════
# 6. EVENTS K8S (erreurs récentes)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 6. EVENTS K8S (Erreurs récentes)                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

kubectl get events -A --sort-by='.lastTimestamp' | tail -50 > "$LOG_DIR/recent_events.txt"
echo "→ 50 derniers events :"
tail -50 "$LOG_DIR/recent_events.txt"
echo ""

# Filtrer les erreurs Warning/Error
kubectl get events -A --field-selector type!=Normal --sort-by='.lastTimestamp' 2>/dev/null > "$LOG_DIR/error_events.txt"
if [ -s "$LOG_DIR/error_events.txt" ]; then
    echo "→ Events Warning/Error :"
    tail -30 "$LOG_DIR/error_events.txt"
else
    echo -e "$OK Aucun event Warning/Error récent"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# 7. RESSOURCES (CPU/Mémoire)
# ═══════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ 7. UTILISATION DES RESSOURCES                                 ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Ressources par nœud..."
kubectl top nodes > "$LOG_DIR/resources_nodes.txt" 2>&1 || echo "metrics-server non disponible"
cat "$LOG_DIR/resources_nodes.txt" 2>/dev/null
echo ""

echo "→ Top 20 pods (CPU)..."
kubectl top pods -A --sort-by=cpu 2>/dev/null | head -21 > "$LOG_DIR/resources_pods_cpu.txt"
cat "$LOG_DIR/resources_pods_cpu.txt" 2>/dev/null
echo ""

echo "→ Top 20 pods (Mémoire)..."
kubectl top pods -A --sort-by=memory 2>/dev/null | head -21 > "$LOG_DIR/resources_pods_memory.txt"
cat "$LOG_DIR/resources_pods_memory.txt" 2>/dev/null
echo ""

# ═══════════════════════════════════════════════════════════════════
# 8. RÉSUMÉ ET RECOMMANDATIONS
# ═══════════════════════════════════════════════════════════════════

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  RÉSUMÉ DU DIAGNOSTIC                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Compter les pods par état
RUNNING=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo 0)
COMPLETED=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Completed" || echo 0)
CRASHLOOP=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || echo 0)
ERROR=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Error" || echo 0)
PENDING=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Pending" || echo 0)
TOTAL=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l || echo 0)

echo "📊 STATISTIQUES GLOBALES"
echo "════════════════════════════════════════════════════════════════"
echo "  Total pods       : $TOTAL"
echo "  ✅ Running       : $RUNNING"
echo "  ✅ Completed     : $COMPLETED"
echo "  ❌ CrashLoop     : $CRASHLOOP"
echo "  ❌ Error         : $ERROR"
echo "  ⏳ Pending       : $PENDING"
echo ""

# Analyse par namespace problématique
echo "🔍 PROBLÈMES PAR NAMESPACE"
echo "════════════════════════════════════════════════════════════════"

VAULT_ISSUES=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep -v "Running.*0/" | wc -l)
WAZUH_ISSUES=$(kubectl get pods -n wazuh --no-headers 2>/dev/null | grep -c "CrashLoopBackOff\|Error" || echo 0)
ERPNEXT_ISSUES=$(kubectl get pods -n erpnext --no-headers 2>/dev/null | grep -c "CrashLoopBackOff\|Error" || echo 0)

if [ "$VAULT_ISSUES" -gt 0 ]; then
    echo -e "$KO Vault      : $VAULT_ISSUES pods en problème"
else
    echo -e "$OK Vault      : OK"
fi

if [ "$WAZUH_ISSUES" -gt 0 ]; then
    echo -e "$KO Wazuh      : $WAZUH_ISSUES pods en problème"
else
    echo -e "$OK Wazuh      : OK"
fi

if [ "$ERPNEXT_ISSUES" -gt 0 ]; then
    echo -e "$WARN ERPNext   : $ERPNEXT_ISSUES pods en problème"
else
    echo -e "$OK ERPNext   : OK"
fi

echo ""
echo "📋 RECOMMANDATIONS"
echo "════════════════════════════════════════════════════════════════"

if [ "$VAULT_ISSUES" -gt 0 ]; then
    echo "🔴 VAULT :"
    echo "   • Pods en CrashLoopBackOff ou avec restarts élevés"
    echo "   • Cause probable : Vault sealed (verrouillé)"
    echo "   • Action : Vérifier fichier $LOG_DIR/vault/vault_status.txt"
    echo "   • Solution : ./fix_vault_unsealed.sh (à créer)"
    echo ""
fi

if [ "$WAZUH_ISSUES" -gt 0 ]; then
    echo "🔴 WAZUH :"
    echo "   • Managers et/ou Indexer en problème"
    echo "   • Cause probable : Configuration SSL, dépendances manquantes"
    echo "   • Action : Vérifier logs dans $LOG_DIR/wazuh/"
    echo "   • Solution : ./fix_wazuh_complete.sh (à créer)"
    echo ""
fi

if [ "$ERPNEXT_ISSUES" -gt 0 ]; then
    echo "🟡 ERPNEXT :"
    echo "   • Composant socketio en CrashLoopBackOff"
    echo "   • Cause probable : Connexion Redis ou base de données"
    echo "   • Action : Vérifier logs dans $LOG_DIR/erpnext/"
    echo "   • Solution : ./fix_erpnext_socketio.sh (à créer)"
    echo ""
fi

echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📁 Tous les logs détaillés sont dans : $LOG_DIR"
echo ""
echo "🔧 Prochaines étapes :"
echo "  1. Analyser les logs dans $LOG_DIR"
echo "  2. Exécuter les scripts de correction recommandés"
echo "  3. Relancer ce diagnostic pour vérifier les corrections"
echo ""
echo "💾 Logs sauvegardés avec timestamp : $TIMESTAMP"
echo ""

# Créer un fichier summary
cat > "$LOG_DIR/SUMMARY.txt" <<SUMMARY
=== DIAGNOSTIC CLUSTER K3S - KeyBuzz ===
Date : $(date)
Timestamp : $TIMESTAMP

STATISTIQUES :
  Total pods   : $TOTAL
  Running      : $RUNNING
  Completed    : $COMPLETED
  CrashLoop    : $CRASHLOOP
  Error        : $ERROR
  Pending      : $PENDING

PROBLÈMES IDENTIFIÉS :
  Vault        : $VAULT_ISSUES pods
  Wazuh        : $WAZUH_ISSUES pods
  ERPNext      : $ERPNEXT_ISSUES pods

LOGS DISPONIBLES :
  - all_pods.txt
  - problematic_pods.txt
  - vault/
  - wazuh/
  - erpnext/
  - recent_events.txt
  - error_events.txt
  - resources_*.txt
SUMMARY

echo "✅ Diagnostic terminé !"
echo ""

exit 0
