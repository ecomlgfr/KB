# Guide de Correction Rapide - Basé sur votre Diagnostic

## 📊 Résumé de votre Diagnostic

D'après `kubectl get pods -A`, voici l'état actuel :

### ✅ Pods Fonctionnels (101 Running)
- **Chatwoot** : 16/16 ✅ (Corrigé avec succès !)
- **n8n** : 8/8 ✅
- **LiteLLM** : 8/8 ✅
- **Qdrant** : 8/8 ✅
- **Superset** : 8/8 ✅
- **Ingress NGINX** : 8/8 ✅
- **Monitoring** : Tous Running ✅
- **ERPNext** (partiel) : 8/9 ✅

### ❌ Problèmes Restants (13 pods)

| Namespace | Composant | Problème | Pods | Action |
|-----------|-----------|----------|------|--------|
| `wazuh` | Indexer | 37 restarts en 3h24m | 1/1 | **CRITIQUE** 🔴 |
| `vault` | Vault | Sealed (verrouillé) | 7/8 | **Normal** (à unsealer si besoin) 🟡 |
| `erpnext` | socketio | CrashLoopBackOff (1154 restarts) | 1/1 | **À analyser** 🟠 |

---

## 🚀 Plan d'Action Recommandé

### Étape 1 : Corriger Wazuh Indexer (10-15 min)

**Problème détecté** :
```
NotSslRecordException: not an SSL/TLS record
```
→ Le serveur attend SSL mais les health checks K8s utilisent HTTP

**Solution** :
```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack
# ou
cd /opt/keybuzz-installer/scripts/10_K3s_HA_Apps_Stack

# Correction Wazuh Indexer + Diagnostic ERPNext
./fix_wazuh_indexer_erpnext_final.sh
```

**Ce que fait le script** :
1. Supprime complètement l'ancien Wazuh Indexer
2. Redéploie avec SSL **COMPLÈTEMENT** désactivé
3. Health checks en mode `exec` avec curl (au lieu de `httpGet`)
4. Analyse automatique de ERPNext socketio

**Attente** : 10-15 minutes pour stabilisation

---

### Étape 2 : Vérifier Wazuh Indexer (2 min)

Après 10-15 minutes, vérifiez :

```bash
# État du pod
kubectl get pod -n wazuh wazuh-indexer-0

# Doit afficher : 1/1 Running (sans restarts récents)

# Logs
kubectl logs -n wazuh wazuh-indexer-0 --tail=50

# Test HTTP
kubectl exec -n wazuh wazuh-indexer-0 -- curl -s http://localhost:9200

# Doit retourner du JSON avec "cluster_name" : "wazuh-cluster"
```

**Si le pod redémarre encore** :
```bash
# Vérifier les logs pour l'erreur spécifique
kubectl describe pod -n wazuh wazuh-indexer-0

# Analyser les events
kubectl get events -n wazuh --sort-by='.lastTimestamp' | tail -20
```

---

### Étape 3 : Redéployer Wazuh Managers (5 min)

**⚠️ IMPORTANT** : Attendez que Wazuh Indexer soit stable (1/1 Running sans restarts pendant 30+ minutes)

```bash
./redeploy_wazuh_managers.sh
```

Le script va :
1. Vérifier que l'Indexer est stable
2. Tester la connectivité HTTP
3. Déployer le DaemonSet Wazuh Manager (8 pods)

---

### Étape 4 : Vault (Optionnel - si vous avez besoin d'unsealer)

**ℹ️ IMPORTANT À COMPRENDRE** :

Vault est déployé en **DaemonSet** (1 pod par nœud = 8 pods total).

**Comportement NORMAL** :
- **1 seul pod** doit être unsealed (actif) → `1/1 Running`
- **Les 7 autres** restent sealed (standby) → `0/1 Running`

**C'est une limitation du file storage**, pas un bug !

**État actuel de votre Vault** :
```
vault-4s8k9   1/1   Running   → Unsealed (actif) ✅
vault-52v9l   0/1   Running   → Sealed (standby) - NORMAL
vault-8x8hp   0/1   Running   → Sealed (standby) - NORMAL
... (5 autres sealed)
```

**Vault est déjà fonctionnel !** Le pod `vault-4s8k9` est actif.

**Si vous voulez quand même unsealer d'autres pods** :
```bash
./fix_vault_unsealed.sh
```

Le script va :
1. Chercher automatiquement les clés de déverrouillage
2. Identifier les pods sealed
3. Les déverrouiller avec les 3 clés (sur 5)

**Fichiers de clés recherchés** :
- `/home/user/KB/credentials/vault_keys_*.txt`
- `/opt/keybuzz-installer/credentials/vault_keys_*.txt`
- `/root/vault_keys*.txt`

---

### Étape 5 : ERPNext socketio (À voir selon diagnostic)

Le script `fix_wazuh_indexer_erpnext_final.sh` a analysé automatiquement ERPNext socketio.

**Vérifier les logs** :
```bash
cat /tmp/erpnext_socketio_analysis.txt
```

**Solutions selon l'erreur** :

#### A. Erreur Redis
```
ECONNREFUSED redis
Connection refused redis
```

**Solution** :
```bash
# Vérifier que Redis est accessible
kubectl exec -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=gunicorn -o name | cut -d/ -f2) -- redis-cli -h <redis-host> -p 6379 PING

# Vérifier les secrets ERPNext
kubectl get secret -n erpnext erpnext -o yaml | grep -i redis
```

#### B. Erreur DNS
```
ENOTFOUND
getaddrinfo
```

**Solution** :
```bash
# Tester la résolution DNS depuis le pod
kubectl exec -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2) -- nslookup <service-name>

# Vérifier les services ERPNext
kubectl get svc -n erpnext
```

