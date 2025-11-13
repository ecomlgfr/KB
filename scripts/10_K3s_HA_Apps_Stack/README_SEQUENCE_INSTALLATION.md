# 📋 Séquence d'installation K3S Apps - KeyBuzz

## 🎯 Vue d'ensemble

Cette séquence d'installation permet de déployer les applications K3S sur votre cluster après avoir installé la data-plane (PostgreSQL, Redis, RabbitMQ).

## ✅ Prérequis

Avant de commencer, assurez-vous d'avoir complété :

1. ✅ Installation data-plane (PostgreSQL 16 + Patroni, Redis Sentinel, RabbitMQ)
2. ✅ Installation K3s masters (3 nœuds)
3. ✅ Installation K3s workers (5 nœuds)  
4. ✅ Installation K3s addons (Metrics Server, Ingress NGINX, Cert-Manager)

## 📦 Scripts de la séquence

### 0️⃣ Nettoyage (si réinstallation)

Si vous devez tout réinstaller :

```bash
./k3s_cleanup.sh
```

⚠️ **Attention** : Supprime TOUT K3s (masters + workers)

---

### 1️⃣ Installation K3s HA (première installation)

#### A. Installation des 3 masters

```bash
./k3s_ha_install.sh
```

**Ce qu'il fait** :
- ✅ Installe K3s sur master-01 avec `--cluster-init`
- ✅ Joint master-02 et master-03 au cluster
- ✅ Configure le bind sur IP privée Hetzner
- ✅ Ajoute les règles UFW sans reset
- ✅ Sauvegarde le kubeconfig et le token

**Durée** : ~5-8 minutes

**Résultat attendu** :
```
✅ 3 nœuds masters Ready
✅ API accessible
✅ etcd intégré opérationnel
```

---

#### B. Jonction des 5 workers

```bash
./k3s_workers_join.sh
```

**Ce qu'il fait** :
- ✅ Détecte et monte les volumes Hetzner sur `/var/lib/containerd`
- ✅ Configure UFW pour Kubelet et Flannel
- ✅ Installe K3s en mode agent sur chaque worker
- ✅ Vérifie que les 8 nœuds sont Ready

**Durée** : ~5-10 minutes

**Résultat attendu** :
```
✅ 8 nœuds Ready (3 masters + 5 workers)
✅ Volumes montés sur /var/lib/containerd
✅ Réseau Flannel VXLAN opérationnel
```

---

#### C. Installation des addons K3s

```bash
./k3s_bootstrap_addons.sh
```

**Ce qu'il fait** :
- ✅ Installe Metrics Server (pour `kubectl top`)
- ✅ Installe Ingress NGINX Controller (NodePort)
- ✅ Installe Cert-Manager (optionnel)
- ✅ Déploie un namespace de test

**Durée** : ~4-6 minutes

**Résultat attendu** :
```
✅ Metrics Server opérationnel
✅ Ingress NGINX en NodePort
✅ Test HTTP 200 sur pod nginx
```

---

### 2️⃣ Vérification des prérequis

```bash
./00_check_prerequisites.sh
```

**Ce qu'il vérifie** :
- ✅ Cluster K3s accessible (8 nœuds Ready)
- ✅ Data-plane accessible (PostgreSQL, Redis, RabbitMQ)
- ✅ UFW correctement configuré (10.42, 10.43)

**Si des éléments sont KO, corrigez-les avant de continuer.**

---

### 3️⃣ Correction UFW (CRITIQUE)

```bash
./01_fix_ufw_k3s_networks.sh
```

**Ce qu'il fait** :
- ✅ Autorise 10.42.0.0/16 (pods K3s)
- ✅ Autorise 10.43.0.0/16 (services K8s)
- ✅ Sur les 8 nœuds (3 masters + 5 workers)

**Durée** : 2 minutes

⚠️ **OBLIGATOIRE** : Sans cela, les pods ne peuvent pas communiquer !

---

### 4️⃣ Préparation de la base de données

```bash
./02_prepare_database.sh
```

**Ce qu'il fait** :
- ✅ Crée les bases de données (n8n, chatwoot, litellm, superset, erpnext)
- ✅ Crée les utilisateurs PostgreSQL
- ✅ Crée les extensions (pgvector, pg_stat_statements, pgcrypto, pg_trgm)
- ✅ Donne les permissions

**Durée** : 1-2 minutes

**Bases créées** :
- `n8n` → Workflow automation
- `chatwoot` → Customer support  
- `litellm` → LLM Router
- `superset` → Business Intelligence
- `erpnext` → ERP/CRM (optionnel)

**Extensions créées** :
- `vector` (pgvector) → Pour Chatwoot AI
- `pg_stat_statements` → Pour monitoring
- `pgcrypto` → Pour chiffrement
- `pg_trgm` → Pour recherche texte

---

### 5️⃣ Préparation des environnements apps

```bash
./03_prepare_apps_env.sh
```

**Ce qu'il fait** :
- ✅ Charge les credentials data-plane (PostgreSQL, Redis, RabbitMQ, MinIO)
- ✅ Teste la connectivité depuis k3s-worker-01
- ✅ Génère 5 fichiers .env pour les applications
- ✅ Crée les secrets Kubernetes dans chaque namespace

**Durée** : 1-2 minutes

**Fichiers générés** :
- `n8n.env` → Configuration n8n
- `chatwoot.env` → Configuration Chatwoot (avec REDIS_URL correct)
- `litellm.env` → Configuration LiteLLM
- `qdrant.env` → Configuration Qdrant
- `superset.env` → Configuration Superset (avec SECRET_KEY)

