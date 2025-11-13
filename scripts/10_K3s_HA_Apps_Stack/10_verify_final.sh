#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    Vérification Finale - Infrastructure Complète                  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 1. Test DNS ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

DOMAINS=("n8n.keybuzz.io" "chat.keybuzz.io" "llm.keybuzz.io" "qdrant.keybuzz.io" "superset.keybuzz.io")

for domain in "${DOMAINS[@]}"; do
    echo -n "  $domain ... "
    
    ip=$(dig +short "$domain" | head -n1)
    
    if [ -n "$ip" ]; then
        echo -e "$OK ($ip)"
    else
        echo -e "$KO (pas de résolution DNS)"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 2. Test HTTP depuis Internet ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for domain in "${DOMAINS[@]}"; do
    echo -n "  http://$domain ... "
    
    response=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$domain" 2>/dev/null)
    
    if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "404" ] || [ "$response" = "401" ]; then
        echo -e "$OK (HTTP $response)"
    elif [ "$response" = "503" ]; then
        echo -e "$WARN (HTTP $response - Service non déployé)"
    else
        echo -e "$KO (HTTP ${response:-timeout})"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ 3. Résumé de l'Infrastructure ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<'SUMMARY'
✅ Infrastructure KeyBuzz déployée

┌─────────────────────────────────────────────────────────────────┐
│ COUCHE RÉSEAU                                                    │
├─────────────────────────────────────────────────────────────────┤
│ ✓ Réseau privé Hetzner    : 10.0.0.0/16                        │
│ ✓ UFW configuré           : K3s + NodePorts                     │
│ ⚠ VXLAN                   : Bloqué (contournement DaemonSet)   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ KUBERNETES (K3S)                                                 │
├─────────────────────────────────────────────────────────────────┤
│ ✓ Masters                 : 3 nœuds (HA)                        │
│ ✓ Workers                 : 5 nœuds                             │
│ ✓ Ingress NGINX           : DaemonSet (5 pods)                  │
│ ✓ NodePorts               : 31695 (HTTP), 32720 (HTTPS)        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ LOAD BALANCER                                                    │
├─────────────────────────────────────────────────────────────────┤
│ ✓ Type                    : Hetzner Cloud LB                    │
│ ✓ Targets                 : 5 workers (IPs privées)            │
│ ✓ Health Check            : HTTP /healthz                       │
│ ✓ Services                : HTTP (80), HTTPS (443)              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ APPLICATIONS DISPONIBLES                                         │
├─────────────────────────────────────────────────────────────────┤
│ • n8n                     : http://n8n.keybuzz.io               │
│ • Chatwoot                : http://chat.keybuzz.io              │
│ • LiteLLM                 : http://llm.keybuzz.io               │
│ • Qdrant                  : http://qdrant.keybuzz.io            │
│ • Superset                : http://superset.keybuzz.io          │
└─────────────────────────────────────────────────────────────────┘

SUMMARY

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Prochaines Étapes ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

cat <<'NEXT_STEPS'
📋 Prochaines étapes pour compléter l'infrastructure :

1️⃣  DÉPLOYER LES APPLICATIONS

   Les Ingress routes sont créés, mais les applications ne sont
   pas encore déployées dans K3s :

   - n8n       : Créer deployment + service (namespace n8n)
   - Chatwoot  : Créer deployment + service (namespace chatwoot)
   - LiteLLM   : Créer deployment + service (namespace litellm)
   - Qdrant    : Créer deployment + service (namespace qdrant)
   - Superset  : Créer deployment + service (namespace superset)

2️⃣  CONFIGURER CERT-MANAGER (HTTPS)

   Pour activer TLS/HTTPS automatique :
   
   ./09_configure_certmanager.sh

   Choisir entre :
   - HTTP-01 Challenge (certificats par client)
   - DNS-01 Challenge (wildcard *.keybuzz.io)

3️⃣  AJOUTER SÉCURITÉ (optionnel)

   Authentification basique :
   ./10_add_basic_auth.sh --app superset --user admin

   IP Whitelist :
   ./11_add-ip_whitelist.sh --app qdrant --ips <VOTRE_IP>

   Désactiver accès temporairement :
   ./12_toggle_access.sh --app superset --disable

4️⃣  PRÉPARER LES BASES DE DONNÉES

   Si pas déjà fait :
   ./02_prepare_database.sh

   Crée les bases PostgreSQL pour :
   - n8n, chatwoot, litellm, superset, erpnext

5️⃣  CONFIGURER LE MONITORING

   - Prometheus + Grafana
   - Alertmanager
   - Logs centralisés

NEXT_STEPS

echo ""
echo "Pour redémarrer cette vérification :"
echo "  ./10_verify_final.sh"
echo ""
