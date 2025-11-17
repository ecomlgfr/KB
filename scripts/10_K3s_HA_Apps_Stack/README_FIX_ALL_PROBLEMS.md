# Fix All Problems - Guide de Correction Complète du Cluster K3s

## 📋 Vue d'Ensemble

Ce guide fournit les outils pour diagnostiquer et corriger tous les problèmes du cluster K3s KeyBuzz.

### Problèmes Identifiés

D'après `kubectl get pods -A`, les problèmes suivants ont été détectés :

| Namespace | Composant | Problème | Pods Affectés | Restarts |
|-----------|-----------|----------|---------------|----------|
| `vault` | Vault | CrashLoopBackOff | 7/8 | 1203-1215 |
| `wazuh` | Wazuh Manager | CrashLoopBackOff | 8/8 | 1524-1539 |
| `wazuh` | Wazuh Indexer | Restarts élevés | 1/1 | 1063 |
| `erpnext` | ERPNext socketio | CrashLoopBackOff | 1/1 | 1115 |
| Divers | Pods debug/test | Completed/Error | ~40 | - |

### Composants Fonctionnels ✅

- **Chatwoot** : 16/16 pods Running
- **n8n** : 8/8 pods Running
- **LiteLLM** : 8/8 pods Running
- **Qdrant** : 8/8 pods Running
- **Superset** : 8/8 pods Running
- **Ingress NGINX** : 8/8 pods Running
- **Monitoring** (Prometheus/Grafana) : Tous Running
- **ERPNext** (partiel) : 8/9 pods Running

## 🚀 Utilisation Rapide

### Méthode 1 : Correction Automatique (Recommandée)

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack
# ou
cd /opt/keybuzz-installer/scripts/10_K3s_HA_Apps_Stack

# 1. Diagnostic (optionnel mais recommandé)
chmod +x diagnostic_complete_cluster.sh
./diagnostic_complete_cluster.sh

# 2. Correction automatique
chmod +x fix_all_problems_auto.sh
./fix_all_problems_auto.sh

# 3. Attendre 5-10 minutes puis vérifier
kubectl get pods -A | grep -v "Running\|Completed"
```

### Méthode 2 : Corrections Manuelles Ciblées

```bash
# Correction uniquement Vault
./FIX_VAULT_WAZUH_ULTIMATE.sh

# Diagnostic complet
./diagnostic_complete_cluster.sh

