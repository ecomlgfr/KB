#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Diagnostic Load Balancer Hetzner → Workers                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
WORKER_NODES=(k3s-worker-01 k3s-worker-02 k3s-worker-03 k3s-worker-04 k3s-worker-05)

echo ""
echo "Problème identifié :"
echo "  → Résultats aléatoires (parfois 200, parfois 000)"
echo "  → 504 Gateway Timeout depuis navigateur"
echo "  → Load Balancer ne peut pas joindre les workers"
echo ""

HTTP_NODEPORT=$(ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null)

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Identifier l'IP privée du Load Balancer ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Le Load Balancer Hetzner a probablement une IP privée dans 10.0.0.0/16"
echo ""
echo "Pour la trouver, aller sur Hetzner Console :"
echo "  → Load Balancers → lb-keybuzz-1 → Onglet 'Networks'"
echo "  → Noter l'IP privée (ex: 10.0.0.5)"
echo ""

read -p "Entrez l'IP privée du Load Balancer (ex: 10.0.0.5) : " LB_PRIVATE_IP

if [ -z "$LB_PRIVATE_IP" ]; then
    echo -e "$KO IP vide, abandon"
    exit 1
fi

echo ""
echo "  IP Load Balancer (privée) : $LB_PRIVATE_IP"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test connectivité depuis LB vers workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Test depuis chaque worker :"
echo "(Si timeout → UFW bloque probablement le LB)"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker ($ip) ... "
    
    # Test si le worker peut recevoir depuis install-01 (devrait marcher)
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK (depuis install-01)"
    else
        echo -e "$KO (même depuis install-01)"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Vérification UFW sur les workers ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Vérification si le Load Balancer est autorisé dans UFW :"
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "→ $worker ($ip)"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<EOF
# Vérifier si l'IP du LB est autorisée
echo -n "  Autorisation depuis $LB_PRIVATE_IP ... "
if ufw status | grep -q "ALLOW.*$LB_PRIVATE_IP"; then
    echo -e "$OK"
elif ufw status | grep -q "ALLOW.*10.0.0.0/16"; then
    echo -e "$OK (via 10.0.0.0/16)"
else
    echo -e "$KO"
fi

# Vérifier si le port NodePort est ouvert
echo -n "  Port $HTTP_NODEPORT ouvert ... "
if ufw status | grep -q "$HTTP_NODEPORT"; then
    echo -e "$OK"
else
    echo -e "$KO"
fi
EOF
    
    echo ""
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 4. CORRECTION : Autoriser le Load Balancer ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

read -p "Autoriser le Load Balancer ($LB_PRIVATE_IP) dans UFW ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Correction annulée"; exit 0; }

echo ""
echo "Application de la correction sur tous les workers..."
echo ""

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo "→ $worker ($ip)"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<EOF
set -u

# Vérifier que le réseau 10.0.0.0/16 est autorisé
if ! ufw status | grep -q "10.0.0.0/16.*ALLOW"; then
    echo "  ✓ Ajout autorisation 10.0.0.0/16"
    ufw allow from 10.0.0.0/16 comment "Hetzner Private Network" >/dev/null 2>&1
else
    echo "  ✓ Réseau 10.0.0.0/16 déjà autorisé"
fi

# Recharger UFW
ufw reload >/dev/null 2>&1
echo "  ✓ UFW rechargé"
EOF
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 5. Test après correction ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "Attente 10s pour que les règles prennent effet..."
sleep 10

echo ""
echo "Test de connectivité depuis install-01 vers workers :"
echo ""

SUCCESS=0
FAILED=0

