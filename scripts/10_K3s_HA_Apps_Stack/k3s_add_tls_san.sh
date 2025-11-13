#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        K3S HA - Ajout SAN 10.0.0.6 (LB2) aux certificats TLS      ║"
echo "║                      (sans réinstallation)                         ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"

# Vérifications
[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }
mkdir -p "$LOG_DIR"

MASTER_NODES=(k3s-master-01 k3s-master-02 k3s-master-03)
NEW_SAN="10.0.0.6"

echo ""
echo "═══ Configuration ═══"
echo "  Nouveau SAN à ajouter : $NEW_SAN (lb-keybuzz-2)"
echo "  Masters concernés     : ${MASTER_NODES[*]}"
echo ""
echo "⚠️  Cette opération va :"
echo "  1. Modifier le service systemd K3s sur chaque master"
echo "  2. Supprimer les certificats TLS existants"
echo "  3. Redémarrer K3s (régénération automatique des certs)"
echo "  4. Les workers resteront connectés (même token)"
echo ""
read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

# Récupérer les IPs privées
declare -A MASTER_IPS
for node in "${MASTER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
    if [ -z "$ip" ]; then
        echo -e "$KO IP privée introuvable pour $node"
        exit 1
    fi
    MASTER_IPS[$node]=$ip
    echo "  $node : $ip"
done

echo ""

# Fonction pour ajouter le SAN à un master
add_san_to_master() {
    local node="$1"
    local ip="$2"
    local log_file="$LOG_DIR/${node}_add_san.log"
    
    echo ""
    echo "═══ Traitement $node ($ip) ═══"
    echo ""
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash -s "$NEW_SAN" <<'REMOTE_ADD_SAN' | tee "$log_file"
set -u
set -o pipefail

NEW_SAN="$1"

echo "[$(date '+%F %T')] Vérification K3s..."

# Détecter le service (server ou agent)
if systemctl is-active --quiet k3s; then
    SERVICE="k3s"
elif systemctl is-active --quiet k3s-agent; then
    echo "[$(date '+%F %T')] WARN : Ce nœud est un agent, pas un master. Skip."
    exit 0
else
    echo "[$(date '+%F %T')] ERREUR : K3s n'est pas actif sur ce nœud"
    exit 1
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

echo "[$(date '+%F %T')] Modification du service $SERVICE..."

# Vérifier si le SAN existe déjà
if grep -q "\-\-tls-san.*${NEW_SAN}" "$SERVICE_FILE"; then
    echo "[$(date '+%F %T')] SAN $NEW_SAN déjà présent, rien à faire"
    exit 0
fi

# Ajouter le SAN dans ExecStart
# On cherche la ligne ExecStart et on ajoute --tls-san avant le dernier \
if grep -q "ExecStart=" "$SERVICE_FILE"; then
    # Backup
    cp "$SERVICE_FILE" "${SERVICE_FILE}.bak_$(date +%s)"
    
    # Ajouter --tls-san avant le dernier backslash de la ligne ExecStart
    sed -i "/ExecStart=/ {
        # Si la ligne se termine par un backslash, on ajoute avant
        s|\(.*\)\s*\\\\\s*$|\1 \\\\\n    --tls-san ${NEW_SAN} \\\\|
    }" "$SERVICE_FILE"
    
    echo "[$(date '+%F %T')] SAN ajouté au service systemd"
else
    echo "[$(date '+%F %T')] ERREUR : ExecStart introuvable dans $SERVICE_FILE"
    exit 1
fi

# Recharger systemd
echo "[$(date '+%F %T')] Rechargement systemd..."
systemctl daemon-reload

# Supprimer les certificats TLS existants (K3s les régénérera au démarrage)
echo "[$(date '+%F %T')] Suppression des certificats existants..."
rm -f /var/lib/rancher/k3s/server/tls/*.crt /var/lib/rancher/k3s/server/tls/*.key 2>/dev/null || true

# Redémarrer K3s
echo "[$(date '+%F %T')] Redémarrage K3s..."
systemctl restart $SERVICE

# Attendre que K3s soit actif
for i in {1..30}; do
    if systemctl is-active --quiet $SERVICE; then
        echo "[$(date '+%F %T')] K3s redémarré avec succès"
        break
    fi
    sleep 2
done

if ! systemctl is-active --quiet $SERVICE; then
    echo "[$(date '+%F %T')] ERREUR : K3s n'a pas redémarré"
    journalctl -u $SERVICE --no-pager -n 50
    exit 1
fi

echo "[$(date '+%F %T')] SAN $NEW_SAN ajouté avec succès"
REMOTE_ADD_SAN
    
    if [ $? -eq 0 ]; then
        echo -e "  $OK $node : SAN ajouté"
        return 0
    else
        echo -e "  $KO Erreur sur $node"
        echo ""
        tail -n 30 "$log_file"
        return 1
    fi
}

# Traiter chaque master
SUCCESS_COUNT=0
FAILED_COUNT=0

for node in "${MASTER_NODES[@]}"; do
    ip="${MASTER_IPS[$node]}"
    
    if add_san_to_master "$node" "$ip"; then
        ((SUCCESS_COUNT++))
    else
        ((FAILED_COUNT++))
    fi
    
    # Pause entre chaque master
    sleep 5
done

# Vérification finale
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ VÉRIFICATION FINALE ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

sleep 10

IP_MASTER01="${MASTER_IPS[k3s-master-01]}"

echo "État du cluster (depuis master-01) :"
echo ""
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes -o wide" 2>/dev/null || echo -e "$WARN Impossible de contacter K3s"
echo ""

READY_NODES=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get nodes --no-headers 2>/dev/null | grep -c Ready" || echo "0")

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Résumé :"
echo "  - Masters traités : $SUCCESS_COUNT/$((SUCCESS_COUNT + FAILED_COUNT))"
echo "  - Nœuds Ready     : $READY_NODES (attendu : 8)"
echo ""

if [ "$SUCCESS_COUNT" -eq 3 ] && [ "$READY_NODES" -ge 8 ]; then
    echo -e "$OK SAN $NEW_SAN ajouté avec succès à tous les masters"
    echo ""
    echo "Vérification des certificats :"
    echo "  ssh root@$IP_MASTER01 'openssl s_client -connect 10.0.0.6:6443 </dev/null 2>/dev/null | openssl x509 -noout -text | grep DNS'"
    echo ""
    echo "Test kubeconfig via LB2 :"
    echo "  export KUBECONFIG=/opt/keybuzz-installer/credentials/k3s.yaml"
    echo "  # Éditer temporairement server: https://10.0.0.6:6443"
    echo "  kubectl get nodes"
    echo ""
    exit 0
else
    echo -e "$WARN Certains masters ont échoué ou le cluster n'est pas complètement Ready"
    echo ""
    echo "Vérifiez les logs :"
    for node in "${MASTER_NODES[@]}"; do
        echo "  tail -n 50 $LOG_DIR/${node}_add_san.log"
    done
    echo ""
    exit 1
fi
