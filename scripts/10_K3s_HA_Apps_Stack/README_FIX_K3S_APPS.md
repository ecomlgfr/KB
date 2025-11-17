# Correction Automatique des Applications K3s

## Contexte

Ce document explique comment utiliser le script de correction automatique des applications K3s pour résoudre les problèmes suivants :

- **ERPNext (erp.keybuzz.io)** : Pod socketio en CrashLoopBackOff
- **Grafana (monitor.keybuzz.io)** : 504 Gateway Time-out
- **Connect API (connect.keybuzz.io)** : 504 Gateway Time-out

## Problème Rencontré

Lors de l'exécution initiale du script, l'erreur suivante est apparue :

```
The connection to the server localhost:8080 was refused - did you specify the right host or port?
```

**Cause** : Le script a été exécuté depuis un environnement qui n'a pas accès au cluster K3s (pas de kubeconfig configuré).

## Solution

Le script a été amélioré pour :

1. **Détecter automatiquement le kubeconfig** dans plusieurs emplacements
2. **Récupérer le kubeconfig depuis un master K3s** si nécessaire
3. **Fournir des instructions claires** en cas d'échec

### Emplacements testés (par ordre de priorité)

1. Variable d'environnement `$KUBECONFIG`
2. `/opt/keybuzz-installer/credentials/k3s.yaml`
3. `/etc/rancher/k3s/k3s.yaml` (sur les masters K3s)
4. `$HOME/.kube/config`

### Récupération automatique

Si aucun kubeconfig n'est trouvé, le script tente de se connecter aux masters K3s :
- `10.0.0.100` (k3s-master-01)
- `10.0.0.101` (k3s-master-02)
- `10.0.0.102` (k3s-master-03)

## Utilisation

### Option 1 : Exécution depuis install-01 (RECOMMANDÉ)

Le serveur **install-01** est le serveur d'orchestration qui a accès au cluster K3s.

#### 1a. Avec le script wrapper (automatique)

```bash
# Depuis votre machine locale
cd scripts/10_K3s_HA_Apps_Stack/

# Définir l'IP de install-01 si différente de 10.0.0.1
export INSTALL01_IP="<ip_de_install01>"

# Exécuter le wrapper qui copie et lance le script
./run_fix_from_install01.sh
```

#### 1b. Manuellement via SSH

```bash
# Se connecter à install-01
ssh root@<ip_install01>

# Récupérer le repository
cd /opt/keybuzz-installer/KB
git pull origin claude/fix-chatwoot-installation-011CV5xfi2iwtaRgAvwt5dJd

# Exécuter le script
cd scripts/10_K3s_HA_Apps_Stack/
./fix_k3s_apps_issues.sh
```

### Option 2 : Exécution depuis un master K3s

```bash
# Se connecter à un master K3s
ssh root@10.0.0.100

# Le kubeconfig existe déjà sur les masters
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# Exécuter le script
cd /chemin/vers/KB/scripts/10_K3s_HA_Apps_Stack/
./fix_k3s_apps_issues.sh
```

### Option 3 : Récupération manuelle du kubeconfig

Si vous préférez exécuter depuis une autre machine :

```bash
# Récupérer le kubeconfig depuis un master
scp root@10.0.0.100:/etc/rancher/k3s/k3s.yaml \
    /opt/keybuzz-installer/credentials/k3s.yaml

# Remplacer 127.0.0.1 par l'IP du master
sed -i 's/127.0.0.1/10.0.0.100/g' \
    /opt/keybuzz-installer/credentials/k3s.yaml

# Sécuriser le fichier
chmod 600 /opt/keybuzz-installer/credentials/k3s.yaml

# Configurer la variable d'environnement
export KUBECONFIG="/opt/keybuzz-installer/credentials/k3s.yaml"

# Tester
kubectl get nodes

# Exécuter le script
cd scripts/10_K3s_HA_Apps_Stack/
./fix_k3s_apps_issues.sh
```

## Ce que fait le script

### Phase 1 : Diagnostic Initial
- Vérifie que kubectl fonctionne
- Liste l'état des pods problématiques

### Phase 2 : Nettoyage
- Supprime les pods en état `Completed` (node-debugger, etc.)

### Phase 3 : ERPNext Socketio
- Analyse les logs du pod socketio
- Corrige la configuration Redis : `redis://10.0.0.10:6379/3`
- Configure le port socketio : `9000`
- Redémarre le pod

