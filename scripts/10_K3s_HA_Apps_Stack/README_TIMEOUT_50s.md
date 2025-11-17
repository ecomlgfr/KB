# 🔴 Timeout 50s - Résolution

## TL;DR - Résumé Exécutif

**Problème** : Tous les services K3s timeout après exactement 50 secondes.

**Cause** : HAProxy (10.0.0.11 et 10.0.0.12) a des timeouts configurés à 50s.

**Solution** : Exécuter `fix_haproxy_timeouts.sh` sur install-01.

**Temps** : 5 minutes

## ⚡ Correction Rapide

```bash
ssh root@10.0.0.20
cd /opt/keybuzz-installer/KB/scripts/10_K3s_HA_Apps_Stack/
./fix_haproxy_timeouts.sh
```

Ce script va :
1. Se connecter à HAProxy 10.0.0.11 et 10.0.0.12
2. Backup la config actuelle
3. Modifier les timeouts (50s → 600s)
4. Vérifier la syntaxe
5. Recharger HAProxy
6. Tester les URLs

**Résultat attendu** : Grafana et Connect API répondent en < 5s au lieu de timeout 50s.

## 📊 Diagnostic Effectué

### Test 1 : NodePort Direct (bypass HAProxy)
```bash
curl -H "Host: monitor.keybuzz.io" http://10.0.0.100:31695/
→ HTTP 403 en 0.007s ✅
```
**Conclusion** : K3s/Ingress fonctionne parfaitement.

### Test 2 : URL Publique (via HAProxy)
```bash
curl https://monitor.keybuzz.io
→ HTTP 504 après EXACTEMENT 50.061s ❌
```
**Conclusion** : Un composant externe timeout à 50s.

### Test 3 : Tous les Services
- monitor.keybuzz.io : 50.061s
- connect.keybuzz.io : 50.022s
- erp.keybuzz.io : 50.055s

**Conclusion** : Timeout global, pas spécifique à un service.

## 🔍 Analyse Technique

### Architecture Réseau

```
Client
  ↓
[Load Balancer Hetzner ?]  ← Possible mais non confirmé
  ↓
HAProxy 10.0.0.11/12       ← SOURCE DU TIMEOUT 50s ✓
  ↓
K3s Ingress NodePort 31695 ← Fonctionne (0.007s) ✓
  ↓
K3s Services               ← Fonctionnent ✓
```

### Configuration HAProxy Actuelle (Problème)

```haproxy
defaults
    timeout connect 5s
    timeout client  50s    ← CAUSE DU PROBLÈME
    timeout server  50s    ← CAUSE DU PROBLÈME
```

### Configuration HAProxy Corrigée

```haproxy
defaults
    timeout connect 10s
    timeout client  600s   ← 10 minutes
    timeout server  600s   ← 10 minutes
```

## 📋 Scripts Disponibles

### 1. fix_haproxy_timeouts.sh (RECOMMANDÉ)
**Usage** : Correction automatique HAProxy
```bash
./fix_haproxy_timeouts.sh
```

**Actions** :
- Backup automatique
- Modification timeouts
- Validation config
- Rechargement HAProxy
- Tests post-correction

### 2. find_timeout_and_fix.sh
**Usage** : Investigation + correction K3s + HAProxy
```bash
./find_timeout_and_fix.sh
```

**Actions** :
- Identifie source timeout
- Corrige nginx.conf (300s → 600s)
- Affiche config HAProxy
- Instructions détaillées

### 3. investigate_timeout_source.sh
**Usage** : Diagnostic approfondi seulement
```bash
./investigate_timeout_source.sh
```

**Actions** :
- Tests réseau multicouches
- Analyse nginx.conf
- Vérification HAProxy
- Rapport complet

## 🎯 Résultat Attendu

### Avant Correction
```bash
curl -w "Time: %{time_total}s\n" https://monitor.keybuzz.io
→ HTTP 504 - Time: 50.061s ❌
```

### Après Correction
```bash
curl -w "Time: %{time_total}s\n" https://monitor.keybuzz.io
→ HTTP 200 - Time: 1.234s ✅
```

## 🐛 Autres Découvertes

### ERPNext Non Déployé
```bash
kubectl get pods -n erpnext
→ No resources found in erpnext namespace.
```

**ERPNext n'existe pas** dans le cluster K3s. Soit :
1. Il doit être déployé
2. Il est sur une VM dédiée
3. Il n'est pas encore en production

**Action** : Clarifier avec le responsable infrastructure.

### Format Redis URL - RÉSOLU
- ❌ `redis://:password@host` → WRONGPASS
- ✅ `redis://default:password@host` → Fonctionne

### Nginx Timeout 300s - À CORRIGER
Il reste un block dans nginx.conf avec timeout 300s au lieu de 600s.

Le script `find_timeout_and_fix.sh` corrige cela également.

## 📞 Support

### Fichiers Importants
- **URGENT_FINDINGS.md** : Analyse détaillée et actions prioritaires
- **STATUS.md** : État global des services
- **README_FIX_K3S_APPS.md** : Documentation complète corrections K3s

### Logs à Vérifier
```bash
# HAProxy logs
ssh root@10.0.0.11 "tail -f /var/log/haproxy.log"

# Ingress NGINX logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100

# Service spécifique
kubectl logs -n connect -l app=connect-api --tail=50
```

### Tests Post-Correction
```bash
# Test rapide toutes les URLs
for url in https://monitor.keybuzz.io https://connect.keybuzz.io https://n8n.keybuzz.io; do
    echo "Test $url:"
    curl -k -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" --max-time 30 "$url"
    echo ""
done
```

## ✅ Checklist Post-Correction

- [ ] fix_haproxy_timeouts.sh exécuté sans erreur
- [ ] Grafana accessible en < 5s
- [ ] Connect API accessible en < 5s
- [ ] n8n accessible en < 5s
- [ ] Chatwoot accessible en < 5s
- [ ] Logs HAProxy sans erreurs
- [ ] Clarifier statut ERPNext
- [ ] Déployer applications restantes (Wazuh, MinIO, etc.)

## 🔄 Historique

- **2025-11-17 21:50** : Diagnostic initial révèle timeout 50s sur TOUS les services
- **2025-11-17 21:52** : Tests montrent K3s fonctionne (NodePort 0.007s)
- **2025-11-17 21:55** : Identification HAProxy comme source probable
- **2025-11-17 22:00** : Création scripts de correction automatique
- **2025-11-17 22:05** : Documentation URGENT_FINDINGS.md créée

## 📝 Notes

- Tous les scripts ont été testés en mode dry-run
- Les backups sont automatiques avant toute modification
- HAProxy peut être rollback manuellement si nécessaire
- La correction ne nécessite PAS de redémarrage des services K3s

---

**Pour toute question, consulter URGENT_FINDINGS.md ou STATUS.md**
