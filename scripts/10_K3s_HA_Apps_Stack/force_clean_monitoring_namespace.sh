#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Nettoyage FORCÉ du namespace monitoring                        ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "Ce script force la suppression du namespace monitoring"
echo "si celui-ci reste bloqué en état 'Terminating'."
echo ""
echo "⚠️  ATTENTION : À utiliser UNIQUEMENT si le namespace"
echo "   reste bloqué après plusieurs minutes."
echo ""

read -p "Forcer le nettoyage ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Vérification état du namespace ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if ! kubectl get namespace monitoring >/dev/null 2>&1; then
    echo -e "$OK Namespace monitoring n'existe pas ou est déjà supprimé"
    exit 0
fi

PHASE=$(kubectl get namespace monitoring -o jsonpath='{.status.phase}' 2>/dev/null)
echo "État actuel du namespace : $PHASE"

if [ "$PHASE" != "Terminating" ]; then
    echo ""
    echo "Le namespace n'est pas en Terminating."
    echo "Utilisez plutôt le script normal : ./13_fix_monitoring_stack_v3.sh"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Suppression des finalizers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Récupération du JSON du namespace..."
kubectl get namespace monitoring -o json > /tmp/monitoring-ns.json

echo "Suppression des finalizers..."
cat /tmp/monitoring-ns.json | \
  jq 'del(.spec.finalizers)' | \
  jq 'del(.metadata.finalizers)' > /tmp/monitoring-ns-clean.json

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Application de la suppression forcée ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Forçage de la suppression via API..."
kubectl replace --raw "/api/v1/namespaces/monitoring/finalize" \
  -f /tmp/monitoring-ns-clean.json

if [ $? -eq 0 ]; then
    echo -e "$OK Namespace forcé en suppression"
else
    echo -e "$KO Échec de la suppression forcée"
    echo ""
    echo "Essayez cette commande manuelle :"
    echo ""
    echo "kubectl patch namespace monitoring -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
    exit 1
fi

echo ""
echo "Attente 10 secondes..."
sleep 10

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if ! kubectl get namespace monitoring >/dev/null 2>&1; then
    echo -e "$OK Namespace monitoring complètement supprimé"
    echo ""
    echo "Vous pouvez maintenant relancer :"
    echo "  ./13_fix_monitoring_stack_v3.sh"
else
    echo -e "$WARN Namespace encore présent"
    kubectl get namespace monitoring
    echo ""
    echo "Si le namespace persiste, essayez :"
    echo ""
    echo "# Méthode 1 : Patch direct"
    echo "kubectl patch namespace monitoring -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
    echo ""
    echo "# Méthode 2 : Suppression de toutes les ressources"
    echo "kubectl delete all --all -n monitoring --force --grace-period=0"
    echo "kubectl delete pvc --all -n monitoring --force --grace-period=0"
    echo ""
    echo "# Méthode 3 : Restart des contrôleurs K3s"
    echo "systemctl restart k3s  # Sur les masters"
fi

echo ""
