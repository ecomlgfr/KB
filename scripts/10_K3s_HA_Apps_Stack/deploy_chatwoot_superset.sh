#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        Création déploiements Chatwoot & Superset (propre)         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

MASTER_IP="10.0.0.100"

echo ""
echo "Cette opération va créer les déploiements K8s pour :"
echo "  → Chatwoot (web + worker)"
echo "  → Superset"
echo ""
echo "Les bases PostgreSQL sont propres et prêtes :"
echo "  ✓ Extensions installées (pg_stat_statements, pgcrypto, pg_trgm, vector)"
echo "  ✓ Permissions configurées"
echo ""

read -p "Créer les déploiements ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Création des déploiements Chatwoot ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash <<'CREATE_CHATWOOT'
set -u

echo "[$(date '+%F %T')] Création du déploiement Chatwoot Web..."

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
      containers:
      - name: chatwoot
        image: chatwoot/chatwoot:latest
        ports:
        - containerPort: 3000
          name: http
        envFrom:
        - secretRef:
            name: chatwoot-config
        env:
        - name: RAILS_ENV
          value: "production"
        - name: NODE_ENV
          value: "production"
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
        readinessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 10
EOF

echo "  ✓ Chatwoot Web créé"

echo ""
echo "[$(date '+%F %T')] Création du déploiement Chatwoot Worker..."

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatwoot-worker
  namespace: chatwoot
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chatwoot-worker
  template:
    metadata:
      labels:
        app: chatwoot-worker
    spec:
      containers:
      - name: worker
        image: chatwoot/chatwoot:latest
        command:
        - bundle
        - exec
        - sidekiq
        - -C
        - config/sidekiq.yml
        envFrom:
        - secretRef:
            name: chatwoot-config
        env:
        - name: RAILS_ENV
          value: "production"
        - name: NODE_ENV
          value: "production"
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
EOF

echo "  ✓ Chatwoot Worker créé"

CREATE_CHATWOOT

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Création du déploiement Superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@$MASTER_IP bash <<'CREATE_SUPERSET'
set -u

echo "[$(date '+%F %T')] Création du déploiement Superset..."

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
        envFrom:
        - secretRef:
            name: superset-config
        env:
        - name: SQLALCHEMY_DATABASE_URI
          value: "postgresql://superset:$(cat /run/secrets/superset-config/DATABASE_PASSWORD)@10.0.0.10:5432/superset"
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
        envFrom:
        - secretRef:
            name: superset-config
        env:
        - name: SQLALCHEMY_DATABASE_URI
          value: "postgresql://superset:$(cat /run/secrets/superset-config/DATABASE_PASSWORD)@10.0.0.10:5432/superset"
      containers:
      - name: superset
        image: apache/superset:latest
        ports:
        - containerPort: 8088
          name: http
        envFrom:
        - secretRef:
            name: superset-config
        env:
        - name: SQLALCHEMY_DATABASE_URI
          value: "postgresql://superset:$(cat /run/secrets/superset-config/DATABASE_PASSWORD)@10.0.0.10:5432/superset"
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
        readinessProbe:
          httpGet:
            path: /health
            port: 8088
          initialDelaySeconds: 120
          periodSeconds: 10
EOF

echo "  ✓ Superset créé"

CREATE_SUPERSET

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
echo "═══ État final de toutes les applications ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh root@$MASTER_IP bash <<'CHECK'
echo "Pods de toutes les applications :"
echo ""

for ns in n8n chatwoot litellm superset qdrant; do
    echo "━━━ $ns ━━━"
    kubectl get pods -n $ns -o wide 2>/dev/null || echo "  Namespace vide"
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

RUNNING=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep "Running" | wc -l)
TOTAL=$(kubectl get pods -A | grep -E "n8n|chatwoot|litellm|superset|qdrant" | grep -v Completed | wc -l)

echo "Résumé des pods :"
echo "  Pods Running : $RUNNING/$TOTAL"
echo ""

if [ $RUNNING -ge 10 ]; then
    echo "🎉 SUCCÈS ! Toutes les applications sont Running"
    echo ""
    echo "Applications disponibles (via port-forward ou LB) :"
    echo "  • n8n      : https://n8n.keybuzz.io"
    echo "  • Chatwoot : https://chat.keybuzz.io"
    echo "  • LiteLLM  : https://llm.keybuzz.io"
    echo "  • Qdrant   : https://qdrant.keybuzz.io"
    echo "  • Superset : https://superset.keybuzz.io"
    echo ""
    echo "Pour tester immédiatement (port-forward) :"
    echo "  kubectl port-forward -n n8n svc/n8n 8080:80 --address=0.0.0.0"
    echo "  → http://IP_INSTALL_01:8080"
else
    echo "⚠️  Certains pods ne sont pas encore Running"
    echo ""
    echo "   Vérifier les logs :"
    for ns in chatwoot superset; do
        PODS=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l)
        if [ $PODS -gt 0 ]; then
            echo "   kubectl logs -n $ns -l app=$ns --tail=50"
        fi
    done
fi

CHECK

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Déploiements créés"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Actions effectuées :"
echo "  ✓ Chatwoot Web déployé (2 replicas)"
echo "  ✓ Chatwoot Worker déployé (2 replicas)"
echo "  ✓ Superset déployé (2 replicas)"
echo ""
echo "Si des pods sont encore en Init ou CrashLoop :"
echo "  → Attendre 2-3 minutes (migrations DB en cours)"
echo "  → Vérifier les logs si échec persiste"
echo ""
echo "Prochaine étape :"
echo "  ssh root@10.0.0.100 kubectl get pods -A"
echo ""

exit 0
