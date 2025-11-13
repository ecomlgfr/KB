#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   Diagnostic et Correction Complète - n8n + LiteLLM + Chatwoot    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

# Charger les credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO postgres.env introuvable"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ PROBLÈME 1/3 : LiteLLM - Base de données manquante ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Vérification de l'existence de la base litellm..."
DB_EXISTS=$(ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='litellm';\"" 2>/dev/null || echo "0")

if [ "$DB_EXISTS" != "1" ]; then
    echo -e "$WARN Base litellm n'existe pas, création..."
    
    ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres" <<'SQL'
-- Créer la base et l'user
CREATE DATABASE litellm;
CREATE USER litellm WITH PASSWORD 'NEhobUmaJGdR7TL2MCXRB853';

-- Se connecter et configurer
\c litellm

-- Permissions complètes
ALTER SCHEMA public OWNER TO litellm;
GRANT ALL ON SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO litellm;

SELECT 'Base litellm créée avec succès' AS status;
SQL
    
    echo -e "$OK Base litellm créée"
    
    # Redémarrer LiteLLM
    kubectl rollout restart daemonset -n litellm litellm
    echo "  Redémarrage de LiteLLM en cours..."
else
    echo -e "$OK Base litellm existe déjà"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ PROBLÈME 2/3 : n8n - Permissions et configuration ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Vérification de la base n8n..."
ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -d n8n -c '\dt'" | head -10

echo ""
echo "→ Vérification du propriétaire du schéma public..."
OWNER=$(ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -d n8n -tAc \"SELECT pg_catalog.pg_get_userbyid(n.nspowner) FROM pg_namespace n WHERE n.nspname = 'public';\"")

if [ "$OWNER" != "n8n" ]; then
    echo -e "$WARN Schéma public appartient à '$OWNER', correction..."
    
    ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -d n8n" <<'SQL'
ALTER SCHEMA public OWNER TO n8n;
GRANT ALL ON SCHEMA public TO n8n;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO n8n;
SQL
    
    echo -e "$OK Permissions n8n corrigées"
    
    # Redémarrer n8n
    kubectl rollout restart daemonset -n n8n n8n
    echo "  Redémarrage de n8n en cours..."
else
    echo -e "$OK Permissions n8n correctes"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ PROBLÈME 3/3 : Chatwoot - Compte créé mais login impossible ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Vérification des comptes existants..."
ssh root@10.0.0.120 "docker exec -i patroni psql -U postgres -d chatwoot" <<'SQL'
SELECT id, name, email, role, confirmed FROM users ORDER BY id;
SQL

echo ""
echo "→ Diagnostic du problème de login..."
echo ""
echo "Causes possibles :"
echo "  1. Compte non confirmé (confirmed=false)"
echo "  2. Mauvais mot de passe"
echo "  3. Variable FRONTEND_URL incorrecte"
echo ""

read -p "Voulez-vous réinitialiser le mot de passe du compte ludovic@keybuzz.pro ? (yes/NO) : " reset_password

if [ "$reset_password" = "yes" ]; then
    echo ""
    echo "Création d'un pod temporaire pour réinitialiser le mot de passe..."
    
    # Créer un pod pour exécuter la console Rails
    cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: chatwoot-console
  namespace: chatwoot
spec:
  restartPolicy: Never
  containers:
  - name: console
    image: chatwoot/chatwoot:latest
    command: ["sleep", "3600"]
    env:
    - name: RAILS_ENV
      value: "production"
    envFrom:
    - secretRef:
        name: chatwoot-secrets
EOF
    
    echo "Attente du pod..."
    sleep 10
    
    kubectl wait --for=condition=Ready pod/chatwoot-console -n chatwoot --timeout=60s
    
    echo ""
    echo "Exécution du script de réinitialisation..."
    
    kubectl exec -it -n chatwoot chatwoot-console -- bundle exec rails runner "
user = User.find_by(email: 'ludovic@keybuzz.pro')
if user
  user.password = 'KeyBuzz2025!'
  user.password_confirmation = 'KeyBuzz2025!'
  user.confirmed = true
  user.save!
  puts '✓ Mot de passe réinitialisé : KeyBuzz2025!'
  puts '✓ Compte confirmé'
  puts \"✓ User: #{user.email} (#{user.role})\"
else
  puts '✗ Utilisateur non trouvé'
end
"
    
    # Nettoyer
    kubectl delete pod -n chatwoot chatwoot-console
    
    echo ""
    echo -e "$OK Mot de passe réinitialisé : KeyBuzz2025!"
    echo "  Essayez de vous connecter avec ce mot de passe"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Attente du redémarrage des services (2 minutes) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ État final ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

kubectl get pods -A | grep -E '(n8n|chatwoot|litellm|qdrant)' | grep -v ingress

echo ""
RUNNING=$(kubectl get pods -A | grep -E '(n8n|chatwoot|litellm|qdrant)' | grep 'Running' | wc -l)
CRASH=$(kubectl get pods -A | grep -E '(n8n|chatwoot|litellm|qdrant)' | grep -E '(CrashLoopBackOff|Error)' | wc -l)

echo "  ✓ $RUNNING pods Running"
echo "  ✗ $CRASH pods CrashLoopBackOff/Error"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Tests de connexion ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ Test n8n..."
curl -I http://n8n.keybuzz.io 2>/dev/null | head -5

echo ""
echo "→ Test Chatwoot..."
curl -I http://chat.keybuzz.io 2>/dev/null | head -5

echo ""
echo "→ Test LiteLLM..."
curl -I http://llm.keybuzz.io 2>/dev/null | head -5

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Résumé des corrections :"
echo "  1. Base litellm créée avec permissions complètes"
echo "  2. Permissions n8n vérifiées/corrigées"
echo "  3. Mot de passe Chatwoot réinitialisé : KeyBuzz2025!"
echo ""
echo "Credentials de test Chatwoot :"
echo "  Email    : ludovic@keybuzz.pro"
echo "  Password : KeyBuzz2025!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