for worker in "${WORKER_NODES[@]}"; do
    ip=$(awk -F'\t' -v h="$worker" '$2==h {print $3}' "$SERVERS_TSV")
    
    echo -n "  $worker ($ip:$HTTP_NODEPORT) ... "
    
    if timeout 3 bash -c "</dev/tcp/$ip/$HTTP_NODEPORT" 2>/dev/null; then
        echo -e "$OK"
        ((SUCCESS++))
    else
        echo -e "$KO"
        ((FAILED++))
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "Résultat : $SUCCESS/$((SUCCESS+FAILED)) workers accessibles"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ $SUCCESS -ge 4 ]; then
    echo -e "$OK Connectivité OK"
    echo ""
    echo "Prochaines étapes :"
    echo ""
    echo "1. Vérifier dans Hetzner Console que les targets passent 'Healthy' :"
    echo "   https://console.hetzner.cloud/ → Load Balancers → lb-keybuzz-1"
    echo ""
    echo "2. Attendre 30 secondes que les health checks passent"
    echo ""
    echo "3. Tester depuis Internet :"
    echo "   curl http://llm.keybuzz.io"
    echo "   curl http://superset.keybuzz.io"
    echo ""
    echo "4. Vérifier stabilité (lancer 10 fois) :"
    echo "   for i in {1..10}; do curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://llm.keybuzz.io; sleep 1; done"
    echo ""
else
    echo -e "$WARN Problème persistant"
    echo ""
    echo "Debug supplémentaire :"
    echo ""
    echo "1. Vérifier les logs d'un worker :"
    echo "   ssh root@10.0.0.110"
    echo "   journalctl -u k3s-agent | grep -i 'refused\|denied\|blocked' | tail -20"
    echo ""
    echo "2. Vérifier UFW détaillé :"
    echo "   ssh root@10.0.0.110"
    echo "   ufw status numbered"
    echo ""
    echo "3. Test manuel depuis le LB (si possible) :"
    echo "   curl -v http://10.0.0.110:$HTTP_NODEPORT/healthz"
    echo ""
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 6. CONFIGURATION RECOMMANDÉE LOAD BALANCER HETZNER ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<CONFIG

Vérifier dans Hetzner Console : https://console.hetzner.cloud/

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1️⃣  ONGLET SERVICES (lb-keybuzz-1)

   SERVICE HTTP :
   ┌─────────────────────────────────────────────────────────────┐
   │ Listen Port       : 80                                       │
   │ Destination Port  : $HTTP_NODEPORT (NodePort K3s)                      │
   │ Protocol          : HTTP                                     │
   │ Proxy Protocol    : Off                                      │
   └─────────────────────────────────────────────────────────────┘

   SERVICE HTTPS (optionnel si TLS terminé sur LB) :
   ┌─────────────────────────────────────────────────────────────┐
   │ Listen Port       : 443                                      │
   │ Destination Port  : 32720 (NodePort HTTPS)                  │
   │ Protocol          : TCP                                      │
   │ Proxy Protocol    : Off                                      │
   └─────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

2️⃣  ONGLET TARGETS

   ⚠️  IMPORTANT : Utiliser les IPs PRIVÉES (10.0.0.x)

   Ajouter les 5 workers :
   ┌─────────────────────────────────────────────────────────────┐
   │ k3s-worker-01 : 10.0.0.110                                  │
   │ k3s-worker-02 : 10.0.0.111                                  │
   │ k3s-worker-03 : 10.0.0.112                                  │
   │ k3s-worker-04 : 10.0.0.113                                  │
   │ k3s-worker-05 : 10.0.0.114                                  │
   └─────────────────────────────────────────────────────────────┘

   État attendu : Tous "Healthy" (vert) ✅

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

3️⃣  ONGLET HEALTH CHECKS

   CRITIQUE : Configuration correcte du health check

   ┌─────────────────────────────────────────────────────────────┐
   │ Protocol          : HTTP                                     │
   │ Port              : $HTTP_NODEPORT (même que Destination Port)    │
   │ Path              : /healthz                                 │
   │ Interval          : 15 seconds                               │
   │ Timeout           : 10 seconds                               │
   │ Retries           : 3                                        │
   │ HTTP Status Codes : 200                                      │
   └─────────────────────────────────────────────────────────────┘

   ⚠️  Si le health check est mal configuré, les targets resteront
       "Unhealthy" même si les workers fonctionnent.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

4️⃣  ONGLET NETWORKS

   Vérifier que le Load Balancer est attaché au réseau privé :
   ┌─────────────────────────────────────────────────────────────┐
   │ Network : keybuzz-network (10.0.0.0/16)                    │
   │ IP      : $LB_PRIVATE_IP (IP privée du LB)                         │
   └─────────────────────────────────────────────────────────────┘

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CONFIG

echo ""