#### C. Dépendance manquante
```
Cannot find module
Error: Cannot find
```

**Solution** : Nécessite une reconstruction de l'image Docker (avancé)

#### D. Cause inconnue

**Solution simple** : Redémarrer le pod
```bash
kubectl delete pod -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2)
```

Kubernetes va automatiquement recréer le pod.

---

## 📋 Vérification Finale

Après toutes les corrections, relancez le diagnostic :

```bash
./diagnostic_complete_cluster.sh
```

**Résultat attendu** :

```bash
kubectl get pods -A | grep -v "Running\|Completed" | wc -l
```

**Devrait afficher** : **0** (ou max 7 si Vault sealed en standby)

**Détail** :
- Wazuh Indexer : `1/1 Running` ✅
- Wazuh Managers : `8/8 Running` ✅
- Vault : `1/1 Running` + 7 sealed (normal) ✅
- ERPNext socketio : `1/1 Running` ✅
- Tous les autres : `Running` ✅

---

## 🔧 Commandes de Vérification Rapide

```bash
# Vue d'ensemble des problèmes
kubectl get pods -A | grep -v "Running\|Completed"

# Wazuh complet
kubectl get pods -n wazuh -o wide

# Vault complet
kubectl get pods -n vault -o wide

# ERPNext complet
kubectl get pods -n erpnext -o wide

# Events récents (erreurs)
kubectl get events -A --field-selector type!=Normal --sort-by='.lastTimestamp' | tail -30

# Statistiques globales
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
```

---

## ⏱️ Timeline Recommandée

| Heure | Action | Durée |
|-------|--------|-------|
| H+0 | Lancer `fix_wazuh_indexer_erpnext_final.sh` | 5 min |
| H+5 | **Attendre** stabilisation Wazuh Indexer | 10 min |
| H+15 | Vérifier Wazuh Indexer | 2 min |
| H+17 | Lancer `redeploy_wazuh_managers.sh` | 5 min |
| H+22 | **Attendre** démarrage Managers | 5 min |
| H+27 | Vérification finale avec diagnostic | 2 min |
| H+29 | (Optionnel) `fix_vault_unsealed.sh` si besoin | 3 min |
| H+32 | **FIN** - Tout devrait être OK ✅ | - |

---

## 📞 En Cas de Problème

### Wazuh Indexer continue à redémarrer

**Diagnostic approfondi** :
```bash
# Logs complets
kubectl logs -n wazuh wazuh-indexer-0 --previous
kubectl logs -n wazuh wazuh-indexer-0

# Description détaillée
kubectl describe pod -n wazuh wazuh-indexer-0

# Vérifier vm.max_map_count sur les nœuds
for node in 10.0.0.100 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    echo "Node $node:"
    ssh root@$node "sysctl vm.max_map_count"
done
```

**Si vm.max_map_count < 262144** :
```bash
for node in 10.0.0.100 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
    ssh root@$node "sysctl -w vm.max_map_count=262144"
    ssh root@$node "echo 'vm.max_map_count=262144' >> /etc/sysctl.conf"
done
```

### Wazuh Managers ne démarrent pas

**Vérifier la connexion à l'Indexer** :
```bash
# Depuis un Manager
kubectl exec -n wazuh $(kubectl get pod -n wazuh -l app=wazuh-manager -o name | head -1 | cut -d/ -f2) -- curl -s http://wazuh-indexer:9200
```

**Analyser les logs** :
```bash
kubectl logs -n wazuh $(kubectl get pod -n wazuh -l app=wazuh-manager -o name | head -1 | cut -d/ -f2) --tail=100
```

### Vault ne se déverrouille pas

**Vérifier les clés** :
```bash
# Trouver le fichier de clés
find /home/user/KB -name "vault_keys*.txt" 2>/dev/null
find /opt/keybuzz-installer -name "vault_keys*.txt" 2>/dev/null

# Afficher les clés (ATTENTION : sensible !)
cat <fichier-trouvé>
```

**Déverrouillage manuel** :
```bash
POD=$(kubectl get pod -n vault -l app=vault -o name | head -1 | cut -d/ -f2)

kubectl exec -n vault $POD -- vault operator unseal <KEY1>
kubectl exec -n vault $POD -- vault operator unseal <KEY2>
kubectl exec -n vault $POD -- vault operator unseal <KEY3>

# Vérifier
kubectl exec -n vault $POD -- vault status
```

---

## 📚 Fichiers et Logs Importants

| Fichier/Log | Description | Emplacement |
|-------------|-------------|-------------|
| Diagnostic complet | Tous les logs et états | `/home/user/KB/logs/diagnostic_20251113_162922/` |
| Logs correction | Log du script de correction | `/home/user/KB/logs/fix_all_20251113_162936.log` |
| Analyse ERPNext | Diagnostic ERPNext socketio | `/tmp/erpnext_socketio_analysis.txt` |
| Clés Vault | Clés de déverrouillage Vault | `/home/user/KB/credentials/vault_keys_*.txt` |

---

## ✅ Checklist Finale

- [ ] Wazuh Indexer : 1/1 Running (stable 30+ min)
- [ ] Wazuh Managers : 8/8 Running
- [ ] Vault : 1/8 unsealed (les autres sealed = normal)
- [ ] ERPNext socketio : 1/1 Running
- [ ] Pods debug/test nettoyés
- [ ] Aucun CrashLoopBackOff (sauf peut-être ERPNext si problème complexe)
- [ ] Diagnostic final OK : `./diagnostic_complete_cluster.sh`

---

**Créé** : 2025-11-13
**Basé sur** : Diagnostic du 2025-11-13 16:29:22
**Auteur** : Claude AI Assistant
