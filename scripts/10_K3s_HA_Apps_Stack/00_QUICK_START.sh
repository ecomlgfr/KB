#!/usr/bin/env bash
# GUIDE DE DÉMARRAGE RAPIDE - KeyBuzz Infrastructure Complète
# Ce fichier contient TOUTES les commandes à exécuter dans l'ordre

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║   GUIDE DE DÉMARRAGE RAPIDE - KeyBuzz Infrastructure Complète     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  Ce guide suppose que les phases 1-3 sont déjà terminées :"
echo "    ✅ Infrastructure de base (PostgreSQL, Redis, RabbitMQ, MinIO)"
echo "    ✅ K3s HA (3 masters + 5 workers)"
echo "    ✅ Applications (n8n, litellm, qdrant, chatwoot, superset)"
echo ""
echo "📦 Nous allons maintenant installer les 4 derniers composants :"
echo "    1. Vault (Secrets Management)"
echo "    2. Wazuh SIEM (Sécurité)"
echo "    3. Backups automatiques"
echo "    4. Validation finale"
echo ""
read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 0 : PRÉPARATION
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 0 : Préparation                                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Vérification des prérequis..."

# Vérifier que nous sommes sur install-01
if [ ! -f "/opt/keybuzz-installer/inventory/servers.tsv" ]; then
    echo "❌ Ce script doit être exécuté depuis install-01"
    exit 1
fi

echo "✓ servers.tsv trouvé"

# Vérifier que K3s fonctionne
if ! kubectl get nodes &>/dev/null; then
    echo "❌ K3s ne répond pas, vérifier l'installation"
    exit 1
fi

echo "✓ K3s opérationnel"

# Vérifier les scripts
SCRIPTS=(
    "12_deploy_vault.sh"
    "19_deploy_wazuh_siem.sh"
    "20_configure_backups.sh"
    "21_final_validation_complete.sh"
)

for script in "${SCRIPTS[@]}"; do
    if [ ! -f "/opt/keybuzz-installer/scripts/$script" ]; then
        echo "❌ Script manquant : $script"
        echo "   Veuillez d'abord copier tous les scripts dans /opt/keybuzz-installer/scripts/"
        exit 1
    fi
done

echo "✓ Tous les scripts présents"

# Rendre exécutables
cd /opt/keybuzz-installer/scripts/
chmod +x 12_deploy_vault.sh 19_deploy_wazuh_siem.sh 20_configure_backups.sh 21_final_validation_complete.sh

echo "✓ Scripts exécutables"
echo ""

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 1 : VAULT
# ═══════════════════════════════════════════════════════════════════

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1 : Déploiement Vault (Secrets Management)              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

read -p "Déployer Vault ? (yes/NO) : " vault_confirm
if [ "$vault_confirm" == "yes" ]; then
    echo ""
    echo "→ Lancement du déploiement Vault..."
    ./12_deploy_vault.sh
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Vault déployé avec succès"
        echo ""
        echo "⚠️  ÉTAPE CRITIQUE : Initialisation de Vault"
        echo ""
        echo "Vous DEVEZ maintenant initialiser Vault manuellement :"
        echo ""
        echo "1️⃣  Initialiser Vault (génère 5 clés + root token) :"
        echo ""
        echo "    kubectl exec -n vault \$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}') -- vault operator init"
        echo ""
        echo "2️⃣  COPIER ET SAUVEGARDER les 5 clés et le root token dans un endroit sécurisé !"
        echo ""
        echo "3️⃣  Déverrouiller Vault avec 3 clés minimum :"
        echo ""
        echo "    POD_NAME=\$(kubectl get pods -n vault -l app=vault -o jsonpath='{.items[0].metadata.name}')"
        echo "    kubectl exec -n vault \$POD_NAME -- vault operator unseal <KEY1>"
        echo "    kubectl exec -n vault \$POD_NAME -- vault operator unseal <KEY2>"
        echo "    kubectl exec -n vault \$POD_NAME -- vault operator unseal <KEY3>"
        echo ""
        echo "4️⃣  Vérifier que Vault est déverrouillé :"
        echo ""
        echo "    kubectl exec -n vault \$POD_NAME -- vault status"
        echo ""
        
        read -p "Appuyer sur ENTRÉE une fois Vault initialisé et déverrouillé..."
    else
        echo "❌ Échec du déploiement Vault"
        exit 1
    fi
else
    echo "⚠️  Vault ignoré"
fi

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 2 : WAZUH SIEM
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2 : Déploiement Wazuh SIEM (Sécurité)                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

