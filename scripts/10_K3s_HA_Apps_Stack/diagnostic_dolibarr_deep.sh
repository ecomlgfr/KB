#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    DIAGNOSTIC APPROFONDI - Dolibarr ERP                           ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. État des pods Dolibarr ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -n erp -o wide

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Vérification Secret DB ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Variables d'environnement DB dans le secret :"
kubectl get secret -n erp dolibarr-secrets -o jsonpath='{.data.DOLI_DB_HOST}' | base64 -d && echo " (DOLI_DB_HOST)"
kubectl get secret -n erp dolibarr-secrets -o jsonpath='{.data.DOLI_DB_PORT}' | base64 -d && echo " (DOLI_DB_PORT)"
kubectl get secret -n erp dolibarr-secrets -o jsonpath='{.data.DOLI_DB_NAME}' | base64 -d && echo " (DOLI_DB_NAME)"
kubectl get secret -n erp dolibarr-secrets -o jsonpath='{.data.DOLI_DB_USER}' | base64 -d && echo " (DOLI_DB_USER)"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Test connexion DB (port 4632 - PgBouncer) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

POD=$(kubectl get pod -n erp -l app=dolibarr -o name | head -1)

echo "Test depuis le pod Dolibarr..."
kubectl exec -n erp $POD -- sh -c "echo 'Testing PgBouncer connection...'"

# Test port 4632 (PgBouncer - CORRECT)
echo ""
echo "Test port 4632 (PgBouncer SCRAM-SHA-256) :"
kubectl exec -n erp $POD -- sh -c "timeout 5 nc -zv 10.0.0.10 4632 2>&1" || echo "❌ Port 4632 inaccessible"

# Test port 6432 (HAProxy PostgreSQL - INCORRECT pour Dolibarr)
echo ""
echo "Test port 6432 (HAProxy PostgreSQL - utilisé actuellement) :"
kubectl exec -n erp $POD -- sh -c "timeout 5 nc -zv 10.0.0.10 6432 2>&1" || echo "❌ Port 6432 inaccessible"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. Test SQL depuis install-01 (via PgBouncer 4632) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Connexion à la base dolibarr via PgBouncer (port 4632) :"
PGPASSWORD="NEhobUmaJGdR7TL2MCXRB853" psql -h 10.0.0.10 -p 4632 -U dolibarr -d dolibarr -c "\dt" 2>&1 | head -20

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Logs Dolibarr (dernières 30 lignes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl logs -n erp $POD --tail=30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. Test HTTP direct (ClusterIP) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

SVC_IP=$(kubectl get svc -n erp dolibarr -o jsonpath='{.spec.clusterIP}')
echo "Service ClusterIP : $SVC_IP"

kubectl run test-dolibarr --image=curlimages/curl --restart=Never -n erp --rm -i -- \
  curl -I http://$SVC_IP:80 --max-time 10 2>&1 | head -15

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 7. Test HTTP via Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test depuis install-01 :"
curl -I http://my.keybuzz.io --max-time 10

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 8. Vérification Ingress ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get ingress -n erp dolibarr-ingress -o yaml | grep -A 10 "annotations:"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ DIAGNOSTIC TERMINÉ ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "🔍 POINTS À VÉRIFIER :"
echo ""
echo "1. Port DB utilisé :"
echo "   - Actuel dans secret : voir ci-dessus"
echo "   - Devrait être : 4632 (PgBouncer SCRAM-SHA-256)"
echo "   - PAS 6432 (HAProxy PostgreSQL direct)"
echo ""
echo "2. HTTP Status :"
echo "   - Si 202 : Dolibarr en cours d'installation"
echo "   - Si 504 : Timeout Ingress ou DB"
echo "   - Si 200/302 : OK"
echo ""
echo "3. Base de données :"
echo "   - Tables dolibarr créées ?"
echo "   - Schéma initialisé ?"
echo ""

exit 0
