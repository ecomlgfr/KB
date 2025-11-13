#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# UFW_HELPERS.sh - Fonctions sécurisées pour gestion UFW
# ════════════════════════════════════════════════════════════════════════════
#
# USAGE : Source ce fichier dans vos scripts
#   source /opt/keybuzz-installer/lib/ufw_helpers.sh
#   add_ufw_rule_safe "from 10.0.0.0/16 to any port 6443 proto tcp" "K3s API"
#
# IMPORTANT : Ces fonctions AJOUTENT des règles sans jamais :
#   - Réinitialiser UFW (pas de ufw reset)
#   - Recharger UFW (pas de ufw reload)
#   - Désactiver/Réactiver UFW (pas de ufw disable/enable)
#   → Préserve les connexions SSH existantes
#
# ════════════════════════════════════════════════════════════════════════════

# Couleurs pour output
UFW_OK='\033[0;32m✓\033[0m'
UFW_SKIP='\033[0;33m⊘\033[0m'
UFW_KO='\033[0;31m✗\033[0m'

# ────────────────────────────────────────────────────────────────────────────
# add_ufw_rule_safe : Ajoute une règle UFW de manière idempotente
# ────────────────────────────────────────────────────────────────────────────
# ARGS:
#   $1 : Règle UFW (ex: "from 10.0.0.0/16 to any port 6443 proto tcp")
#   $2 : Commentaire (ex: "K3s API")
#
# EXEMPLES:
#   add_ufw_rule_safe "from 10.0.0.0/16 to any port 6443 proto tcp" "K3s API"
#   add_ufw_rule_safe "proto tcp from any to any port 22" "SSH"
#
# COMPORTEMENT:
#   - Vérifie si la règle existe déjà (par le commentaire)
#   - Si existe → skip (pas d'erreur)
#   - Si n'existe pas → ajoute la règle
#   - Ne recharge JAMAIS UFW (préserve les connexions SSH)
# ────────────────────────────────────────────────────────────────────────────
add_ufw_rule_safe() {
    local RULE="$1"
    local COMMENT="$2"
    
    # Vérifier que UFW est installé
    if ! command -v ufw &>/dev/null; then
        echo -e "${UFW_KO} UFW non installé"
        return 1
    fi
    
    # Vérifier si la règle existe déjà (recherche par commentaire)
    if ufw status numbered 2>/dev/null | grep -q "$COMMENT"; then
        echo -e "${UFW_SKIP} Règle existante : $COMMENT"
        return 0
    fi
    
    # Ajouter la règle
    if ufw allow $RULE comment "$COMMENT" &>/dev/null; then
        echo -e "${UFW_OK} Règle ajoutée : $COMMENT"
        return 0
    else
        echo -e "${UFW_KO} Échec ajout règle : $COMMENT"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# add_k3s_master_rules : Ajoute toutes les règles UFW pour un master K3s
# ────────────────────────────────────────────────────────────────────────────
add_k3s_master_rules() {
    echo "═══ Configuration UFW pour K3s Master ═══"
    
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 6443 proto tcp" "K3s API"
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 10250 proto tcp" "K3s kubelet"
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 8472 proto udp" "K3s VXLAN"
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 51820 proto udp" "K3s Flannel WireGuard"
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 2379:2380 proto tcp" "K3s etcd"
    
    echo "Configuration UFW K3s Master terminée (sans interruption)"
}

# ────────────────────────────────────────────────────────────────────────────
# add_k3s_worker_rules : Ajoute toutes les règles UFW pour un worker K3s
# ────────────────────────────────────────────────────────────────────────────
add_k3s_worker_rules() {
    echo "═══ Configuration UFW pour K3s Worker ═══"
    
    # Les workers n'ont pas besoin de l'API server (6443) ni etcd (2379-2380)
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 10250 proto tcp" "K3s kubelet"
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 8472 proto udp" "K3s VXLAN"
    add_ufw_rule_safe "from 10.0.0.0/16 to any port 51820 proto udp" "K3s Flannel WireGuard"
    
    echo "Configuration UFW K3s Worker terminée (sans interruption)"
}

# ────────────────────────────────────────────────────────────────────────────
# check_ufw_rule : Vérifie si une règle UFW existe
# ────────────────────────────────────────────────────────────────────────────
# ARGS:
#   $1 : Commentaire de la règle
#
# RETURN:
#   0 si la règle existe, 1 sinon
# ────────────────────────────────────────────────────────────────────────────
check_ufw_rule() {
    local COMMENT="$1"
    
    if ufw status numbered 2>/dev/null | grep -q "$COMMENT"; then
        return 0
    else
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# show_ufw_k3s_rules : Affiche toutes les règles UFW liées à K3s
# ────────────────────────────────────────────────────────────────────────────
show_ufw_k3s_rules() {
    echo "═══ Règles UFW K3s actuelles ═══"
    ufw status numbered 2>/dev/null | grep -E "K3s|k3s" || echo "Aucune règle K3s trouvée"
}

# ────────────────────────────────────────────────────────────────────────────
# BONNES PRATIQUES UFW - À NE JAMAIS FAIRE
# ────────────────────────────────────────────────────────────────────────────
#
# ❌ NE JAMAIS FAIRE :
#   ufw reset                    # Supprime TOUTES les règles (y compris SSH)
#   ufw reload                   # Peut couper temporairement les connexions
#   ufw disable && ufw enable    # Coupe toutes les connexions actives
#   ufw --force enable           # Idem
#   ufw delete <number>          # Risque de supprimer SSH par erreur
#
# ✅ À FAIRE :
#   ufw allow <rule> comment "..."     # Ajoute une règle (idempotent avec notre fonction)
#   ufw status                         # Consulter sans modifier
#   ufw status numbered                # Consulter avec numéros
#
# ────────────────────────────────────────────────────────────────────────────

# ════════════════════════════════════════════════════════════════════════════
# EXEMPLE D'UTILISATION DANS UN SCRIPT
# ════════════════════════════════════════════════════════════════════════════
#
# #!/usr/bin/env bash
# set -u
# set -o pipefail
#
# # Source les helpers UFW
# source /opt/keybuzz-installer/lib/ufw_helpers.sh
#
# # Ajouter les règles K3s master
# add_k3s_master_rules
#
# # Ou ajouter une règle custom
# add_ufw_rule_safe "from 192.168.1.0/24 to any port 8080 proto tcp" "Custom App"
#
# # Vérifier si une règle existe
# if check_ufw_rule "K3s API"; then
#     echo "Règle K3s API présente"
# fi
#
# # Afficher les règles K3s
# show_ufw_k3s_rules
#
# ════════════════════════════════════════════════════════════════════════════

# Export des fonctions pour utilisation dans les scripts qui sourcent ce fichier
export -f add_ufw_rule_safe
export -f add_k3s_master_rules
export -f add_k3s_worker_rules
export -f check_ufw_rule
export -f show_ufw_k3s_rules

echo "Helpers UFW chargés (fonctions safe pour K3s)"
