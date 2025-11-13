#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           Correction du secret Superset (SECRET_KEY)              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

if [ -z "$IP_MASTER01" ]; then
    echo -e "$KO IP de k3s-master-01 introuvable dans servers.tsv"
    exit 1
fi

echo ""
echo "═══ Configuration ═══"
echo "  Master-01 : $IP_MASTER01"
echo ""

echo "Problème détecté :"
echo "  Superset refuse de démarrer avec :"
echo "  'Refusing to start due to insecure SECRET_KEY'"
echo ""
echo "Solution :"
echo "  Générer une vraie SECRET_KEY aléatoire et mettre à jour le secret K8s"
echo ""

read -p "Corriger le secret Superset ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Correction du secret Superset ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'EOFIX'
set -u
set -o pipefail

echo "[$(date '+%F %T')] Génération d'une SECRET_KEY sécurisée..."

# Générer une clé aléatoire de 42 caractères
SECRET_KEY=$(openssl rand -base64 42)

echo "  ✓ SECRET_KEY générée"
echo ""

echo "[$(date '+%F %T')] Mise à jour du secret Kubernetes..."

# Vérifier si le secret existe
if ! kubectl get secret superset-config -n superset >/dev/null 2>&1; then
    echo "  ✗ Le secret superset-config n'existe pas"
    echo ""
    echo "  Création du secret depuis le .env..."
    
    if [ -f /opt/keybuzz/apps/superset.env ]; then
        # Créer le secret depuis le .env
        kubectl create secret generic superset-config \
          --from-env-file=/opt/keybuzz/apps/superset.env \
          -n superset
        
        echo "  ✓ Secret créé depuis superset.env"
    else
        echo "  ✗ Fichier /opt/keybuzz/apps/superset.env introuvable"
        echo ""
        echo "  Création d'un secret minimal..."
        
        kubectl create secret generic superset-config \
          --from-literal=SUPERSET_SECRET_KEY="$SECRET_KEY" \
          -n superset
        
        echo "  ✓ Secret minimal créé"
    fi
else
    echo "  ✓ Secret superset-config existe déjà"
fi

echo ""
echo "[$(date '+%F %T')] Ajout/Mise à jour de SUPERSET_SECRET_KEY..."

# Encoder la SECRET_KEY en base64
SECRET_KEY_B64=$(echo -n "$SECRET_KEY" | base64 -w0)

# Patcher le secret
kubectl patch secret superset-config -n superset -p \
  "{\"data\":{\"SUPERSET_SECRET_KEY\":\"$SECRET_KEY_B64\"}}"

if [ $? -eq 0 ]; then
    echo "  ✓ SUPERSET_SECRET_KEY mise à jour"
else
    echo "  ✗ Erreur lors de la mise à jour"
    exit 1
fi

echo ""
echo "[$(date '+%F %T')] Vérification du secret..."

# Afficher les clés du secret (sans les valeurs)
kubectl get secret superset-config -n superset -o jsonpath='{.data}' | jq -r 'keys[]' | while read key; do
    echo "  - $key"
done

echo ""
echo "[$(date '+%F %T')] ✓ Secret Superset corrigé"
echo ""
echo "La SECRET_KEY a été définie sur :"
echo "$SECRET_KEY" | head -c 20
echo "... (42 caractères)"

EOFIX

if [ $? -eq 0 ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$OK Secret Superset corrigé"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Prochaine étape : redémarrer le déploiement Superset"
    echo ""
    echo "  ssh root@$IP_MASTER01 kubectl rollout restart deployment/superset -n superset"
    echo ""
else
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "$KO Erreur lors de la correction"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Vérification manuelle :"
    echo "  ssh root@$IP_MASTER01"
    echo "  kubectl get secret superset-config -n superset -o yaml"
    echo ""
fi

exit 0
