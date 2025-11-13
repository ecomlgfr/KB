#!/usr/bin/env bash
set -u

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         Logs des NOUVEAUX pods (après fix Redis password)         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

MASTER_IP="10.0.0.100"

echo ""
echo "═══ Chatwoot Web (NOUVEAU pod - après correction Redis) ═══"
echo ""

# Prendre le pod le plus récent (654958cdb7)
CHATWOOT_WEB=$(ssh root@$MASTER_IP "kubectl get pods -n chatwoot -l app=chatwoot-web -o json | jq -r '.items[] | select(.metadata.name | contains(\"654958\")) | .metadata.name' | head -n1")

if [ -n "$CHATWOOT_WEB" ]; then
    echo "Pod : $CHATWOOT_WEB"
    echo ""
    
    # Vérifier s'il y a un init container
    INIT_STATUS=$(ssh root@$MASTER_IP "kubectl get pod $CHATWOOT_WEB -n chatwoot -o jsonpath='{.status.initContainerStatuses}' 2>/dev/null")
    
    if [ -n "$INIT_STATUS" ]; then
        echo "Logs init container db-migrate :"
        ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_WEB -c db-migrate 2>&1 | tail -100"
    else
        echo "Logs container principal :"
        ssh root@$MASTER_IP "kubectl logs -n chatwoot $CHATWOOT_WEB 2>&1 | tail -100"
    fi
else
    echo "Aucun nouveau pod Chatwoot Web trouvé"
fi

echo ""
echo "═══ Superset (NOUVEAU pod - après correction) ═══"
echo ""

# Prendre le pod le plus récent (6bcf56cb6f)
SUPERSET_POD=$(ssh root@$MASTER_IP "kubectl get pods -n superset -o json | jq -r '.items[] | select(.metadata.name | contains(\"6bcf56\")) | .metadata.name' | head -n1")

if [ -n "$SUPERSET_POD" ]; then
    echo "Pod : $SUPERSET_POD"
    echo ""
    
    # Vérifier l'état du pod
    POD_PHASE=$(ssh root@$MASTER_IP "kubectl get pod $SUPERSET_POD -n superset -o jsonpath='{.status.phase}'")
    echo "Phase : $POD_PHASE"
    echo ""
    
    # Essayer les différents containers
    echo "→ Tentative logs init-db :"
    ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-db 2>&1 | tail -50"
    
    echo ""
    echo "→ Tentative logs init-admin :"
    ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD -c init-admin 2>&1 | tail -50"
    
    echo ""
    echo "→ Tentative logs container principal :"
    ssh root@$MASTER_IP "kubectl logs -n superset $SUPERSET_POD 2>&1 | tail -50"
else
    echo "Aucun nouveau pod Superset trouvé"
fi

echo ""
echo "═══ Describe des pods pour voir les erreurs K8s ═══"
echo ""

echo "→ Chatwoot Web (dernier événement) :"
if [ -n "$CHATWOOT_WEB" ]; then
    ssh root@$MASTER_IP "kubectl describe pod $CHATWOOT_WEB -n chatwoot | grep -A 15 Events"
fi

echo ""
echo "→ Superset (dernier événement) :"
if [ -n "$SUPERSET_POD" ]; then
    ssh root@$MASTER_IP "kubectl describe pod $SUPERSET_POD -n superset | grep -A 15 Events"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "FIN DES LOGS"
echo "═══════════════════════════════════════════════════════════════════"
