#!/usr/bin/env bash
# Diagnostic rapide - À exécuter quand les apps ne fonctionnent pas

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   DIAGNOSTIC RAPIDE - Identification des problèmes                ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'

echo ""
echo "═══ 1. État général des pods ═══"
echo ""

kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -v ingress

RUNNING=$(kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -c "Running")
CRASH=$(kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -c "CrashLoopBackOff")
ERROR=$(kubectl get pods -A | grep -E '(n8n|litellm|chatwoot|qdrant)' | grep -c "Error")

echo ""
echo "  Running : $RUNNING/40"
echo "  CrashLoopBackOff : $CRASH"
echo "  Error : $ERROR"

if [ $CRASH -gt 0 ] || [ $ERROR -gt 0 ]; then
    echo ""
    echo "═══ 2. Logs des pods en erreur ═══"
    echo ""
    
    # n8n
    if kubectl get pods -n n8n 2>/dev/null | grep -qE "(CrashLoopBackOff|Error)"; then
        POD=$(kubectl get pods -n n8n -o name | grep n8n | head -1 | cut -d'/' -f2)
        echo "→ Logs n8n ($POD) :"
        kubectl logs -n n8n $POD --tail=20 2>/dev/null || echo "  Pas de logs disponibles"
        echo ""
    fi
    
    # litellm
    if kubectl get pods -n litellm 2>/dev/null | grep -qE "(CrashLoopBackOff|Error)"; then
        POD=$(kubectl get pods -n litellm -o name | grep litellm | head -1 | cut -d'/' -f2)
        echo "→ Logs litellm ($POD) :"
        kubectl logs -n litellm $POD --tail=20 2>/dev/null || echo "  Pas de logs disponibles"
        echo ""
    fi
    
    # chatwoot
    if kubectl get pods -n chatwoot 2>/dev/null | grep -qE "(CrashLoopBackOff|Error)"; then
        POD=$(kubectl get pods -n chatwoot -o name | grep chatwoot-web | head -1 | cut -d'/' -f2)
        echo "→ Logs chatwoot-web ($POD) :"
        kubectl logs -n chatwoot $POD --tail=20 2>/dev/null || echo "  Pas de logs disponibles"
        echo ""
    fi
fi

echo ""
echo "═══ 3. Diagnostic des erreurs courantes ═══"
echo ""

# Test 1 : PostgreSQL
echo "→ Test PostgreSQL..."
if psql -h 10.0.0.10 -p 5432 -U postgres -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "  $OK Port 5432 accessible"
else
    echo -e "  $KO Port 5432 inaccessible"
    echo "     SOLUTION : Vérifier HAProxy et PostgreSQL"
fi

if psql -h 10.0.0.10 -p 4632 -U postgres -c "SHOW POOLS;" >/dev/null 2>&1; then
    echo -e "  $OK Port 4632 (PgBouncer) accessible"
else
    echo -e "  $KO Port 4632 inaccessible"
    echo "     SOLUTION : Vérifier PgBouncer"
fi

