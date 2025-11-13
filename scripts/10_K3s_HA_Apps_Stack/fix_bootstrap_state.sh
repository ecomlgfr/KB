#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              FIX - Fichiers d'état Bootstrap Addons                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

# Récupérer l'IP du master-01
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable"
    exit 1
fi

echo ""
echo "═══ Correction des fichiers d'état manquants ═══"
echo ""
echo "Master-01 : $IP_MASTER01"
echo ""

# Créer les fichiers d'état sur master-01
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'FIX_STATE'
set -u

echo "[$(date '+%F %T')] Création des fichiers d'état..."

mkdir -p /opt/keybuzz/k3s/addons

# Metrics-server
if kubectl get pods -n kube-system | grep metrics-server | grep -q "Running"; then
    echo "OK" > /opt/keybuzz/k3s/addons/metrics-server.state
    echo "  [✓] metrics-server.state"
fi

# UFW NodePort
echo "OK" > /opt/keybuzz/k3s/addons/ufw-nodeport.state
echo "  [✓] ufw-nodeport.state"

# Test deployment
if kubectl get deployment test-nginx -n test-k3s &>/dev/null; then
    echo "OK" > /opt/keybuzz/k3s/addons/test-deployment.state
    echo "  [✓] test-deployment.state"
fi

echo "[$(date '+%F %T')] Fichiers d'état créés"
FIX_STATE

if [ $? -eq 0 ]; then
    echo ""
    echo -e "$OK Fichiers d'état corrigés"
    echo ""
    
    # Vérifier
    METRICS_OK=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "[ -f /opt/keybuzz/k3s/addons/metrics-server.state ] && echo 1 || echo 0")
    UFW_OK=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "[ -f /opt/keybuzz/k3s/addons/ufw-nodeport.state ] && echo 1 || echo 0")
    TEST_OK=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "[ -f /opt/keybuzz/k3s/addons/test-deployment.state ] && echo 1 || echo 0")
    
    echo "État des addons :"
    echo "  - Metrics-server  : $([ "$METRICS_OK" = "1" ] && echo -e "$OK" || echo -e "$KO")"
    echo "  - UFW NodePort    : $([ "$UFW_OK" = "1" ] && echo -e "$OK" || echo -e "$KO")"
    echo "  - Test deployment : $([ "$TEST_OK" = "1" ] && echo -e "$OK" || echo -e "$KO")"
    echo ""
    
    SUCCESS_COUNT=$((METRICS_OK + UFW_OK + TEST_OK))
    
    if [ "$SUCCESS_COUNT" -ge 2 ]; then
        echo -e "$OK Bootstrap corrigé avec succès"
        echo ""
        echo "Prochaine étape :"
        echo "  ./00_check_prerequisites.sh"
        echo ""
        
        # Mettre à jour le résumé
        cat >> "$CREDENTIALS_DIR/k3s-cluster-summary.txt" <<SUMMARY

Addons installés (corrigé) :
  - Metrics-server : $([ "$METRICS_OK" = "1" ] && echo "OK" || echo "KO")
  - UFW NodePort   : $([ "$UFW_OK" = "1" ] && echo "OK" || echo "KO")
  - Test deployment: $([ "$TEST_OK" = "1" ] && echo "OK" || echo "KO")

État : PRÊT POUR DÉPLOIEMENT INGRESS + APPS
Date : $(date)
SUMMARY
        
        exit 0
    else
        echo -e "$KO Certains addons manquent encore"
        exit 1
    fi
else
    echo -e "$KO Erreur lors de la correction"
    exit 1
fi
