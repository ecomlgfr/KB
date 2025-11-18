# ⚡ Quick Start - Fix V2

## 🎯 Correction Rapide (5 minutes)

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack/
./fix_v2_00_all_in_one.sh
```

**Ce script va automatiquement**:
1. ✅ Corriger Connect API (build image locale)
2. ✅ Corriger Airbyte (fix DNS service names)
3. ✅ Corriger Dolibarr (fix initialisation DB)
4. ✅ Corriger Grafana (désactiver sidecars problématiques)

Durée: **15-20 minutes**

---

## 📋 Problèmes Corrigés

| Service | Erreur Avant | Fix Appliqué |
|---------|--------------|--------------|
| **Connect API** | `ErrImageNeverPull` | Build + import image sur workers |
| **Airbyte** | `UnknownHostException: airbyte-db-svc` | Fix nom service PostgreSQL |
| **Dolibarr** | HTTP 504/202 timeout | Init container + timeouts augmentés |
| **Grafana** | 2/3 pods CrashLoopBackOff | Désactivation sidecars |

---

## 🔍 Validation Rapide

```bash
# Vérifier tous les pods
kubectl get pods -A | grep -E "(connect|etl|erp|monitoring)"

# Tester les URLs
curl http://connect.keybuzz.io/health
curl -I http://airbyte.keybuzz.io
curl -I http://erp.keybuzz.io
curl -I http://monitor.keybuzz.io
```

**Résultats attendus**:
- Connect API: HTTP 200 (JSON health status)
- Airbyte: HTTP 200 ou 302
- Dolibarr: HTTP 200 (peut prendre 5 min première fois)
- Grafana: HTTP 302 (redirect login)

---

## 🔑 Accès aux Services

### Connect API Gateway
- **URL**: http://connect.keybuzz.io
- **Health**: http://connect.keybuzz.io/health
- **Info**: http://connect.keybuzz.io/api/v1/info

### Airbyte (ETL)
- **URL**: http://airbyte.keybuzz.io
- **Login**: `airbyte`
- **Password**: `password`

### Dolibarr (ERP/CRM)
- **URL**: http://erp.keybuzz.io
- **Login**: `admin`
- **Password**: `Admin123!`

### Grafana (Monitoring)
- **URL**: http://monitor.keybuzz.io
- **Login**: `admin`
- **Password**: `AdminGrafana123!`

---

## 🐛 Si Erreur Persiste

### Connect API toujours en ImagePullBackOff

```bash
# Vérifier image sur workers
for worker in 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    ssh root@$worker "ctr -n k8s.io images ls | grep connect"
done

# Ré-exécuter le fix
./fix_v2_01_connect_api_image.sh
```

### Airbyte bootloader en erreur

```bash
# Vérifier les services DNS
kubectl get svc -n etl

# Doit voir: airbyte-db-svc
# Si absent, ré-exécuter:
./fix_v2_02_airbyte_dns.sh
```

### Dolibarr toujours HTTP 202 après 10 minutes

```bash
# Vérifier les logs
kubectl logs -n erp -l component=web --tail=100

# Si erreur DB, supprimer et relancer:
kubectl delete deployment dolibarr-web -n erp
./fix_v2_03_dolibarr_init.sh
```

### Grafana pods restart en boucle

```bash
# Vérifier les logs
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=100

# Relancer le fix:
./fix_v2_04_grafana_sidecars.sh
```

---

## 📚 Documentation Complète

Pour plus de détails, consulter:
- **README_FIX_V2.md** - Documentation complète des fix V2
- **TROUBLESHOOTING_GUIDE.md** - Guide de dépannage détaillé
- **README_DEPLOY_APPS.md** - Documentation déploiement initial

---

## 📞 Support Rapide

```bash
# Voir tous les pods en erreur
kubectl get pods -A | grep -vE "(Running|Completed)"

# Logs de tous les nouveaux services
kubectl logs -n connect -l app=connect-api --tail=50
kubectl logs -n etl -l app.kubernetes.io/name=server --tail=50
kubectl logs -n erp -l component=web --tail=50
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana --tail=50
```

---

**Version**: V2 - 2025-11-18
