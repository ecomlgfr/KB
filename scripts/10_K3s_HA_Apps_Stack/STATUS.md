# État Actuel - Correction K3s Apps

**Date**: 2025-11-17
**Branche**: `claude/fix-chatwoot-installation-011CV5xfi2iwtaRgAvwt5dJd`

## Résumé

Ce document résume l'état actuel de la correction des applications K3s et les problèmes restants.

## ✅ Problèmes Résolus

### 1. DNS Kubernetes Complètement Cassé
**Problème**: CoreDNS forwardait vers `127.0.0.53` (systemd-resolved local) qui était inaccessible depuis les pods.

**Solution**: Patché CoreDNS pour forward vers DNS publics :
```bash
forward . 8.8.8.8 8.8.4.4 1.1.1.1
```

**Résultat**: ✅ DNS fonctionne maintenant (résolution interne et externe)

### 2. Grafana (monitor.keybuzz.io)
**Problème**: 504 Gateway Time-out

**Solution**:
- Fix DNS (ci-dessus)
- Augmentation timeouts Ingress à 600s
- Redémarrage Grafana

**Résultat**: ✅ HTTP 302 (fonctionne correctement)

### 3. Auto-détection Kubeconfig
**Problème**: Scripts échouaient avec `KUBECONFIG: unbound variable`

**Solution**:
- Ajout de `${KUBECONFIG:-}` au lieu de `${KUBECONFIG}`
- Auto-détection dans plusieurs emplacements
- Récupération automatique depuis masters K3s

**Résultat**: ✅ Scripts fonctionnent sur install-01

### 4. IPs Serveurs
**Problème**: Scripts utilisaient `10.0.0.1` pour install-01

**Solution**: Mise à jour vers `10.0.0.20` (selon servers.tsv)

**Résultat**: ✅ SSH et connexions fonctionnent

## ❌ Problèmes Restants

### 1. ERPNext Socketio (erp.keybuzz.io) - CRITIQUE

**Symptômes**:
- Pod socketio en CrashLoopBackOff (5+ restarts)
- HTTP 500 sur erp.keybuzz.io
- Erreur: `SocketClosedUnexpectedlyError: Socket closed unexpectedly`

**Cause Identifiée**:
Format URL Redis incompatible avec le client Python utilisé par Frappe/ERPNext.

**Tests Effectués**:
```bash
# ✅ Fonctionne
redis-cli -h 10.0.0.10 -a "PASSWORD" PING
→ PONG

# ❌ Échoue
redis-cli -u "redis://:PASSWORD@10.0.0.10:6379/3" PING
→ WRONGPASS invalid username-password pair
```

**Solution Proposée**:
Tester le format avec user `default` explicite :
```bash
redis://default:PASSWORD@10.0.0.10:6379/3
```

**Script**: `fix_final_issues.sh` teste et applique cette solution

**Informations Techniques**:
- Redis: 10.0.0.10:6379 (VIP HAProxy entre 2 serveurs)
- Password: `SfqY41ThPI3UlGZxI1j2qlm0unBR41Ie`
- Databases utilisées:
  - DB 0: redis_cache
  - DB 1: redis_queue
  - DB 3: redis_socketio

### 2. Connect API (connect.keybuzz.io) - MYSTÈRE

**Symptômes**:
- Timeout après 50 secondes au lieu de 600s configurés
- Pod est sain (HTTP 200 sur /health)
- Service et endpoints corrects

**Tests Effectués**:
```bash
# ✅ Pod fonctionne
kubectl exec -n connect <pod> -- curl http://localhost:3000/health
→ HTTP 200

# ❌ Via Ingress timeout
curl https://connect.keybuzz.io
→ 504 Gateway Time-out après ~50s
```

**Configuration Appliquée**:
- ConfigMap Ingress NGINX: timeouts 600s ✅
- Annotations Ingress: timeouts 600s ✅
- Ingress NGINX redémarré ✅

