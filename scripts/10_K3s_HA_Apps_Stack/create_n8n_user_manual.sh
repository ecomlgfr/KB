#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    CRÉATION MANUELLE COMPTE N8N - Contournement boucle infinie    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✅ OK\033[0m'
KO='\033[0;31m❌ KO\033[0m'
WARN='\033[0;33m⚠️ WARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
POSTGRES_ENV="/opt/keybuzz-installer/credentials/postgres.env"
LOG_FILE="/opt/keybuzz-installer/logs/create_n8n_user_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

# Vérifications préliminaires
if [ ! -f "$SERVERS_TSV" ]; then
    echo -e "$KO servers.tsv introuvable : $SERVERS_TSV"
    exit 1
fi

if [ ! -f "$POSTGRES_ENV" ]; then
    echo -e "$KO postgres.env introuvable : $POSTGRES_ENV"
    exit 1
fi

source "$POSTGRES_ENV"

IP_DB_LB="10.0.0.10"

echo ""
echo "🎯 Configuration :"
echo "   • PostgreSQL : $IP_DB_LB:5432"
echo "   • Base       : n8n"
echo "   • User DB    : ${POSTGRES_USER}"
echo ""

# Fonction pour générer un UUID v4
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# Fonction pour hasher un mot de passe (bcrypt simulé avec sha256 pour démo)
hash_password() {
    local password=$1
    # Note : n8n utilise bcrypt, mais pour ce script de démo on utilise sha256
    # En production, utiliser un vrai bcrypt hash ou laisser n8n gérer
    echo -n "$password" | sha256sum | awk '{print $1}'
}

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. VÉRIFICATION BASE N8N ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if ! PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT 1;" &>/dev/null; then
    echo -e "$KO Base de données n8n inaccessible ou n'existe pas"
    echo ""
    echo "🔧 Création de la base n8n..."
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d postgres <<-EOSQL
		CREATE DATABASE n8n;
		GRANT ALL PRIVILEGES ON DATABASE n8n TO ${POSTGRES_USER};
	EOSQL
    echo -e "$OK Base n8n créée"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. VÉRIFICATION STRUCTURE TABLES ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "🔍 Liste des tables existantes..."
TABLES=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null)

if [ "$TABLES" -eq 0 ]; then
    echo -e "$WARN Aucune table dans n8n - les migrations n8n doivent s'exécuter au premier démarrage"
    echo ""
    echo "💡 Solution : Redémarrer les pods n8n pour qu'ils créent les tables automatiquement"
    echo "   kubectl rollout restart daemonset/n8n -n n8n"
    echo ""
    read -p "Voulez-vous que je redémarre les pods n8n maintenant ? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl rollout restart daemonset/n8n -n n8n"
        echo -e "$OK Pods n8n en cours de redémarrage..."
        echo "   Attendez 30 secondes puis relancez ce script"
        exit 0
    fi
else
    echo -e "$OK $TABLES tables trouvées dans n8n"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. VÉRIFICATION TABLE USER ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if ! PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT 1 FROM \"user\" LIMIT 1;" &>/dev/null; then
    echo -e "$KO Table 'user' n'existe pas ou n'est pas accessible"
    echo "   Les migrations n8n n'ont pas été exécutées correctement"
    echo ""
    echo "💡 Redémarrez les pods n8n et vérifiez les logs"
    exit 1
fi

echo "🔍 Utilisateurs existants..."
USER_COUNT=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -tAc "SELECT COUNT(*) FROM \"user\"" 2>/dev/null)
echo "   Nombre d'utilisateurs : $USER_COUNT"

if [ "$USER_COUNT" -gt 0 ]; then
    echo ""
    echo "📋 Liste des utilisateurs :"
    PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n -c "SELECT id, email, \"firstName\", \"lastName\", \"createdAt\" FROM \"user\";"
    echo ""
    read -p "Des utilisateurs existent déjà. Voulez-vous en créer un nouveau quand même ? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Annulé par l'utilisateur"
        exit 0
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. CRÉATION UTILISATEUR N8N ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Demander les informations utilisateur
read -p "Email : " USER_EMAIL
read -p "Prénom : " USER_FIRSTNAME
read -p "Nom : " USER_LASTNAME
read -sp "Mot de passe : " USER_PASSWORD
echo ""

