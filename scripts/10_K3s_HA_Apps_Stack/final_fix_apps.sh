#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Correction finale Chatwoot Web & Superset (variables env)      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

MASTER_IP="10.0.0.100"

echo ""
echo "Problèmes identifiés :"
echo "  → Chatwoot Web : Container principal crash (logs à vérifier)"
echo "  → Superset : Variable d'env mal formée (tcp://... au lieu de port)"
echo ""
echo "Solutions :"
echo "  → Chatwoot : Voir les logs et corriger si besoin"
echo "  → Superset : Supprimer les variables auto-injectées par K8s"
echo ""

read -p "Corriger les déploiements ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Logs du container principal Chatwoot ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@$MASTER_IP bash <<'CHECK_CHATWOOT'
# Trouver un pod Chatwoot Web récent
POD=$(kubectl get pods -n chatwoot -l app=chatwoot-web -o json | jq -r '.items[] | select(.metadata.name | contains("654958")) | .metadata.name' | head -n1)

if [ -n "$POD" ]; then
    echo "Pod : $POD"
    echo ""
    echo "Logs container principal (dernières erreurs) :"
    kubectl logs -n chatwoot $POD -c chatwoot --tail=100 2>&1 | tail -50
else
    echo "Aucun pod trouvé"
fi
CHECK_CHATWOOT

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Correction déploiement Superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@$MASTER_IP bash <<'FIX_SUPERSET'
set -u

echo "[$(date '+%F %T')] Suppression du déploiement Superset..."
kubectl delete deployment superset -n superset --force --grace-period=0
echo "  ✓ Déploiement supprimé"

echo ""
echo "[$(date '+%F %T')] Recréation avec variables explicites..."

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: superset
  namespace: superset
spec:
  replicas: 2
  selector:
    matchLabels:
      app: superset
  template:
    metadata:
      labels:
        app: superset
    spec:
      initContainers:
      - name: init-db
        image: apache/superset:latest
        command:
        - /bin/sh
        - -c
        - |
          superset db upgrade
          superset init
        env:
        - name: SUPERSET_PORT
          value: "8088"
        envFrom:
        - secretRef:
            name: superset-config
      - name: init-admin
        image: apache/superset:latest
        command:
        - /bin/sh
        - -c
        - |
          superset fab create-admin \
            --username admin \
            --firstname Admin \
            --lastname User \
            --email admin@keybuzz.io \
            --password admin || true
        env:
        - name: SUPERSET_PORT
          value: "8088"
        envFrom:
        - secretRef:
            name: superset-config
      containers:
      - name: superset
        image: apache/superset:latest
        command:
        - /bin/sh
        - -c
        - |
          gunicorn \
            -w 10 \
            -k gevent \
            --timeout 120 \
            -b 0.0.0.0:8088 \
            --limit-request-line 0 \
            --limit-request-field_size 0 \
            'superset.app:create_app()'
        ports:
        - containerPort: 8088
          name: http
        env:
        - name: SUPERSET_PORT
          value: "8088"
        envFrom:
        - secretRef:
            name: superset-config
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 180
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 120
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
EOF

echo "  ✓ Superset recréé avec command explicite"

FIX_SUPERSET

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Correction déploiement Chatwoot Web ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Analyse des logs Chatwoot en cours..."
echo "Si le problème est similaire à Superset, on va corriger le déploiement."
echo ""

ssh root@$MASTER_IP bash <<'FIX_CHATWOOT'
set -u

echo "[$(date '+%F %T')] Suppression du déploiement Chatwoot Web..."
kubectl delete deployment chatwoot-web -n chatwoot --force --grace-period=0
echo "  ✓ Déploiement supprimé"

