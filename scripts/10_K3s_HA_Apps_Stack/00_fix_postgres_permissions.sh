#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   Correction Permissions PostgreSQL - Apps K3S                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

# Charger le mot de passe
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$KO postgres.env introuvable"
    exit 1
fi

echo ""
echo "PostgreSQL Node : 10.0.0.120"
echo "Mot de passe : ${POSTGRES_PASSWORD:0:10}***"
echo ""

read -p "Corriger les permissions ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══ Correction des permissions ═══"
echo ""

# Créer le script SQL localement
cat > /tmp/fix_permissions.sql <<EOF
-- n8n
\c n8n
ALTER SCHEMA public OWNER TO n8n;
GRANT ALL ON SCHEMA public TO n8n;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO n8n;
SELECT 'n8n OK' AS status;

-- litellm
\c litellm
ALTER SCHEMA public OWNER TO litellm;
GRANT ALL ON SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO litellm;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO litellm;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO litellm;
SELECT 'litellm OK' AS status;

-- chatwoot
\c chatwoot
ALTER SCHEMA public OWNER TO chatwoot;
GRANT ALL ON SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO chatwoot;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO chatwoot;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO chatwoot;
SELECT 'chatwoot OK' AS status;

-- superset
\c superset
ALTER SCHEMA public OWNER TO superset;
GRANT ALL ON SCHEMA public TO superset;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO superset;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO superset;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO superset;
SELECT 'superset OK' AS status;

-- erpnext
\c erpnext
ALTER SCHEMA public OWNER TO erpnext;
GRANT ALL ON SCHEMA public TO erpnext;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO erpnext;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO erpnext;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO erpnext;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO erpnext;
SELECT 'erpnext OK' AS status;
EOF

# Copier le script sur le serveur
scp -o StrictHostKeyChecking=no /tmp/fix_permissions.sql root@10.0.0.120:/tmp/

# Exécuter sur le serveur
ssh -o StrictHostKeyChecking=no root@10.0.0.120 "
  CONTAINER=\$(docker ps | grep postgres | awk '{print \$1}')
  docker exec -i -e PGPASSWORD='${POSTGRES_PASSWORD}' \$CONTAINER psql -U postgres < /tmp/fix_permissions.sql
  rm /tmp/fix_permissions.sql
"

# Nettoyer
rm /tmp/fix_permissions.sql

if [ $? -eq 0 ]; then
    echo ""
    echo -e "$OK Permissions corrigées"
    echo ""
    echo "Redémarrez maintenant les pods :"
    echo "  kubectl rollout restart daemonset -n n8n n8n"
    echo "  kubectl rollout restart daemonset -n litellm litellm"
    echo "  kubectl rollout restart daemonset -n chatwoot chatwoot-web"
    echo "  kubectl rollout restart daemonset -n chatwoot chatwoot-worker"
    echo ""
else
    echo ""
    echo -e "$KO Erreur"
    exit 1
fi
