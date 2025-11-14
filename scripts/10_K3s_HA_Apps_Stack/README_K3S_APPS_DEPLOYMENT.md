# Déploiement automatique applications K3s KeyBuzz

**Version**: 1.0
**Date**: 2025-11-14

---

## 🎯 Vue d'ensemble

Suite complète de scripts pour déployer automatiquement toutes les applications sur le cluster K3s KeyBuzz (3 masters + 5 workers).

**Point de départ** : Cluster K3s fraîchement installé, vierge d'applications.

**Applications déployées** :
1. Ingress NGINX (DaemonSet + hostNetwork)
2. cert-manager (gestion TLS automatique)
3. n8n (automation)
4. LiteLLM (LLM router)
5. Qdrant (vector database)
6. Chatwoot (customer support)
7. Superset (BI/analytics)
8. ERPNext (ERP via MariaDB Galera)

---

## 📁 Fichiers

```
scripts/10_K3s_HA_Apps_Stack/
├── .env.k3s_apps                            # Configuration centralisée
├── generate_k3s_credentials.sh              # Génération credentials
├── 00_k3s_check_prerequisites.sh            # Vérification prérequis
├── 01_deploy_ingress_nginx_daemonset.sh     # Ingress NGINX DaemonSet
├── 02_deploy_cert_manager.sh                # cert-manager (à créer)
├── 03_deploy_n8n.sh                         # n8n (à créer)
├── 04_deploy_litellm.sh                     # LiteLLM (à créer)
├── 05_deploy_qdrant.sh                      # Qdrant (à créer)
├── 06_deploy_chatwoot.sh                    # Chatwoot (à créer)
├── 07_deploy_superset.sh                    # Superset (à créer)
├── 08_deploy_erpnext.sh                     # ERPNext (à créer)
└── deploy_all_k3s_apps.sh                   # Orchestrateur maître (à créer)
```

---

## 🏗️ Architecture de déploiement

### Principe : DaemonSet + hostNetwork

Toutes les applications utilisent :
- **DaemonSet** : 1 pod par worker (5 workers = 5 pods)
- **hostNetwork: true** : Contourne les problèmes VXLAN Hetzner
- **NodePort** : Ports fixes (HTTP 31695, HTTPS 32720)
- **Load Balancer** : lb-keybuzz-1/2 (49.13.42.76, 138.199.132.240)

### Connexions backend

Toutes les apps se connectent via **lb-haproxy (10.0.0.10)** :

| Service | Host | Port | Description |
|---------|------|------|-------------|
| PostgreSQL Write | 10.0.0.10 | 5432 | Patroni master |
| PostgreSQL Read | 10.0.0.10 | 5433 | Patroni répliques |
| PgBouncer | 10.0.0.10 | 4632 | Connection pooling |
| Redis | 10.0.0.10 | 6379 | Redis Sentinel |
| RabbitMQ | 10.0.0.10 | 5672 | MQ cluster |
| MariaDB | 10.0.0.10 | 6033 | ProxySQL → Galera |

---

## 🚀 Installation

### Étape 1: Configuration

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack/

# Copier le template
cp .env.k3s_apps.example .env.k3s_apps

# Éditer la configuration
nano .env.k3s_apps
```

**À configurer** :
- IPs des nœuds K3s (vérifier)
- Domaines des applications (*.keybuzz.io)
- Token Hetzner DNS (pour cert-manager)
- Laisser les passwords vides (générés auto)

### Étape 2: Générer les credentials

```bash
./generate_k3s_credentials.sh
```

Génère automatiquement tous les passwords, clés de chiffrement, tokens.

### Étape 3: Vérifier les prérequis

```bash
./00_k3s_check_prerequisites.sh
```

Vérifie :
- kubectl fonctionnel
- Cluster K3s 8 nœuds Ready
- Connectivité vers lb-haproxy
- UFW rules NodePorts

### Étape 4: Déploiement automatique

```bash
./deploy_all_k3s_apps.sh
```

**OU** déploiement manuel étape par étape :

```bash
# 1. Ingress NGINX
./01_deploy_ingress_nginx_daemonset.sh

# 2. cert-manager
./02_deploy_cert_manager.sh

