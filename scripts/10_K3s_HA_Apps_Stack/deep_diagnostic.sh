#!/usr/bin/env bash

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC APPROFONDI - Analyse des problèmes persistants      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════
# 1. VAULT - Logs détaillés
# ═══════════════════════════════════════════════════════════════════

echo "════════════════════════════════════════════════════════════════════"
echo "1. VAULT - CrashLoopBackOff (11 restarts)"
echo "════════════════════════════════════════════════════════════════════"
echo ""

POD_VAULT=$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_VAULT" ]; then
    echo "Pod: $POD_VAULT"
    echo ""
    echo "--- Logs Vault (50 dernières lignes) ---"
    kubectl logs -n vault "$POD_VAULT" --tail=50 2>&1
    echo ""
    echo "--- Events Vault ---"
    kubectl get events -n vault --sort-by='.lastTimestamp' | tail -10
    echo ""
    echo "--- ConfigMap Vault ---"
    kubectl get configmap vault-config -n vault -o yaml | grep -A 20 "vault.hcl"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "2. WAZUH INDEXER - CrashLoopBackOff (23 restarts) ⚠️ CRITIQUE"
echo "════════════════════════════════════════════════════════════════════"
echo ""

POD_INDEXER=$(kubectl get pods -n wazuh -l app=wazuh-indexer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_INDEXER" ]; then
    echo "Pod: $POD_INDEXER"
    echo ""
    echo "--- Describe Pod ---"
    kubectl describe pod -n wazuh "$POD_INDEXER" | tail -50
    echo ""
    echo "--- Logs Indexer (100 dernières lignes) ---"
    kubectl logs -n wazuh "$POD_INDEXER" --tail=100 2>&1
    echo ""
    echo "--- Init Container Logs (si présent) ---"
    kubectl logs -n wazuh "$POD_INDEXER" -c sysctl --tail=50 2>&1 || echo "Pas d'init container"
    echo ""
    echo "--- Events Wazuh ---"
    kubectl get events -n wazuh --sort-by='.lastTimestamp' | tail -15
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "3. WAZUH MANAGER - Erreur Password"
echo "════════════════════════════════════════════════════════════════════"
echo ""

POD_MANAGER=$(kubectl get pods -n wazuh -l app=wazuh-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_MANAGER" ]; then
    echo "Pod: $POD_MANAGER"
    echo ""
    echo "--- Logs Manager (derniers 50 lignes) ---"
    kubectl logs -n wazuh "$POD_MANAGER" --tail=50 2>&1
    echo ""
    echo "--- Secret Wazuh ---"
    echo "API_PASSWORD length:"
    kubectl get secret wazuh-secrets -n wazuh -o jsonpath='{.data.API_PASSWORD}' | base64 -d | wc -c
    echo ""
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "4. WAZUH DASHBOARD - Dépend de l'Indexer"
echo "════════════════════════════════════════════════════════════════════"
echo ""

POD_DASHBOARD=$(kubectl get pods -n wazuh -l app=wazuh-dashboard -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_DASHBOARD" ]; then
    echo "Pod: $POD_DASHBOARD"
    echo ""
    echo "--- Logs Dashboard (30 dernières lignes) ---"
    kubectl logs -n wazuh "$POD_DASHBOARD" --tail=30 2>&1
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "5. GRAFANA - Datasource Conflict"
echo "════════════════════════════════════════════════════════════════════"
echo ""

POD_GRAFANA=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD_GRAFANA" ]; then
    echo "Pod: $POD_GRAFANA"
    echo ""
    echo "--- Logs Grafana container (50 dernières lignes) ---"
    kubectl logs -n monitoring "$POD_GRAFANA" -c grafana --tail=50 2>&1
    echo ""
    echo "--- ConfigMaps Grafana ---"
    kubectl get configmap -n monitoring | grep grafana
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ DES PROBLÈMES"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "Pods en erreur :"
kubectl get pods -A | grep -E "CrashLoop|Error|ImagePull" | wc -l
echo ""
echo "Détails :"
kubectl get pods -A | grep -E "CrashLoop|Error|ImagePull"
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "Pour voir le diagnostic complet, consulter le fichier de log."
echo ""