**Anomalie Détectée**:
Dans `nginx.conf`, un block montre encore `proxy_connect_timeout 300s` au lieu de 600s.

**Solution Proposée**:
1. Identifier le block upstream spécifique avec timeout 300s
2. Forcer le patch avec toutes les annotations possibles
3. Redémarrer Ingress NGINX Controller

**Script**: `fix_final_issues.sh` applique un patch complet

## 📊 État Global des Services

| Service | Status | URL | Notes |
|---------|--------|-----|-------|
| **Grafana** | ✅ OK | monitor.keybuzz.io | HTTP 302, fonctionne |
| **n8n** | ✅ OK | n8n.keybuzz.io | Vérifié fonctionnel |
| **LiteLLM** | ✅ OK | llm.keybuzz.io | Vérifié fonctionnel |
| **Qdrant** | ✅ OK | qdrant.keybuzz.io | Vérifié fonctionnel |
| **Chatwoot** | ✅ OK | chat.keybuzz.io | Vérifié fonctionnel |
| **Superset** | ✅ OK | superset.keybuzz.io | Vérifié fonctionnel |
| **Vault** | ✅ OK | vault.keybuzz.io | Vérifié fonctionnel |
| **ERPNext** | ❌ KO | erp.keybuzz.io | HTTP 500, socketio crash |
| **Connect API** | ❌ KO | connect.keybuzz.io | Timeout 50s |
| **Wazuh** | ⏳ À déployer | siem.keybuzz.io | Pas encore installé |
| **Portail** | ⏳ À déployer | my.keybuzz.io | Pas encore installé |
| **MinIO** | ⏳ À déployer | s3.keybuzz.io | Pas encore installé |
| **Airbyte** | ⏳ À déployer | etl.keybuzz.io | Pas encore installé |

**Score**: 7/9 services déployés fonctionnels (78%)

## 🔧 Scripts Disponibles

### Diagnostic
- `diagnose_remaining_issues.sh` - Diagnostic approfondi des 2 problèmes restants
- `diagnose_and_fix_ingress.sh` - Diagnostic Ingress et services

### Correction
- `fix_final_issues.sh` - **Script principal** pour corriger les 2 derniers problèmes
- `fix_upstream_timeouts.sh` - Correction spécifique timeouts upstream
- `fix_k3s_apps_issues.sh` - Script de correction initial (déjà exécuté)

### Wrapper
- `run_fix_from_install01.sh` - Exécute n'importe quel script depuis install-01 via SSH

## 📋 Prochaines Actions Recommandées

### 1. Exécuter le Script de Diagnostic (Optionnel)
```bash
ssh root@10.0.0.20
cd /opt/keybuzz-installer/KB/scripts/10_K3s_HA_Apps_Stack/
./diagnose_remaining_issues.sh | tee /tmp/diagnostic_$(date +%Y%m%d_%H%M%S).log
```

Cela permettra de :
- Tester les 3 formats Redis URL (avec/sans user, différentes syntaxes)
- Identifier exactement quel block nginx a le timeout 300s
- Mesurer la latence réseau entre Ingress et pods backend

### 2. Appliquer les Corrections Finales
```bash
ssh root@10.0.0.20
cd /opt/keybuzz-installer/KB/scripts/10_K3s_HA_Apps_Stack/
./fix_final_issues.sh | tee /tmp/fix_final_$(date +%Y%m%d_%H%M%S).log
```

Ce script va :
- Tester et appliquer le format Redis URL correct
- Forcer tous les timeouts Ingress à 600s
- Redémarrer tous les composants concernés
- Vérifier la configuration finale

### 3. Vérification Post-Fix

Après exécution de `fix_final_issues.sh`, attendre 2-3 minutes puis :

```bash
# Test ERPNext
curl -I https://erp.keybuzz.io
# Attendu: HTTP 200 ou 302 (pas 500)

# Test Connect API
curl -I https://connect.keybuzz.io
# Attendu: HTTP 200 ou 302 en moins de 60s

# Vérifier socketio
kubectl logs -n erpnext -l component=socketio --tail=50
# Attendu: Pas d'erreurs Redis, pas de crash
```