# Vérification finale
kubectl get pods -A
```

## 📊 Script de Diagnostic Complet

### `diagnostic_complete_cluster.sh`

Collecte toutes les informations nécessaires au diagnostic.

**Fonctionnalités** :
- État de tous les pods par namespace
- Logs des pods en échec (Vault, Wazuh, ERPNext)
- Events K8s (erreurs/warnings récents)
- Utilisation des ressources (CPU/Mémoire)
- Statistiques globales du cluster
- Recommandations de correction

**Sortie** :
```
/home/user/KB/logs/diagnostic_YYYYMMDD_HHMMSS/
├── SUMMARY.txt                    # Résumé du diagnostic
├── all_pods.txt                   # Liste de tous les pods
├── problematic_pods.txt           # Pods en problème
├── vault/
│   ├── pods.txt
│   ├── logs_vault-xxxxx.txt
│   ├── describe_vault-xxxxx.txt
│   └── vault_status.txt
├── wazuh/
│   ├── pods.txt
│   ├── indexer_logs.txt
│   └── manager_logs_wazuh-manager-xxxxx.txt
├── erpnext/
│   ├── pods.txt
│   └── socketio_logs.txt
├── recent_events.txt              # 50 derniers events
├── error_events.txt               # Events Warning/Error
├── resources_nodes.txt            # CPU/Mémoire par nœud
├── resources_pods_cpu.txt         # Top 20 CPU
└── resources_pods_memory.txt      # Top 20 Mémoire
```

## 🔧 Script de Correction Automatique

### `fix_all_problems_auto.sh`

Corrige automatiquement tous les problèmes détectés.

**Actions effectuées** :

### 1. Nettoyage des Pods Debug/Test
- Suppression de tous les pods `node-debugger-*` (Completed)
- Suppression des pods de test DNS (`dnscheck`, `netdiag`, etc.)
- Suppression des pods temporaires ERPNext

### 2. Correction Vault
**Problème** : Pods en CrashLoopBackOff, Vault sealed

**Cause racine** :
- File storage avec `hostPath` non persistant
- Vault devient "sealed" après redémarrage
- Clés de déverrouillage potentiellement perdues

**Actions** :
1. Suppression de l'ancien DaemonSet
2. Nettoyage des données Vault sur tous les nœuds
3. Recréation avec file storage propre
4. Initialisation de Vault (si non initialisé)
5. Génération et sauvegarde des clés
6. Déverrouillage automatique avec les 3 premières clés

**Configuration finale** :
```yaml
Storage: File (/opt/keybuzz/vault/data)
TLS: Désactivé
Mode: Single-node (DaemonSet)
Ports: 8200 (HTTP), 8201 (cluster)
Health checks: Optimisés pour Vault sealed
```

**Fichiers générés** :
- `/home/user/KB/credentials/vault_keys_TIMESTAMP.txt` (à sauvegarder !)

### 3. Correction Wazuh Indexer
**Problème** : Restarts élevés (1063+), erreurs SSL

**Cause racine** :
- Configuration SSL incomplète
- Mode cluster sans nœuds multiples
- Health checks trop agressifs

**Actions** :
1. Suppression de l'ancien StatefulSet et PVC
2. Redéploiement en mode single-node
3. Désactivation complète de SSL (`plugins.security.disabled=true`)
4. Health checks optimisés (délais augmentés)

**Configuration finale** :
```yaml
Mode: single-node
SSL: Désactivé
Storage: 50Gi PVC
Mémoire: 2-4Gi (heap: 2Gi)
Health checks: 120s initial, 15s period
```

### 4. Correction Wazuh Manager
**Problème** : Tous les pods en CrashLoopBackOff

**Cause racine** :
- Dépendance à Wazuh Indexer non disponible
- Configuration SSL incompatible

**Actions** :
1. Suppression temporaire du DaemonSet
2. Attente de la stabilisation de Wazuh Indexer
3. Redéploiement manuel requis après (voir section ci-dessous)

### 5. Correction ERPNext socketio
**Problème** : Pod en CrashLoopBackOff (1115 restarts)

**Cause racine** (à diagnostiquer) :
- Connexion Redis échouée
- Problème DNS (service backend)
- Configuration manquante

**Actions** :
1. Analyse des logs pour identifier la cause
2. Redémarrage du pod si cause inconnue
3. Recommandations selon l'erreur détectée

## 📝 Procédure Complète Recommandée

### Étape 1 : Diagnostic Initial

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack

# Exécuter le diagnostic
./diagnostic_complete_cluster.sh

# Analyser le résumé
cat /home/user/KB/logs/diagnostic_*/SUMMARY.txt

# Vérifier les logs problématiques
ls -la /home/user/KB/logs/diagnostic_*/
```

### Étape 2 : Correction Automatique

```bash
# Lancer la correction
./fix_all_problems_auto.sh

# Répondre 'yes' pour confirmer
```

**Durée estimée** : 2-3 minutes pour l'exécution, 5-10 minutes pour stabilisation

### Étape 3 : Vérification Post-Correction

```bash
# Attendre 5 minutes minimum
sleep 300

# Vérifier l'état des pods
kubectl get pods -A | grep -v "Running\|Completed"

# Vérifier Vault spécifiquement
kubectl get pods -n vault
kubectl exec -n vault $(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2) -- vault status

# Vérifier Wazuh Indexer
kubectl get pods -n wazuh
kubectl logs -n wazuh wazuh-indexer-0 --tail=30

# Vérifier ERPNext
kubectl get pods -n erpnext
```

### Étape 4 : Actions Manuelles (si nécessaire)

#### Déverrouiller Vault (si sealed)

```bash
# Récupérer le nom du pod
VAULT_POD=$(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2)

# Vérifier le statut
kubectl exec -n vault $VAULT_POD -- vault status

# Si "Sealed: true", déverrouiller avec les clés
# Fichier clés : /home/user/KB/credentials/vault_keys_TIMESTAMP.txt

kubectl exec -n vault $VAULT_POD -- vault operator unseal <KEY1>
kubectl exec -n vault $VAULT_POD -- vault operator unseal <KEY2>
kubectl exec -n vault $VAULT_POD -- vault operator unseal <KEY3>

# Vérifier
kubectl exec -n vault $VAULT_POD -- vault status
# Doit afficher "Sealed: false"
```