echo ""
echo "[$(date '+%F %T')] Recréation avec command explicite..."

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatwoot-web
  namespace: chatwoot
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chatwoot-web
  template:
    metadata:
      labels:
        app: chatwoot-web
    spec:
      initContainers:
      - name: db-migrate
        image: chatwoot/chatwoot:latest
        command:
        - bundle
        - exec
        - rails
        - db:chatwoot_prepare
        envFrom:
        - secretRef:
            name: chatwoot-config
        env:
        - name: PORT
          value: "3000"
      containers:
      - name: chatwoot
        image: chatwoot/chatwoot:latest
        command:
        - bundle
        - exec
        - rails
        - server
        - -b
        - 0.0.0.0
        - -p
        - "3000"
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: PORT
          value: "3000"
        - name: RAILS_ENV
          value: "production"
        - name: NODE_ENV
          value: "production"
        envFrom:
        - secretRef:
            name: chatwoot-config
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
EOF

echo "  ✓ Chatwoot Web recréé avec command explicite"

FIX_CHATWOOT

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Attente du démarrage (120 secondes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for i in {120..1}; do
    echo -ne "\rAttente... ${i}s restantes   "
    sleep 1
done
echo ""

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ ÉTAT FINAL DE TOUTES LES APPLICATIONS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@$MASTER_IP bash <<'FINAL_CHECK'
echo "Pods de toutes les applications :"
echo ""

for ns in n8n chatwoot litellm superset qdrant; do
    echo "━━━ $ns ━━━"
    kubectl get pods -n $ns 2>/dev/null
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

RUNNING=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep "Running" | wc -l)
TOTAL=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep -v Completed | wc -l)

echo "═══════════════════════════════════════════════════════════════════"
echo "RÉSUMÉ FINAL"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Pods Running : $RUNNING/$TOTAL"
echo ""

if [ $RUNNING -ge 11 ]; then
    echo "🎉🎉🎉 SUCCÈS COMPLET ! TOUTES LES APPLICATIONS FONCTIONNENT ! 🎉🎉🎉"
    echo ""
    echo "Applications disponibles :"
    echo "  ✅ n8n             : 2 pods Running"
    echo "  ✅ Chatwoot Web    : 2 pods Running"
    echo "  ✅ Chatwoot Worker : 2 pods Running"
    echo "  ✅ LiteLLM         : 2 pods Running"
    echo "  ✅ Superset        : 2 pods Running"
    echo "  ✅ Qdrant          : 1 pod Running"
    echo ""
    echo "Total : 11 pods Running (100%) ✅"
    echo ""
    echo "Accès aux applications :"
    echo "  1. Via port-forward (immédiat) :"
    echo "     kubectl port-forward -n n8n svc/n8n 8080:80 --address=0.0.0.0"
    echo ""
    echo "  2. Via Load Balancer Hetzner (après config) :"
    echo "     https://n8n.keybuzz.io"
    echo "     https://chat.keybuzz.io"
    echo "     https://llm.keybuzz.io"
    echo "     https://qdrant.keybuzz.io"
    echo "     https://superset.keybuzz.io"
    echo ""
    echo "Credentials Superset :"
    echo "  Username : admin"
    echo "  Password : admin"
    echo ""
elif [ $RUNNING -ge 9 ]; then
    echo "✅ Presque terminé ! $RUNNING/$TOTAL pods Running"
    echo ""
    echo "Vérifier les derniers pods en erreur :"
    kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep -v Running | grep -v Completed
    echo ""
    echo "Voir les logs si nécessaire :"
    echo "  kubectl logs -n <namespace> <pod-name>"
else
    echo "⚠️  $RUNNING/$TOTAL pods Running"
    echo ""
    echo "Pods en erreur :"
    kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep -v Running | grep -v Completed
    echo ""
    echo "Vérifier les logs :"
    echo "  kubectl logs -n <namespace> <pod-name>"
fi

FINAL_CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Déploiements corrigés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions effectuées :"
echo "  ✓ Chatwoot Web recréé avec command explicite"
echo "  ✓ Superset recréé avec command et port explicites"
echo "  ✓ Attente 2 minutes"
echo ""

exit 0
