# ⚡ Quick Start - Fix V3 (CORRIGÉ)

## 🎯 Qu'est-ce que V3 ?

**Version 3 corrige les problèmes rencontrés avec V2:**

| Problème V2 | Solution V3 |
|-------------|-------------|
| Connect API ImagePullBackOff persistant | Tag local `connect-api:local` au lieu de `keybuzz/connect:1.0.0` |
| Dolibarr: Secret manquant | Création automatique du secret avant déploiement |
| Grafana: Error "secret exists" | Utilisation de `kubectl apply` au lieu de `create` |
| Airbyte: Script non trouvé | Script copié dans le bon chemin |

---

## 🚀 Exécution Rapide (5 minutes)

### Sur votre serveur install-01:

```bash
# Copier les scripts V3 dans le dossier de travail
cp /home/user/KB/scripts/10_K3s_HA_Apps_Stack/fix_v3_*.sh .

# Exécuter le script master V3
./fix_v3_00_all_in_one.sh
```

**Durée estimée**: 15-20 minutes

---

## 🔧 Corrections Principales V3

### 1. Connect API - Tag Local

**Problème V2**:
```
ErrImagePull: image "keybuzz/connect:1.0.0" not found
```

**Solution V3**:
- Build avec tag local: `connect-api:local`
- Import avec nom complet: `docker.io/library/connect-api:local`
- Création automatique du secret `connect-secrets`
- Création automatique de la base de données `connect`

**Résultat attendu**:
```bash
kubectl get pods -n connect
NAME                           READY   STATUS    RESTARTS   AGE
connect-api-xxxxx-yyyyy        1/1     Running   0          2m
connect-api-xxxxx-zzzzz        1/1     Running   0          2m
```

---

### 2. Dolibarr - Création Secret

**Problème V2**:
```
Error from server (NotFound): secrets "dolibarr-secrets" not found
```

**Solution V3**:
- Crée le secret `dolibarr-secrets` AVANT le déploiement
- Vérifie/crée la base de données `dolibarr`
- Utilise le même mot de passe PostgreSQL que le cluster

**Résultat attendu**:
```bash
kubectl get pods -n erp
NAME                            READY   STATUS    RESTARTS   AGE
dolibarr-web-xxxxx-yyyyy        1/1     Running   0          3m
dolibarr-web-xxxxx-zzzzz        1/1     Running   0          3m
dolibarr-cron-xxxxx-yyyyy       1/1     Running   0          3m
```

---

### 3. Grafana - Gestion Secret Existant

**Problème V2**:
```
error: failed to create secret secrets "grafana-admin-credentials" already exists
```

**Solution V3**:
- Utilise `kubectl apply` au lieu de `kubectl create`
- Permet de recréer/mettre à jour le secret existant
- Désactive TOUS les sidecars (dashboards, datasources, plugins, notifiers)

**Résultat attendu**:
```bash
kubectl get pods -n monitoring
NAME                       READY   STATUS    RESTARTS   AGE
grafana-xxxxx-yyyyy        1/1     Running   0          2m
grafana-xxxxx-zzzzz        1/1     Running   0          2m
```

---

## 📋 Ordre d'Exécution

Le script master `fix_v3_00_all_in_one.sh` exécute dans cet ordre:

1. **Connect API** (5 min)
   - Création secret
   - Création DB
   - Build image locale
   - Import sur tous workers
   - Déploiement

2. **Airbyte** (5 min)
   - Désinstallation Helm
   - Réinstallation avec `fullnameOverride`
   - PostgreSQL + MinIO internes

3. **Dolibarr** (5 min)
   - Création secret
   - Vérification/création DB
   - Déploiement avec init container
   - Attente initialisation (3 min)

4. **Grafana** (3 min)
   - Gestion secret existant
   - Désinstallation anciens déploiements
   - Installation standalone simplifié

5. **Validation** (2 min)
   - Tests HTTP de tous les services
   - Vérification pods
   - Rapport final

**Total**: ~20 minutes

---

## ✅ Validation Post-Fix

### Tests HTTP Rapides

```bash
# Connect API (attendu: HTTP 200)
curl http://connect.keybuzz.io/health

# Airbyte (attendu: HTTP 200 ou 302)
curl -I http://airbyte.keybuzz.io

# Dolibarr (attendu: HTTP 200)
curl -I http://erp.keybuzz.io

# Grafana (attendu: HTTP 302)
curl -I http://monitor.keybuzz.io
```

### Vérification Pods

```bash
# Tous les nouveaux pods
kubectl get pods -A | grep -E "(connect|etl|erp|monitoring)"

# Détail par namespace
kubectl get pods -n connect
kubectl get pods -n etl
kubectl get pods -n erp
kubectl get pods -n monitoring
```

### Vérification Logs

```bash
# Connect API
kubectl logs -n connect -l app=connect-api --tail=50

# Airbyte (server)
kubectl logs -n etl -l app.kubernetes.io/name=server --tail=50

# Dolibarr
kubectl logs -n erp -l component=web --tail=50

# Grafana
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50
```