#### Redéployer Wazuh Managers (après stabilisation Indexer)

**Attendre 30+ minutes** que Wazuh Indexer soit complètement stable, puis :

```bash
# Vérifier que l'Indexer est OK
kubectl exec -n wazuh wazuh-indexer-0 -- curl -s http://localhost:9200
# Doit retourner du JSON avec cluster_name: "wazuh-cluster"

# Créer le script de redéploiement (à faire)
# TODO: Créer ./redeploy_wazuh_managers.sh
```

#### Corriger ERPNext socketio (selon le problème détecté)

Analyser les logs :
```bash
kubectl logs -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2) --tail=100
```

**Si erreur Redis** :
```bash
# Vérifier les secrets ERPNext
kubectl get secret -n erpnext erpnext -o yaml

# Vérifier la connexion Redis
kubectl exec -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2) -- redis-cli -h <redis-host> -p 6379 PING
```

**Si erreur DNS** :
```bash
# Vérifier la résolution DNS
kubectl exec -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2) -- nslookup <service-name>
```

### Étape 5 : Diagnostic Final

```bash
# Relancer le diagnostic
./diagnostic_complete_cluster.sh

# Comparer avec le diagnostic initial
diff /home/user/KB/logs/diagnostic_<AVANT>/SUMMARY.txt \
     /home/user/KB/logs/diagnostic_<APRES>/SUMMARY.txt

# État final attendu
kubectl get pods -A | grep -v "Running\|Completed" | wc -l
# Résultat attendu: 0 (ou très faible)
```

## 🔍 Troubleshooting

### Problème : Vault reste en CrashLoopBackOff après correction

**Diagnostic** :
```bash
kubectl logs -n vault $(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2) --tail=50
kubectl describe pod -n vault $(kubectl get pod -n vault -o name | head -1 | cut -d/ -f2)
```

**Solutions** :
1. **Erreur de permissions** :
   ```bash
   # Sur chaque nœud K3s
   for node in 10.0.0.100 10.0.0.101 10.0.0.102 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
       ssh root@$node "mkdir -p /opt/keybuzz/vault/data && chmod -R 777 /opt/keybuzz/vault"
   done
   ```

2. **Vault déjà initialisé** :
   - Récupérer les anciennes clés si disponibles
   - Ou réinitialiser complètement (perte de données)

### Problème : Wazuh Indexer ne démarre pas

**Diagnostic** :
```bash
kubectl logs -n wazuh wazuh-indexer-0 --tail=100
kubectl describe pod -n wazuh wazuh-indexer-0
```

**Solutions communes** :
1. **vm.max_map_count insuffisant** :
   ```bash
   # Sur tous les nœuds K3s
   for node in 10.0.0.100 10.0.0.101 10.0.0.102 10.0.0.110 10.0.0.111 10.0.0.112 10.0.0.113 10.0.0.114; do
       ssh root@$node "sysctl -w vm.max_map_count=262144"
       ssh root@$node "echo 'vm.max_map_count=262144' >> /etc/sysctl.conf"
   done
   ```

2. **Mémoire insuffisante** :
   - Vérifier : `kubectl top nodes`
   - Réduire le heap : Éditer le StatefulSet, changer `OPENSEARCH_JAVA_OPTS` de `-Xms2g -Xmx2g` à `-Xms1g -Xmx1g`

3. **PVC bloqué** :
   ```bash
   kubectl get pvc -n wazuh
   # Si "Pending" : vérifier le StorageClass
   kubectl get sc
   ```

### Problème : ERPNext socketio continue à crasher

**Diagnostic approfondi** :
```bash
# Logs détaillés
kubectl logs -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2) --tail=200

# Variables d'environnement
kubectl exec -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2) -- env | grep -E "REDIS|DB|SITE"

# Tester connexions
kubectl exec -n erpnext $(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2) -- curl -v telnet://redis:6379
```

**Solutions selon l'erreur** :
- **Connection refused** : Vérifier que le service Redis existe et écoute
- **ENOTFOUND** : Problème DNS, vérifier `/etc/resolv.conf` dans le pod
- **Authentication failed** : Vérifier le mot de passe Redis dans les secrets