**Secrets K8s créés** :
- `n8n-config` (namespace n8n)
- `chatwoot-config` (namespace chatwoot)
- `litellm-config` (namespace litellm)
- `qdrant-config` (namespace qdrant)
- `superset-config` (namespace superset)

---

### 6️⃣ Déploiement des applications

```bash
./04_apps_helm_deploy.sh
```

OU (fichier uploadé) :

```bash
./apps_helm_deploy.sh
```

**Ce qu'il fait** :
- ✅ Déploie n8n (2 replicas + PVC 10GB)
- ✅ Déploie Chatwoot (2 web + 2 workers + PVC 5GB)
- ✅ Déploie LiteLLM (2 replicas)
- ✅ Déploie Qdrant (StatefulSet + PVC 20GB)
- ✅ Déploie Superset (2 replicas)

**Durée** : 10-15 minutes

**Résultat attendu** :
```
n8n         : 2 pods Running
chatwoot    : 4 pods Running (2 web + 2 workers)
litellm     : 2 pods Running
qdrant      : 1 pod Running
superset    : 2 pods Running
```

---

### 7️⃣ Tests d'acceptation

```bash
./05_apps_final_tests.sh
```

OU (fichier uploadé) :

```bash
./apps_final_tests.sh
```

**Ce qu'il vérifie** :
- ✅ État du cluster K3s (8 nœuds)
- ✅ État des pods applicatifs
- ✅ Connectivité HTTP via Ingress (NodePort)
- ✅ PVC (Persistent Volume Claims)

**Durée** : 2-3 minutes

---

## 🎯 Séquence complète (résumé)

```bash
# 0. Vérifier les prérequis
./00_check_prerequisites.sh

# 1. Corriger UFW (CRITIQUE)
./01_fix_ufw_k3s_networks.sh

# 2. Préparer PostgreSQL
./02_prepare_database.sh

# 3. Préparer les environnements
./03_prepare_apps_env.sh

# 4. Déployer les applications
./apps_helm_deploy.sh

# 5. Attendre 2-3 minutes que les pods démarrent
sleep 180

# 6. Lancer les tests
./apps_final_tests.sh
```

**Durée totale** : ~20-30 minutes

---

## 🔧 Scripts de fix (si problèmes)

### Si pods en CrashLoopBackOff

```bash
# Vérifier les logs
ssh root@10.0.0.100 kubectl get pods -A | grep -v Running

# Voir les logs d'un pod
ssh root@10.0.0.100 kubectl logs -n <namespace> <pod-name>
```

### Si secret manquant

```bash
# Recréer un secret spécifique
ssh root@10.0.0.100 bash <<'EOF'
kubectl create secret generic <secret-name> \
  --from-env-file=/opt/keybuzz/apps/<app>.env \
  -n <namespace> --dry-run=client -o yaml | kubectl apply -f -
EOF
```

### Si extension PostgreSQL manquante

```bash
# Se connecter à PostgreSQL
ssh root@10.0.0.120  # ou 10.0.0.10

# Entrer dans le container
docker exec -it <postgres-container> psql -U postgres -d <database>

# Créer l'extension
CREATE EXTENSION IF NOT EXISTS vector;
```

---

## 📊 État final attendu

Après installation complète :

```bash
ssh root@10.0.0.100 kubectl get pods -A
```

**Résultat** :
```
NAMESPACE       NAME                              READY   STATUS    RESTARTS
n8n             n8n-xxx                           1/1     Running   0
n8n             n8n-xxx                           1/1     Running   0
chatwoot        chatwoot-web-xxx                  1/1     Running   0
chatwoot        chatwoot-web-xxx                  1/1     Running   0
chatwoot        chatwoot-worker-xxx               1/1     Running   0
chatwoot        chatwoot-worker-xxx               1/1     Running   0
litellm         litellm-xxx                       1/1     Running   0
litellm         litellm-xxx                       1/1     Running   0
qdrant          qdrant-0                          1/1     Running   0
superset        superset-xxx                      1/1     Running   0
superset        superset-xxx                      1/1     Running   0
```

**Total** : 11 pods Running ✅

---

## 🌐 Accès aux applications

Pour accéder aux applications, configurer :

1. **Load Balancer Hetzner** → Router vers NodePort (récupérable via `kubectl get svc -n ingress-nginx`)
2. **DNS publics** :
   - `n8n.keybuzz.io` → LB Hetzner
   - `chat.keybuzz.io` → LB Hetzner
   - `llm.keybuzz.io` → LB Hetzner
   - `qdrant.keybuzz.io` → LB Hetzner
   - `superset.keybuzz.io` → LB Hetzner

---

## 🆘 Support

En cas de problème :

1. Vérifiez les logs : `tail -n 50 /opt/keybuzz-installer/logs/<script>.log`
2. Vérifiez l'état des pods : `kubectl get pods -A`
3. Vérifiez les secrets : `kubectl get secrets -n <namespace>`
4. Vérifiez UFW : `ufw status | grep -E "10.42|10.43"`

---

## 📚 Documentation

- n8n : https://docs.n8n.io
- Chatwoot : https://www.chatwoot.com/docs
- LiteLLM : https://docs.litellm.ai
- Qdrant : https://qdrant.tech/documentation
- Superset : https://superset.apache.org/docs

---

✅ **Installation terminée !** 🎉