### 4. Si Problèmes Persistent

#### Pour ERPNext Socketio:
```bash
# Vérifier la config appliquée
kubectl exec -n erpnext deployment/erpnext-gunicorn -- \
    cat sites/erp.keybuzz.io/site_config.json | jq '.redis_socketio'

# Tester Redis manuellement
redis-cli -h 10.0.0.10 -a "SfqY41ThPI3UlGZxI1j2qlm0unBR41Ie" -n 3 PING

# Vérifier HAProxy (VIP 10.0.0.10)
curl -I http://10.0.0.11:6379  # HAProxy 1
curl -I http://10.0.0.12:6379  # HAProxy 2
```

#### Pour Connect API Timeout:
```bash
# Vérifier nginx.conf final
INGRESS_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ingress-nginx "$INGRESS_POD" -- \
    cat /etc/nginx/nginx.conf | grep -E "proxy_(connect|send|read)_timeout"

# Vérifier les annotations Ingress
kubectl get ingress connect-ingress -n connect -o yaml | grep -A 20 "annotations:"

# Test depuis un pod de test
kubectl run test-connect --image=curlimages/curl:latest --rm -i --restart=Never -- \
    curl -s -o /dev/null -w "HTTP %{http_code} - Time: %{time_total}s\n" \
    --max-time 120 "http://$(kubectl get svc -n connect connect-api -o jsonpath='{.spec.clusterIP}'):3000/health"
```

## 📚 Documentation Technique

### Architecture Redis HA
- **VIP**: 10.0.0.10 (HAProxy)
- **HAProxy 1**: 10.0.0.11
- **HAProxy 2**: 10.0.0.12
- **Redis Nodes**: 10.0.0.123, 10.0.0.124, 10.0.0.125
- **Mode**: Sentinel avec quorum 2

### Ingress NGINX
- **Mode**: DaemonSet avec hostNetwork
- **HTTP NodePort**: 31695
- **Timeouts configurés**: 600s (tous types)
- **Buffer size**: 16k
- **Max body size**: 50m

### ERPNext
- **Namespace**: erpnext
- **Components**: gunicorn (web), scheduler, worker, socketio
- **Database**: MariaDB (maria-01: 10.0.0.30)
- **Cache**: Redis DB 0, DB 1, DB 3
- **Port socketio**: 9000

### Connect API
- **Namespace**: connect
- **Replicas**: 3
- **Port**: 3000
- **Health endpoint**: /health
- **Service Type**: ClusterIP

## 🐛 Bugs Connus et Workarounds

### Bug 1: redis-cli URL format avec mot de passe
**Symptôme**: `redis://:password@host` retourne WRONGPASS
**Workaround**: Utiliser `-h host -a password` ou `redis://default:password@host`

### Bug 2: Timeouts Ingress ne s'appliquent pas immédiatement
**Symptôme**: nginx.conf garde anciennes valeurs malgré ConfigMap patché
**Workaround**: Redémarrer le DaemonSet Ingress NGINX (`rollout restart`)

### Bug 3: Pods Completed qui s'accumulent
**Symptôme**: node-debugger pods en status Completed ne sont pas nettoyés
**Workaround**: `kubectl delete pods -A --field-selector=status.phase==Succeeded`

## 📞 Support

Pour plus d'informations :
- Documentation principale: `/home/user/KB/scripts/10_K3s_HA_Apps_Stack/README_FIX_K3S_APPS.md`
- Cahier des charges: `/home/user/KB/docs/cahier_des_charges_keybuzz.md`
- Logs sur install-01: `/opt/keybuzz-installer/logs/`

## 🔄 Dernière Mise à Jour

**Date**: 2025-11-17
**Par**: Claude (session de correction continue)
**Branche**: claude/fix-chatwoot-installation-011CV5xfi2iwtaRgAvwt5dJd
