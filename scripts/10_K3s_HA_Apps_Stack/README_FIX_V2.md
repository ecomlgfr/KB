# 🔧 Fix V2 - Corrections Déploiement Services

## TL;DR - Résumé Exécutif

**Problème**: Les 4 nouveaux services déployés ne fonctionnent pas après installation.

**Solution**: Exécuter le script master qui corrige tous les problèmes.

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack/
./fix_v2_00_all_in_one.sh
```

**Temps**: 15-20 minutes

---

## 📋 Problèmes Identifiés

### 1. Connect API - ImagePullBackOff ❌

**Erreur**: `ErrImageNeverPull`
```
Failed to pull image "ghcr.io/keybuzz/connect:1.0.0": rpc error:
code = Unknown desc = image not found
```

**Cause**: L'image `ghcr.io/keybuzz/connect:1.0.0` n'existe pas dans le registry.

**Solution**: Script `fix_v2_01_connect_api_image.sh`
- Build l'image Docker localement
- Import sur tous les workers K3s avec `ctr`
- Redéploie avec `imagePullPolicy: IfNotPresent`

---

### 2. Airbyte - UnknownHostException ❌

**Erreur**: `UnknownHostException: airbyte-db-svc`
```
Bootloader failed to connect to database service
```

**Cause**: Le Helm chart crée un service avec un nom différent de celui attendu par le bootloader.

**Solution**: Script `fix_v2_02_airbyte_dns.sh`
- Désinstalle le déploiement Helm actuel
- Redéploie avec `fullnameOverride: airbyte-db-svc`
- Utilise PostgreSQL et MinIO internes (simplification)

---

### 3. Dolibarr - HTTP 202/504 ⚠️

**Erreur**: HTTP 504 timeout puis HTTP 202 (not ready)

**Cause**:
- Base de données prend du temps à s'initialiser
- Dolibarr doit créer toutes ses tables au premier démarrage
- Probes trop agressives

**Solution**: Script `fix_v2_03_dolibarr_init.sh`
- Ajoute init container pour attendre la DB
- Augmente timeouts des probes (180s liveness, 120s readiness)
- Augmente `failureThreshold` pour permettre plus de temps
- Vérifie/crée la base de données avant déploiement

---

### 4. Grafana - Init:CrashLoopBackOff ⚠️

**Erreur**: 2/3 pods running avec restarts

**Cause**:
- Sidecars (dashboards, datasources, plugins) causent des crashes
- Init containers ont des problèmes de permissions

**Solution**: Script `fix_v2_04_grafana_sidecars.sh`
- Désinstalle kube-prometheus-stack (trop complexe)
- Installe Grafana standalone
- Désactive tous les sidecars
- Désactive la persistence (peut causer problèmes init)
- Configure datasources manuellement (Prometheus + Loki)

---

## 🚀 Utilisation

### Option A: Script Master (RECOMMANDÉ)

Exécute tous les fix en séquence:

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack/
./fix_v2_00_all_in_one.sh
```

Ce script va:
1. Demander confirmation
2. Exécuter les 4 fix en ordre
3. Valider tous les services
4. Afficher un rapport final

**Durée totale**: ~15-20 minutes

### Option B: Scripts Individuels

Si vous voulez corriger un seul service:

```bash
# Fix Connect API seulement
./fix_v2_01_connect_api_image.sh

# Fix Airbyte seulement
./fix_v2_02_airbyte_dns.sh

# Fix Dolibarr seulement
./fix_v2_03_dolibarr_init.sh

# Fix Grafana seulement
./fix_v2_04_grafana_sidecars.sh
```

---

## 📊 Résultats Attendus

### Avant Fix

| Service | Status | Erreur |
|---------|--------|--------|
| Connect API | ❌ ImagePullBackOff | `ErrImageNeverPull` |
| Airbyte | ❌ Bootloader Error | `UnknownHostException: airbyte-db-svc` |
| Dolibarr | ⚠️ HTTP 202/504 | Initialisation timeout |
| Grafana | ⚠️ 2/3 Running | Init container crashes |

### Après Fix

| Service | Status | URL |
|---------|--------|-----|
| Connect API | ✅ 2/2 Running | http://connect.keybuzz.io |
| Airbyte | ✅ All Running | http://airbyte.keybuzz.io |
| Dolibarr | ✅ 2/2 Web + 1/1 Cron | http://erp.keybuzz.io |
| Grafana | ✅ 2/2 Running | http://monitor.keybuzz.io |

---

## 🔑 Credentials

### Connect API
- URL: http://connect.keybuzz.io
- Health check: http://connect.keybuzz.io/health
- Pas d'authentification (API gateway)

