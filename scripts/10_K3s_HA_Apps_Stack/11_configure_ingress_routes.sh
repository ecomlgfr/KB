#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    K3S - Configuration Ingress Routes                             ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'

echo ""
echo "Création des Ingress pour :"
echo "  - n8n.keybuzz.io"
echo "  - llm.keybuzz.io"
echo "  - qdrant.keybuzz.io"
echo ""

kubectl apply -f - <<'EOF'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: n8n
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
spec:
  ingressClassName: nginx
  rules:
  - host: n8n.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: n8n
            port:
              number: 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm
  namespace: litellm
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: llm.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: litellm
            port:
              number: 4000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qdrant
  namespace: qdrant
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: qdrant.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: qdrant
            port:
              number: 6333
EOF

echo ""
echo -e "$OK Ingress routes créés"
echo ""

echo "Vérification :"
kubectl get ingress -A

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "$OK Configuration terminée"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Prochaine étape :"
echo "  ./12_final_validation.sh"
echo ""