### Phase 4 : Grafana Timeout
- Patch l'Ingress avec des timeouts augmentés (600s)
- Annotations ajoutées :
  - `nginx.ingress.kubernetes.io/proxy-connect-timeout: "600"`
  - `nginx.ingress.kubernetes.io/proxy-send-timeout: "600"`
  - `nginx.ingress.kubernetes.io/proxy-read-timeout: "600"`

### Phase 5 : Connect API Timeout
- Même correction que Grafana (timeouts 600s)

### Phase 6 : Vérification Ingress
- Liste tous les Ingress configurés

### Phase 7 : Placeholders
- Crée des Ingress placeholders pour les futures apps :
  - `my.keybuzz.io` (portail client)
  - Note : `s3.keybuzz.io` et `etl.keybuzz.io` seront configurés plus tard

### Phase 8 : Tests Finaux
- Attend 30s pour propagation
- Teste tous les endpoints depuis un worker K3s
- Affiche le statut HTTP de chaque service

### Phase 9 : Résumé
- Affiche un résumé complet des corrections
- Liste les services OK vs KO
- Fournit les commandes de vérification

## Résultats Attendus

Après exécution du script, vous devriez voir :

✅ **Services OK (6/10)** :
- n8n.keybuzz.io
- llm.keybuzz.io
- qdrant.keybuzz.io
- chat.keybuzz.io (Chatwoot)
- superset.keybuzz.io
- vault.keybuzz.io

🔧 **Services Corrigés (3/10)** :
- erp.keybuzz.io (ERPNext) - Attendre 5 min pour stabilisation
- monitor.keybuzz.io (Grafana) - Timeout augmenté
- connect.keybuzz.io (Connect API) - Timeout augmenté

⏳ **À Déployer Plus Tard (4)** :
- siem.keybuzz.io (Wazuh)
- my.keybuzz.io (Portail client)
- s3.keybuzz.io (MinIO)
- etl.keybuzz.io (Airbyte)

## Vérifications Post-Exécution

### 1. Vérifier ERPNext Socketio

```bash
# Attendre 5 minutes après l'exécution du script
kubectl get pods -n erpnext -l component=socketio

# Vérifier les logs (ne doit plus crasher)
kubectl logs -n erpnext -l component=socketio --tail=50
```

### 2. Tester les URLs

```bash
# Grafana (ne doit plus timeout)
curl -I https://monitor.keybuzz.io

# Connect API (ne doit plus timeout)
curl -I https://connect.keybuzz.io

# ERPNext (doit répondre HTTP 200 ou 302)
curl -I https://erp.keybuzz.io
```

### 3. Voir l'état global

```bash
kubectl get pods -A | grep -E "(CrashLoop|Error|Pending)"
kubectl get ingress -A
```

## Logs

Le script crée un log détaillé dans :
```
/opt/keybuzz-installer/logs/fix_k3s_apps_YYYYMMDD_HHMMSS.log
```

Pour voir le log en temps réel :
```bash
tail -f /opt/keybuzz-installer/logs/fix_k3s_apps_*.log
```

## Troubleshooting

### Erreur : "kubectl: command not found"
- Le script doit être exécuté sur un serveur avec kubectl installé
- Utilisez install-01 ou un master K3s

### Erreur : "connection refused"
- Le kubeconfig n'est pas configuré ou invalide
- Suivez les instructions de récupération manuelle ci-dessus

### ERPNext socketio continue de crasher
- Vérifier que Redis est accessible : `redis-cli -h 10.0.0.10 -p 6379 PING`
- Vérifier la configuration du site ERPNext :
  ```bash
  kubectl exec -n erpnext deployment/erpnext-gunicorn -- \
      cat sites/erp.keybuzz.io/site_config.json | jq '.redis_socketio'
  ```

### Grafana timeout persiste
- Vérifier que l'Ingress a bien été patché :
  ```bash
  kubectl get ingress -n monitoring kube-prometheus-stack-grafana -o yaml | \
      grep -A 3 annotations
  ```
- Redémarrer le pod Grafana :
  ```bash
  kubectl rollout restart deployment -n monitoring \
      kube-prometheus-stack-grafana
  ```

## Support

Pour plus d'informations :
- Cahier des charges : `/docs/cahier_des_charges_keybuzz.md`
- Scripts K3s : `/scripts/10_K3s_HA_Apps_Stack/`
- Logs : `/opt/keybuzz-installer/logs/`

## Historique des Modifications

- **2025-11-17** : Création initiale du script
- **2025-11-17** : Ajout de l'auto-détection kubeconfig
- **2025-11-17** : Création du script wrapper pour install-01