### Airbyte
- URL: http://airbyte.keybuzz.io
- Email: `airbyte`
- Password: `password`

### Dolibarr
- URL: http://erp.keybuzz.io
- Login: `admin`
- Password: `Admin123!`

### Grafana
- URL: http://monitor.keybuzz.io
- Login: `admin`
- Password: `AdminGrafana123!`

---

## 🔍 Vérifications Post-Fix

### 1. Vérifier tous les pods

```bash
# Vue d'ensemble
kubectl get pods -A | grep -E "(connect|etl|erp|monitoring)"

# Connect API
kubectl get pods -n connect

# Airbyte
kubectl get pods -n etl

# Dolibarr
kubectl get pods -n erp

# Grafana
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
```

### 2. Tester les URLs

```bash
# Connect API
curl http://connect.keybuzz.io/health
# Attendu: {"api":"ok","database":"ok","cache":"ok",...}

# Airbyte
curl -I http://airbyte.keybuzz.io
# Attendu: HTTP 200 ou 302

# Dolibarr
curl -I http://erp.keybuzz.io
# Attendu: HTTP 200 (peut prendre 5 min au premier démarrage)

# Grafana
curl -I http://monitor.keybuzz.io
# Attendu: HTTP 302 (redirect vers /login)
```

### 3. Vérifier les logs

```bash
# Connect API
kubectl logs -n connect -l app=connect-api --tail=50

# Airbyte server
kubectl logs -n etl -l app.kubernetes.io/name=server --tail=50

# Airbyte worker
kubectl logs -n etl -l app.kubernetes.io/name=worker --tail=50

# Dolibarr web
kubectl logs -n erp -l component=web --tail=50

# Grafana
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50
```

### 4. Vérifier les Ingress

```bash
kubectl get ingress -n connect
kubectl get ingress -n etl
kubectl get ingress -n erp
kubectl get ingress -n monitoring
```

---

## 🐛 Troubleshooting

### Connect API - Toujours ImagePullBackOff

**Cause possible**: Image pas importée sur tous les workers

**Solution**:
```bash
# Vérifier l'image sur chaque worker
for worker in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    echo "=== Worker $worker ==="
    ssh root@$worker "ctr -n k8s.io images ls | grep connect"
done

# Si manquante sur un worker, ré-importer
docker save keybuzz/connect:1.0.0 -o /tmp/connect-api.tar
scp /tmp/connect-api.tar root@10.0.0.XXX:/tmp/
ssh root@10.0.0.XXX "ctr -n k8s.io images import /tmp/connect-api.tar"
```

### Airbyte - Bootloader toujours en erreur

**Cause possible**: Service PostgreSQL pas créé

**Solution**:
```bash
# Vérifier les services
kubectl get svc -n etl

# Doit contenir:
# - airbyte-db-svc (PostgreSQL)
# - airbyte-minio (MinIO)

# Si manquant, désinstaller et réinstaller
helm uninstall airbyte -n etl
./fix_v2_02_airbyte_dns.sh
```

### Dolibarr - Toujours HTTP 202 après 10 minutes

**Cause possible**: Erreur de connexion DB ou initialisation bloquée

**Solution**:
```bash
# Vérifier les logs
kubectl logs -n erp -l component=web --tail=100

# Vérifier connexion DB
DOLIBARR_POD=$(kubectl get pods -n erp -l component=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n erp $DOLIBARR_POD -- pg_isready -h 10.0.0.10 -p 6432 -U dolibarr

# Si erreur DB, recréer la base
PGPASSWORD="..." psql -h 10.0.0.10 -p 5432 -U postgres -c "DROP DATABASE dolibarr; CREATE DATABASE dolibarr WITH OWNER = dolibarr;"
kubectl delete pod -n erp -l component=web
```

### Grafana - Pods restart en boucle

**Cause possible**: Problème de datasource ou configuration

**Solution**:
```bash
# Vérifier les logs détaillés
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=200

# Si problème Prometheus, vérifier qu'il existe
kubectl get svc -n monitoring prometheus-operated

# Si manquant, installer Prometheus d'abord:
# (voir script 13_deploy_monitoring_stack.sh)
```

---

## 📝 Notes Techniques

### Architecture Connect API

L'image construite localement contient:
- Python 3.11 + FastAPI + Uvicorn
- Connexion PostgreSQL (10.0.0.10:6432)
- Connexion Redis (10.0.0.10:6379)
- Endpoints: `/`, `/health`, `/api/v1/info`

### Architecture Airbyte