# Test 2 : Bases de données
echo ""
echo "→ Test bases de données..."
for DB in n8n litellm chatwoot; do
    EXISTS=$(psql -h 10.0.0.10 -p 5432 -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB';" 2>/dev/null || echo "0")
    if [ "$EXISTS" = "1" ]; then
        echo -e "  $OK Base $DB existe"
        
        # Vérifier le owner du schéma
        OWNER=$(psql -h 10.0.0.10 -p 5432 -U postgres -d $DB -tAc "SELECT pg_catalog.pg_get_userbyid(n.nspowner) FROM pg_namespace n WHERE n.nspname = 'public';" 2>/dev/null)
        if [ "$OWNER" = "$DB" ]; then
            echo "     Owner schéma public : $OWNER ✓"
        else
            echo "     Owner schéma public : $OWNER ✗ (devrait être $DB)"
            echo "     SOLUTION : ALTER SCHEMA public OWNER TO $DB;"
        fi
    else
        echo -e "  $KO Base $DB n'existe pas"
        echo "     SOLUTION : Relancer 02_deploy_apps_clean.sh ou créer manuellement"
    fi
done

# Test 3 : Redis
echo ""
echo "→ Test Redis..."
if timeout 2 bash -c "echo PING | nc 10.0.0.10 6379" | grep -q "PONG"; then
    echo -e "  $OK Redis accessible"
else
    echo -e "  $KO Redis inaccessible"
    echo "     SOLUTION : Vérifier Redis et HAProxy"
fi

# Test 4 : Firewall UFW
echo ""
echo "→ Test UFW sur workers..."
WORKER="10.0.0.110"
ssh root@$WORKER "ufw status | grep -q '10.42.0.0/16'" 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "  $OK Règles K3s présentes"
else
    echo -e "  $KO Règles K3s manquantes"
    echo "     SOLUTION : ufw allow from 10.42.0.0/16"
    echo "                ufw allow from 10.43.0.0/16"
fi

# Test 5 : Ingress NGINX
echo ""
echo "→ Test Ingress NGINX..."
INGRESS_RUNNING=$(kubectl get pods -n ingress-nginx --no-headers | grep -c "Running")
if [ $INGRESS_RUNNING -eq 8 ]; then
    echo -e "  $OK Ingress NGINX opérationnel ($INGRESS_RUNNING/8 pods)"
else
    echo -e "  $KO Ingress NGINX incomplet ($INGRESS_RUNNING/8 pods)"
    echo "     SOLUTION : Redéployer Ingress NGINX DaemonSet"
fi

# Test 6 : Secrets K8s
echo ""
echo "→ Test secrets K8s..."
for NS in n8n litellm chatwoot; do
    if kubectl get secret -n $NS ${NS}-secrets >/dev/null 2>&1; then
        echo -e "  $OK Secret $NS-secrets existe"
        
        # Vérifier DATABASE_URL pour litellm
        if [ "$NS" = "litellm" ]; then
            DB_URL=$(kubectl get secret -n litellm litellm-secrets -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d)
            if echo "$DB_URL" | grep -q ":4632"; then
                echo "     DATABASE_URL : port 4632 ✓"
            else
                echo "     DATABASE_URL : port incorrect ✗ (doit être 4632)"
                echo "     SOLUTION : Recréer le secret avec port 4632"
            fi
        fi
    else
        echo -e "  $KO Secret $NS-secrets manquant"
        echo "     SOLUTION : Relancer 02_deploy_apps_clean.sh"
    fi
done

echo ""
echo "═══ 4. Tests de connectivité web ═══"
echo ""

echo "→ Test via Ingress..."
for HOST in n8n.keybuzz.io llm.keybuzz.io chat.keybuzz.io qdrant.keybuzz.io; do
    STATUS=$(curl -I -s -o /dev/null -w "%{http_code}" http://$HOST 2>/dev/null)
    if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
        echo -e "  $OK $HOST : HTTP $STATUS"
    else
        echo -e "  $KO $HOST : HTTP $STATUS"
    fi
done

echo ""
echo "═══ 5. Recommandations ═══"
echo ""

if [ $RUNNING -eq 40 ]; then
    echo "  ✓ Tous les pods sont Running !"
    echo "  ✓ Infrastructure opérationnelle"
    echo ""
    echo "  Si les apps ne répondent pas :"
    echo "    1. Vérifier les Load Balancers Hetzner"
    echo "    2. Vérifier la configuration DNS"
    echo "    3. Vérifier les Ingress (kubectl get ingress -A)"
elif [ $CRASH -gt 0 ]; then
    echo "  ✗ Pods en CrashLoopBackOff détectés"
    echo ""
    echo "  Causes les plus probables :"
    echo "    1. Base de données manquante ou permissions incorrectes"
    echo "    2. Secret K8s mal configuré (mauvais port, mot de passe)"
    echo "    3. Impossible de se connecter à PostgreSQL/Redis"
    echo ""
    echo "  SOLUTION RECOMMANDÉE :"
    echo "    ./00_cleanup_complete.sh"
    echo "    ./01_verify_prerequisites.sh"
    echo "    ./02_deploy_apps_clean.sh"
else
    echo "  ⚠ Infrastructure partiellement opérationnelle"
    echo ""
    echo "  Vérifier les logs ci-dessus pour identifier le problème"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Pour plus de détails :"
echo "  kubectl logs -n <namespace> <pod-name> --tail=100"
echo "  kubectl describe pod -n <namespace> <pod-name>"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