# 3-8. Applications
./03_deploy_n8n.sh
./04_deploy_litellm.sh
./05_deploy_qdrant.sh
./06_deploy_chatwoot.sh
./07_deploy_superset.sh
./08_deploy_erpnext.sh
```

---

## ⏱️ Temps d'installation

| Étape | Durée |
|-------|-------|
| Vérification prérequis | 2 min |
| Ingress NGINX | 3 min |
| cert-manager | 2 min |
| n8n | 5 min |
| LiteLLM | 5 min |
| Qdrant | 3 min |
| Chatwoot | 10 min |
| Superset | 10 min |
| ERPNext | 15 min |
| **TOTAL** | **~55 minutes** |

---

## 📊 État après déploiement

```bash
# Vérifier tous les namespaces
kubectl get pods --all-namespaces

# Vérifier Ingress
kubectl get ingress --all-namespaces

# Tester les applications
curl -k https://n8n.keybuzz.io
curl -k https://llm.keybuzz.io
curl -k https://qdrant.keybuzz.io
curl -k https://connect.keybuzz.io
curl -k https://monitor.keybuzz.io
curl -k https://erp.keybuzz.io
```

---

## 🔐 Credentials

Tous les credentials sont sauvegardés dans :

```bash
# Centralisé
/opt/keybuzz-installer/credentials/k3s-apps-credentials.json

# Par application
/opt/keybuzz/<app>/.env
```

**Format JSON** :
```json
{
  "n8n": {
    "url": "https://n8n.keybuzz.io",
    "db_password": "xxx",
    "encryption_key": "xxx"
  },
  "chatwoot": {
    "url": "https://connect.keybuzz.io",
    "db_password": "xxx",
    "secret_key_base": "xxx"
  }
}
```

---

## 📝 Standards KeyBuzz appliqués

✅ Orchestration depuis install-01 via SSH
✅ Configuration centralisée (.env.k3s_apps)
✅ Génération automatique des credentials
✅ Logs dans /opt/keybuzz-installer/logs/
✅ Bind sur IP privée uniquement (10.0.0.0/16)
✅ DaemonSet + hostNetwork (contournement VXLAN)
✅ NodePort fixes (31695/32720)
✅ Connexions via lb-haproxy (10.0.0.10)
✅ TLS via cert-manager + Hetzner DNS
✅ Volumes XFS

---

## 🔍 Troubleshooting

### Pods CrashLoopBackOff

```bash
# Voir les logs
kubectl logs -n <namespace> <pod-name>

# Vérifier la connexion DB
kubectl exec -n <namespace> <pod-name> -- nc -zv 10.0.0.10 5432
```

### Ingress ne répond pas

```bash
# Vérifier les pods Ingress
kubectl get pods -n ingress-nginx

# Vérifier les NodePorts
kubectl get svc -n ingress-nginx

# Tester depuis un worker
ssh root@10.0.0.110 "curl -k https://localhost:32720"
```

### Certificats TLS non émis

```bash
# Vérifier cert-manager
kubectl get pods -n cert-manager

# Vérifier les ClusterIssuer
kubectl get clusterissuer

# Voir les certificats
kubectl get certificate --all-namespaces
```

---

## 📚 Documentation complète

- Installation MariaDB + ProxySQL + ERPNext : `INSTALLATION_AUTOMATIQUE.md`
- Guide rapide K3s : `QUICK_START_K3S_APPS.md` (à créer)
- Architecture complète : `README_MARIADB_PROXYSQL_ERPNEXT.md`

---

## 🆕 Prochaines étapes

**Scripts à créer** :
- [ ] 02_deploy_cert_manager.sh
- [ ] 03_deploy_n8n.sh
- [ ] 04_deploy_litellm.sh
- [ ] 05_deploy_qdrant.sh
- [ ] 06_deploy_chatwoot.sh
- [ ] 07_deploy_superset.sh
- [ ] 08_deploy_erpnext.sh
- [ ] deploy_all_k3s_apps.sh (orchestrateur)

**Fonctionnalités avancées** :
- Backup automatique (MinIO)
- Monitoring (Prometheus + Grafana)
- Alerting (Alertmanager)
- Logs centralisés (Loki)
- Sécurité (Wazuh agents)

---

**Statut** : 🟡 En développement (Ingress NGINX OK, reste à faire)