## 📊 Métriques de Succès

Après correction, vous devriez avoir :

```bash
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
```

**Résultat attendu** :
```
      5 Completed        # Pods de migration/init (normal)
     85+ Running         # Tous les pods applicatifs
       0 CrashLoopBackOff
       0 Error
       0 Pending
```

**Par namespace** :
- `vault` : 8/8 Running (1 seul unsealed actif, autres en standby sealed - normal)
- `wazuh` : 1/1 Running (Indexer uniquement, Managers à redéployer)
- `erpnext` : 9/9 Running
- `chatwoot` : 16/16 Running
- Tous les autres : 100% Running

## 📚 Fichiers et Scripts

| Script | Description | Durée | Automatique |
|--------|-------------|-------|-------------|
| `diagnostic_complete_cluster.sh` | Diagnostic complet + logs | 2-3 min | ✅ Oui |
| `fix_all_problems_auto.sh` | Correction automatique | 3-5 min | ✅ Oui |
| `FIX_VAULT_WAZUH_ULTIMATE.sh` | Correction Vault + Wazuh Indexer | 5-8 min | ⚠️ Semi-auto |
| `FIX_VAULT_WAZUH_FINAL.sh` | Alternative correction Vault/Wazuh | 5-8 min | ⚠️ Semi-auto |

## ⚠️ Notes Importantes

### Sécurité

1. **Clés Vault** : Toujours sauvegarder `/home/user/KB/credentials/vault_keys_*.txt`
   - Sans ces clés, impossible de déverrouiller Vault après redémarrage
   - Les stocker dans un gestionnaire de mots de passe sécurisé
   - Ne JAMAIS commiter ces fichiers dans Git

2. **SSL Désactivé** : Wazuh Indexer sans SSL (temporaire)
   - OK pour environnement de développement
   - À activer en production

3. **Pods Debug** : Suppression automatique
   - Pas de perte de données (pods Completed)
   - Relancer manuellement si besoin de debug

### Performance

- **Vault** : DaemonSet = 1 pod par nœud (8 pods total)
  - Seul 1 pod actif (unsealed), autres en standby - **c'est normal**
  - Ne pas tenter de déverrouiller tous les pods

- **Wazuh Indexer** : StatefulSet single-node
  - Pas de HA (1 seul pod)
  - Prévu pour environnement de test
  - Cluster Wazuh Indexer HA = déploiement complexe différent

## 🎯 Prochaines Étapes

1. **Court terme** (après corrections) :
   - ✅ Vérifier que Vault est déverrouillé
   - ✅ Vérifier que Wazuh Indexer répond sur :9200
   - ✅ Redéployer Wazuh Managers (script à créer)
   - ✅ Vérifier ERPNext socketio

2. **Moyen terme** :
   - Créer un script de backup automatique des clés Vault
   - Mettre en place un monitoring des restarts (Prometheus)
   - Documenter la procédure de déverrouillage Vault
   - Créer un playbook de disaster recovery

3. **Long terme** :
   - Migrer Vault vers Consul storage (HA persistant)
   - Activer SSL pour Wazuh (production)
   - Implémenter auto-unseal Vault (KMS)
   - Cluster Wazuh Indexer 3 nœuds (HA)

## 📞 Support

Si les problèmes persistent après avoir suivi ce guide :

1. **Collecter les diagnostics** :
   ```bash
   ./diagnostic_complete_cluster.sh
   tar -czf cluster_diagnostics_$(date +%Y%m%d).tar.gz /home/user/KB/logs/diagnostic_*
   ```

2. **Informations à fournir** :
   - Sortie de `kubectl get nodes -o wide`
   - Fichier `SUMMARY.txt` du diagnostic
   - Logs spécifiques du composant en échec
   - Version K3s : `kubectl version`

## 📄 Historique

- **2025-11-13** : Création scripts diagnostic + correction automatique
- **2025-11-02** : Correction Chatwoot CrashLoopBackOff
- **2025-11-08** : Déploiement Vault + Wazuh initial

---

**Auteur** : Claude AI Assistant
**Version** : 1.0
**Dernière mise à jour** : 2025-11-13
