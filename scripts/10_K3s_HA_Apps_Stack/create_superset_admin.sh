#!/bin/bash
set -e

echo "🔧 Création du compte admin Superset..."

# Récupérer le premier pod Superset
POD_NAME=$(kubectl get pods -n superset -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD_NAME" ]; then
    echo "❌ Aucun pod Superset trouvé"
    exit 1
fi

echo "📍 Pod sélectionné : $POD_NAME"
echo ""

# Créer le compte admin
echo "Création du compte admin..."
kubectl exec -n superset $POD_NAME -- bash -c "
    superset db upgrade && \
    superset fab create-admin \
        --username admin \
        --firstname Admin \
        --lastname KeyBuzz \
        --email admin@keybuzz.io \
        --password SuperSecret123! && \
    superset init
"

echo ""
echo "✅ Compte admin créé avec succès !"
echo ""
echo "Credentials :"
echo "  URL      : http://superset.keybuzz.io"
echo "  Username : admin"
echo "  Password : SuperSecret123!"
echo ""
