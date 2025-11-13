#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║       Configuration cert-manager pour Let's Encrypt               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")

echo ""
echo "Configuration Let's Encrypt pour cert-manager"
echo ""
echo "Options :"
echo "  1. HTTP-01 Challenge (pour certificats dédiés par client)"
echo "  2. DNS-01 Challenge (pour certificat wildcard *.keybuzz.io)"
echo ""
echo "Recommandation :"
echo "  → HTTP-01 pour commencer (plus simple)"
echo "  → DNS-01 si vous avez beaucoup de clients (wildcard)"
echo ""

read -p "Quelle méthode ? (1=HTTP-01, 2=DNS-01) : " choice

case "$choice" in
    1)
        METHOD="HTTP-01"
        ;;
    2)
        METHOD="DNS-01"
        read -p "Provider DNS (cloudflare/route53/gcloud) : " dns_provider
        read -p "API Token/Key : " dns_token
        ;;
    *)
        echo "Choix invalide"
        exit 1
        ;;
esac

echo ""
echo "Configuration :"
echo "  Méthode    : $METHOD"
echo "  Email      : admin@keybuzz.io"
echo "  Serveur    : Let's Encrypt Production"
echo ""

read -p "Continuer ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Configuration cert-manager ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$METHOD" = "HTTP-01" ]; then
    # ═══════════════════════════════════════════════════════════════════
    # HTTP-01 Challenge (Simple, recommandé)
    # ═══════════════════════════════════════════════════════════════════
    
    echo "→ Création du ClusterIssuer Let's Encrypt (HTTP-01)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'EOF'
cat <<'YAML' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # Serveur Let's Encrypt production
    server: https://acme-v02.api.letsencrypt.org/directory
    
    # Email pour les notifications
    email: admin@keybuzz.io
    
    # Clé privée pour le compte ACME
    privateKeySecretRef:
      name: letsencrypt-prod
    
    # Méthode de validation : HTTP-01 (via Ingress)
    solvers:
    - http01:
        ingress:
          class: nginx
YAML
EOF
    
    echo ""
    echo "→ Création du ClusterIssuer Let's Encrypt STAGING (pour tests)"
    
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'EOF'
cat <<'YAML' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@keybuzz.io
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
YAML
EOF
    
else
    # ═══════════════════════════════════════════════════════════════════
    # DNS-01 Challenge (Pour wildcard)
    # ═══════════════════════════════════════════════════════════════════
    
    echo "→ Création du secret DNS API Token"
    
    case "$dns_provider" in
        cloudflare)
            ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<EOF
kubectl create secret generic cloudflare-api-token \\
  --from-literal=api-token='$dns_token' \\
  -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
EOF
            
            echo ""
            echo "→ Création du ClusterIssuer Let's Encrypt (DNS-01 Cloudflare)"
            
            ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'EOF'
cat <<'YAML' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@keybuzz.io
    privateKeySecretRef:
      name: letsencrypt-dns
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
YAML
EOF
            ;;
            
        route53)
            echo "→ Route53 configuration (TODO)"
            ;;
            
        *)
            echo -e "$WARN Provider DNS non supporté : $dns_provider"
            ;;
    esac
    
    if [ "$dns_provider" = "cloudflare" ]; then
        echo ""
        echo "→ Création du certificat wildcard *.keybuzz.io"
        
        ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'EOF'
cat <<'YAML' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-keybuzz-io
  namespace: default
spec:
  secretName: wildcard-keybuzz-io-tls
  issuerRef:
    name: letsencrypt-dns
    kind: ClusterIssuer
  dnsNames:
  - '*.keybuzz.io'
  - 'keybuzz.io'
YAML
EOF
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "═══ Vérification ═══"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

echo "→ ClusterIssuers :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" kubectl get clusterissuer

if [ "$METHOD" = "DNS-01" ] && [ "$dns_provider" = "cloudflare" ]; then
    echo ""
    echo "→ Certificat wildcard (attente 60s pour génération) :"
    sleep 10
    
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" kubectl get certificate -n default
    
    echo ""
    echo "→ Statut du certificat :"
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" \
        kubectl describe certificate wildcard-keybuzz-io -n default | grep -A 5 "Status:"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK cert-manager configuré"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$METHOD" = "HTTP-01" ]; then
    echo "Pour créer un certificat pour un client :"
    echo ""
    cat <<'EXAMPLE'
# Exemple : Créer un Ingress avec TLS pour client1.keybuzz.io

ssh root@10.0.0.100 bash <<'EOF'
kubectl create namespace client1

cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: client1-app
  namespace: client1
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - client1.keybuzz.io
    secretName: client1-keybuzz-io-tls
  rules:
  - host: client1.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: client1-app
            port:
              number: 80
YAML
EOF
EXAMPLE
else
    echo "Pour utiliser le certificat wildcard :"
    echo ""
    cat <<'EXAMPLE'
# Exemple : Créer un Ingress pour client2.keybuzz.io avec wildcard

ssh root@10.0.0.100 bash <<'EOF'
kubectl create namespace client2

cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: client2-app
  namespace: client2
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - client2.keybuzz.io
    secretName: wildcard-keybuzz-io-tls  ← Utilise le wildcard
  rules:
  - host: client2.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: client2-app
            port:
              number: 80
YAML
EOF
EXAMPLE
fi

echo ""