if [ -z "$USER_EMAIL" ] || [ -z "$USER_PASSWORD" ]; then
    echo -e "$KO Email et mot de passe sont obligatoires"
    exit 1
fi

# Générer un UUID pour l'utilisateur
USER_ID=$(generate_uuid)

# Note importante sur le hash du mot de passe
echo ""
echo -e "$WARN IMPORTANT : Ce script crée un compte avec un hash SHA256 simple"
echo "   Pour un hash bcrypt compatible n8n, utilisez la commande :"
echo "   node -e \"console.log(require('bcryptjs').hashSync('$USER_PASSWORD', 10))\""
echo ""
read -p "Continuer avec SHA256 (NON recommandé pour production) ? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Annulé - Utilisez l'interface web n8n ou un vrai hash bcrypt"
    exit 0
fi

PASSWORD_HASH=$(hash_password "$USER_PASSWORD")

echo ""
echo "🔧 Insertion de l'utilisateur dans la base..."

PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "$IP_DB_LB" -p 5432 -U "${POSTGRES_USER}" -d n8n <<-EOSQL
	INSERT INTO "user" (
	    id,
	    email,
	    "firstName",
	    "lastName",
	    password,
	    "createdAt",
	    "updatedAt",
	    "globalRole",
	    disabled
	) VALUES (
	    '$USER_ID',
	    '$USER_EMAIL',
	    '$USER_FIRSTNAME',
	    '$USER_LASTNAME',
	    '$PASSWORD_HASH',
	    NOW(),
	    NOW(),
	    'global:owner',
	    false
	);
EOSQL

if [ $? -eq 0 ]; then
    echo -e "$OK Utilisateur créé avec succès !"
    echo ""
    echo "📧 Email    : $USER_EMAIL"
    echo "🔑 Password : $USER_PASSWORD"
    echo "👤 ID       : $USER_ID"
    echo "🎭 Rôle     : global:owner (admin)"
    echo ""
    echo -e "$WARN Note : Le hash SHA256 ne fonctionnera probablement PAS avec n8n"
    echo "   Utilisez l'interface web pour créer un vrai compte, ou :"
    echo "   1. Connectez-vous au pod n8n"
    echo "   2. Exécutez : n8n user:create --email=$USER_EMAIL --password=$USER_PASSWORD"
else
    echo -e "$KO Erreur lors de la création de l'utilisateur"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. MÉTHODE RECOMMANDÉE (bcrypt) ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
N8N_POD=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n n8n --no-headers -o custom-columns=:metadata.name | head -1" 2>/dev/null)

echo "💡 Méthode recommandée pour créer un compte avec bcrypt :"
echo ""
echo "   # Depuis install-01, exécutez :"
echo "   ssh root@$IP_MASTER01 \"kubectl exec -n n8n $N8N_POD -- n8n user-management:reset --email=$USER_EMAIL --password=$USER_PASSWORD\""
echo ""
echo "   Ou pour créer un nouveau compte :"
echo "   ssh root@$IP_MASTER01 \"kubectl exec -n n8n $N8N_POD -- n8n user:create --email=$USER_EMAIL --password=$USER_PASSWORD --role=owner\""
echo ""

read -p "Voulez-vous essayer de créer le compte via la CLI n8n maintenant ? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "🔧 Création du compte via CLI n8n..."
    
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl exec -n n8n $N8N_POD -- n8n user-management:reset --email=\"$USER_EMAIL\" --password=\"$USER_PASSWORD\"" 2>&1 && {
        echo -e "$OK Compte créé/réinitialisé via CLI n8n"
    } || {
        echo -e "$WARN La commande a échoué, mais le compte SQL existe"
    }
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "Terminé : $(date)"
echo "Log : $LOG_FILE"
echo "════════════════════════════════════════════════════════════════════"