---

## 🔑 Accès aux Services

### Connect API Gateway
```
URL:     http://connect.keybuzz.io
Health:  http://connect.keybuzz.io/health
Info:    http://connect.keybuzz.io/api/v1/info
Auth:    Aucune (API publique)
```

### Airbyte (ETL)
```
URL:      http://airbyte.keybuzz.io
Email:    airbyte
Password: password
```

### Dolibarr (ERP/CRM)
```
URL:      http://erp.keybuzz.io
Login:    admin
Password: Admin123!
```

### Grafana (Monitoring)
```
URL:      http://monitor.keybuzz.io
Login:    admin
Password: AdminGrafana123!
```

---

## 🐛 Troubleshooting

### Connect API toujours en ImagePullBackOff

```bash
# Vérifier que l'image est présente sur les workers
for worker in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    echo "=== Worker $worker ==="
    ssh root@$worker "ctr -n k8s.io images ls | grep connect-api"
done

# Vérifier les events du pod
kubectl describe pod -n connect -l app=connect-api | grep -A 10 Events

# Relancer le fix si nécessaire
./fix_v3_01_connect_api_image.sh
```

### Dolibarr HTTP 202 après 10 minutes

```bash
# Vérifier les logs (chercher erreurs SQL)
kubectl logs -n erp -l component=web --tail=100

# Vérifier connexion DB
kubectl exec -n erp $(kubectl get pods -n erp -l component=web -o jsonpath='{.items[0].metadata.name}') -- \
  pg_isready -h 10.0.0.10 -p 6432 -U dolibarr

# Si erreur DB, recréer
kubectl delete deployment dolibarr-web dolibarr-cron -n erp
./fix_v3_03_dolibarr_init.sh
```

### Grafana pods en CrashLoopBackOff

```bash
# Vérifier les logs détaillés
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=200

# Vérifier si Prometheus existe (datasource)
kubectl get svc -n monitoring prometheus-operated

# Relancer avec logs
helm uninstall grafana -n monitoring
./fix_v3_04_grafana_sidecars.sh
```

---

## 📊 Différences V2 vs V3

| Aspect | V2 | V3 |
|--------|----|----|
| **Connect image** | `keybuzz/connect:1.0.0` | `connect-api:local` |
| **Connect secret** | Assume existant | Crée automatiquement |
| **Connect DB** | Assume existante | Crée automatiquement |
| **Dolibarr secret** | Assume existant | Crée automatiquement |
| **Dolibarr DB** | Vérification basique | Vérif + création si manquante |
| **Grafana secret** | `kubectl create` (échoue si existe) | `kubectl apply` (idempotent) |
| **Logs** | Basiques | Détaillés avec diagnostics |
| **Vérifications** | Fin de script | Chaque étape + fin |

---

## 📝 Scripts Individuels V3

Si vous voulez corriger un seul service:

```bash
# Connect API uniquement
./fix_v3_01_connect_api_image.sh

# Airbyte uniquement
./fix_v3_02_airbyte_dns.sh

# Dolibarr uniquement
./fix_v3_03_dolibarr_init.sh

# Grafana uniquement
./fix_v3_04_grafana_sidecars.sh
```

---

## ✅ Checklist Succès

- [ ] Connect API: 2/2 pods Running (pas de ImagePullBackOff)
- [ ] Connect API: HTTP 200 sur /health
- [ ] Secret connect-secrets existe
- [ ] Base de données `connect` existe
- [ ] Airbyte: Tous pods Running (webapp, server, worker, etc.)
- [ ] Airbyte: HTTP 200 ou 302
- [ ] Dolibarr: 3/3 pods Running (2 web + 1 cron)
- [ ] Dolibarr: HTTP 200 (pas 202 après 5 min)
- [ ] Secret dolibarr-secrets existe
- [ ] Base de données `dolibarr` existe
- [ ] Grafana: 2/2 pods Running (0 restarts)
- [ ] Grafana: HTTP 302 (redirect /login)
- [ ] Tous les Ingress configurés
- [ ] Tous les tests de login fonctionnels

---

## 🔄 Rollback si Problème

Si un fix V3 cause des problèmes:

```bash
# Connect API
kubectl delete namespace connect
# Puis redéployer avec script original

# Airbyte
helm uninstall airbyte -n etl
# Puis redéployer avec script original

# Dolibarr
kubectl delete namespace erp
# Puis redéployer avec script original

# Grafana
helm uninstall grafana -n monitoring
# Puis redéployer avec script original
```

---

## 📚 Documentation Complète

- **README_FIX_V2.md**: Documentation détaillée V2 (référence)
- **TROUBLESHOOTING_GUIDE.md**: Guide de dépannage complet
- **README_DEPLOY_APPS.md**: Documentation déploiement initial

---

**Version**: V3 - 2025-11-18
**Status**: Production Ready
**Tested**: Non (à tester sur install-01)