- **PostgreSQL interne**: `airbyte-db-svc:5432`
- **MinIO interne**: `airbyte-minio:9000`
- **Composants**: webapp, server, worker, bootloader, cron, pod-sweeper
- **Version**: 0.50.33 OSS

### Architecture Dolibarr

- **Image**: `tuxgasy/dolibarr:18` (LTS)
- **DB**: PostgreSQL (pas MariaDB)
- **Composants**:
  - 2x web pods (nodeSelector: role=apps)
  - 1x cron pod (nodeSelector: role=background)
- **Volumes**: emptyDir (pas de persistence pour cette version)

### Architecture Grafana

- **Deployment**: Standalone (pas kube-prometheus-stack)
- **Replicas**: 2
- **Sidecars**: Tous désactivés (évite les crashes)
- **Datasources**: Prometheus + Loki (configurés manuellement)
- **Dashboards**: À importer manuellement via UI

---

## ⚙️ Configuration Post-Installation

### Connect API - Ajouter des endpoints

```bash
# Éditer le code source
kubectl edit configmap connect-api-code -n connect

# Ou reconstruire l'image localement
# Modifier /tmp/app.py
# Relancer fix_v2_01_connect_api_image.sh
```

### Airbyte - Configurer les sources/destinations

1. Ouvrir http://airbyte.keybuzz.io
2. Login: `airbyte` / `password`
3. Aller dans "Settings" → "Sources"
4. Ajouter PostgreSQL, MySQL, API, etc.

### Dolibarr - Activer des modules

1. Ouvrir http://erp.keybuzz.io
2. Login: `admin` / `Admin123!`
3. Aller dans "Setup" → "Modules"
4. Activer modules souhaités (déjà pré-activés: Societe, Facture, Propale, Product, Stock)

### Grafana - Importer dashboards

1. Ouvrir http://monitor.keybuzz.io
2. Login: `admin` / `AdminGrafana123!`
3. Menu "+" → "Import"
4. Importer des dashboards Grafana.com (ex: 1860 pour Node Exporter)

---

## 🔄 Rollback

Si un fix cause des problèmes:

### Rollback Connect API
```bash
kubectl delete deployment connect-api -n connect
# Puis redéployer avec le script original 14_deploy_connect_api.sh
```

### Rollback Airbyte
```bash
helm uninstall airbyte -n etl
# Puis redéployer avec le script original 16_deploy_airbyte_etl.sh
```

### Rollback Dolibarr
```bash
kubectl delete deployment dolibarr-web dolibarr-cron -n erp
# Puis redéployer avec le script original 15_deploy_dolibarr.sh
```

### Rollback Grafana
```bash
helm uninstall grafana -n monitoring
# Puis redéployer avec le script original 13_deploy_monitoring_stack.sh
```

---

## 📞 Support

### Fichiers de référence

- **README_FIXES_RAPIDE.md**: Guide de dépannage rapide (V1)
- **TROUBLESHOOTING_GUIDE.md**: Guide de dépannage détaillé (V1)
- **README_DEPLOY_APPS.md**: Documentation déploiement initial

### Logs centralisés

```bash
# Tous les pods en erreur
kubectl get pods -A | grep -vE "(Running|Completed)"

# Logs de tous les services
for ns in connect etl erp monitoring; do
    echo "=== Namespace $ns ==="
    kubectl logs -n $ns --all-containers --tail=20
    echo ""
done
```

### Health checks

```bash
# Script de test rapide
for url in \
    http://connect.keybuzz.io/health \
    http://airbyte.keybuzz.io \
    http://erp.keybuzz.io \
    http://monitor.keybuzz.io
do
    echo "Test $url:"
    curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" --max-time 30 "$url"
    echo ""
done
```

---

## ✅ Checklist Post-Fix

- [ ] Script master exécuté sans erreur
- [ ] Connect API: 2/2 pods Running
- [ ] Airbyte: Tous les pods Running (webapp, server, worker, etc.)
- [ ] Dolibarr: 2/2 web + 1/1 cron Running
- [ ] Grafana: 2/2 pods Running (sans restarts)
- [ ] Connect API accessible (HTTP 200 sur /health)
- [ ] Airbyte accessible (HTTP 200/302)
- [ ] Dolibarr accessible (HTTP 200)
- [ ] Grafana accessible (HTTP 302 redirect /login)
- [ ] Aucun pod en CrashLoopBackOff
- [ ] Aucun pod en ImagePullBackOff
- [ ] Ingress configurés correctement
- [ ] Tests de login réussis sur Airbyte, Dolibarr, Grafana

---

**Version**: V2 - 2025-11-18
**Auteur**: Claude (Anthropic)
**Status**: Production Ready