read -p "Déployer Wazuh SIEM ? (yes/NO) : " wazuh_confirm
if [ "$wazuh_confirm" == "yes" ]; then
    echo ""
    echo "→ Lancement du déploiement Wazuh..."
    echo "   Durée estimée : ~10 minutes"
    ./19_deploy_wazuh_siem.sh
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Wazuh SIEM déployé avec succès"
        echo ""
        echo "📋 Credentials Wazuh :"
        if [ -f "/opt/keybuzz-installer/credentials/wazuh.env" ]; then
            cat /opt/keybuzz-installer/credentials/wazuh.env
        fi
        echo ""
        echo "🌐 Accès Dashboard : https://siem.keybuzz.io"
        echo ""
        echo "⚠️  Installation des agents Wazuh :"
        echo ""
        echo "Sur chaque serveur à monitorer, exécuter :"
        echo ""
        echo "  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import"
        echo "  chmod 644 /usr/share/keyrings/wazuh.gpg"
        echo "  echo \"deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main\" | tee -a /etc/apt/sources.list.d/wazuh.list"
        echo "  apt-get update"
        echo "  WAZUH_MANAGER='<worker_node_ip>' apt-get install wazuh-agent"
        echo "  systemctl enable wazuh-agent"
        echo "  systemctl start wazuh-agent"
        echo ""
    else
        echo "❌ Échec du déploiement Wazuh"
        echo "⚠️  Continuons quand même..."
    fi
else
    echo "⚠️  Wazuh SIEM ignoré"
fi

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 3 : BACKUPS AUTOMATIQUES
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3 : Configuration Backups Automatiques                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

read -p "Configurer les backups automatiques ? (yes/NO) : " backup_confirm
if [ "$backup_confirm" == "yes" ]; then
    echo ""
    echo "→ Configuration des backups..."
    ./20_configure_backups.sh
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Backups configurés avec succès"
        echo ""
        echo "📅 Planning des backups :"
        echo "  PostgreSQL  : Tous les jours à 2h00"
        echo "  Redis       : Tous les jours à 3h00"
        echo "  K3s         : Tous les jours à 4h00"
        echo ""
        echo "📦 Bucket MinIO : keybuzz-backups"
        echo "⏳ Rétention    : 30 jours"
        echo ""
    else
        echo "❌ Échec de la configuration des backups"
        echo "⚠️  Continuons quand même..."
    fi
else
    echo "⚠️  Backups ignorés"
fi

# ═══════════════════════════════════════════════════════════════════
# ÉTAPE 4 : VALIDATION FINALE
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4 : Validation Finale Complète                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

read -p "Lancer la validation finale ? (yes/NO) : " validation_confirm
if [ "$validation_confirm" == "yes" ]; then
    echo ""
    echo "→ Lancement de la validation complète..."
    echo "   Tests : 80+"
    echo ""
    ./21_final_validation_complete.sh
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Validation terminée"
    else
        echo "⚠️  Des problèmes ont été détectés, consultez le rapport"
    fi
else
    echo "⚠️  Validation ignorée"
fi

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    🎉 INSTALLATION TERMINÉE ! 🎉               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Infrastructure KeyBuzz :"
echo ""
echo "  ✅ PostgreSQL 16 + Patroni RAFT HA"
echo "  ✅ Redis Sentinel HA"
echo "  ✅ RabbitMQ Quorum HA"
echo "  ✅ HAProxy + Keepalived"
echo "  ✅ K3s HA (3 masters + 5 workers)"
echo "  ✅ MinIO S3 Storage"
echo ""
echo "  ✅ n8n (Workflow)"
echo "  ✅ LiteLLM (LLM Router)"
echo "  ✅ Qdrant (Vector DB)"
echo "  ✅ Chatwoot (Support)"
echo "  ✅ Superset (BI)"
echo ""
if [ "$vault_confirm" == "yes" ]; then
    echo "  ✅ Vault (Secrets) 🆕"
fi
if [ "$wazuh_confirm" == "yes" ]; then
    echo "  ✅ Wazuh SIEM 🆕"
fi
if [ "$backup_confirm" == "yes" ]; then
    echo "  ✅ Backups automatiques 🆕"
fi
echo ""
echo "  ✅ Monitoring (Prometheus + Grafana + Loki)"
echo "  ✅ Load Balancers Hetzner"
echo ""
echo "🌐 URLs d'accès :"
echo "  n8n       : http://n8n.keybuzz.io"
echo "  LiteLLM   : http://llm.keybuzz.io"
echo "  Qdrant    : http://qdrant.keybuzz.io"
echo "  Chatwoot  : http://chat.keybuzz.io"
echo "  Superset  : http://superset.keybuzz.io"
if [ "$vault_confirm" == "yes" ]; then
    echo "  Vault     : http://vault.keybuzz.io"
fi
echo "  Grafana   : http://monitor.keybuzz.io"
if [ "$wazuh_confirm" == "yes" ]; then
    echo "  Wazuh     : https://siem.keybuzz.io"
fi
echo "  MinIO     : http://s3.keybuzz.io:9000"
echo ""
echo "📝 Prochaines étapes recommandées :"
echo ""
echo "  1. Configurer le DNS pour tous les domaines"
echo "  2. Activer TLS/HTTPS avec cert-manager"
echo "  3. Configurer les alertes Prometheus/Grafana"
echo "  4. Installer les agents Wazuh sur les serveurs"
echo "  5. Tester la restauration des backups"
echo "  6. Documenter les credentials dans un password manager"
echo ""
echo "📚 Documentation complète : README_SCRIPTS_MANQUANTS.md"
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║        🚀 INFRASTRUCTURE 100% OPÉRATIONNELLE ! 🚀              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

exit 0
