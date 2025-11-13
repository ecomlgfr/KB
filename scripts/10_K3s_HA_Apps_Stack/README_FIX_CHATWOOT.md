# Fix Chatwoot - Correction du Déploiement

## 🔴 Problèmes Identifiés

D'après les logs du déploiement (`chatwoot_deploy_20251102_102827.log`), Chatwoot présente les symptômes suivants :

### Symptômes
```
chatwoot-web-7999f5bff-7jmdf      0/1     CrashLoopBackOff   4 (21s ago)
chatwoot-web-7999f5bff-s82rj      0/1     CrashLoopBackOff   4 (20s ago)
```

- ✅ Migration DB : **Réussie** (`chatwoot-db-migrate` Completed)
- ✅ Workers : **Fonctionnent** (1/1 Running)
- ❌ Web Pods : **CrashLoopBackOff** (redémarrage continu)

### Causes Probables

1. **Incohérence du Port PostgreSQL**
   - Script principal : Port 6432 (PgBouncer)
   - Autres scripts : Port 5432 (PostgreSQL direct)
   - → Connexions échouent selon le script utilisé

2. **Configuration RabbitMQ Incomplète**
   - RabbitMQ configuré dans certains secrets
   - Mais peut ne pas être disponible ou mal configuré
   - → Chatwoot crash si RabbitMQ est attendu mais indisponible

3. **Variables d'Environnement Manquantes**
   - `FRONTEND_URL` : Nécessaire pour les webhooks et assets
   - `INSTALLATION_ENV` : Requis pour le mode production
   - `REDIS_PASSWORD` : Variable séparée parfois requise
   - → Erreurs au démarrage de Rails

4. **Timeouts des Health Checks**
   - Probes trop agressives (délai initial trop court)
   - Rails met ~60s à démarrer en production
   - → K8s tue les pods avant qu'ils ne soient prêts

## 🔧 Solution Implémentée

Le script `fix_chatwoot_complete.sh` corrige tous ces problèmes :

### Corrections Appliquées

1. **✅ Port PostgreSQL Unifié**
   ```bash
   POSTGRES_PORT="6432"  # PgBouncer pour toute l'architecture
   ```

2. **✅ Variables d'Environnement Complètes**
   ```bash
   FRONTEND_URL="http://chat.keybuzz.io"
   INSTALLATION_ENV="docker"
   REDIS_PASSWORD="${REDIS_PASSWORD}"
   LOG_LEVEL="info"
   RAILS_MAX_THREADS="5"
   ```

3. **✅ Configuration RabbitMQ Retirée**
   - RabbitMQ est optionnel pour Chatwoot
   - Retiré des secrets pour éviter les erreurs de connexion

4. **✅ Health Checks Optimisés**
   ```yaml
   readinessProbe:
     initialDelaySeconds: 60  # Au lieu de 30
     periodSeconds: 15
     timeoutSeconds: 10
     failureThreshold: 5      # Au lieu de 3

   livenessProbe:
     initialDelaySeconds: 90  # Au lieu de 60
     periodSeconds: 30
   ```

5. **✅ Diagnostics Améliorés**
   - Tests de connexion DB avant migration
   - Logs verbeux au démarrage
   - Affichage de la configuration

## 📋 Utilisation

### Prérequis

- Cluster K3s opérationnel
- PostgreSQL accessible via PgBouncer (10.0.0.10:6432)
- Redis accessible via Sentinel (10.0.0.10:6379)
- Base de données `chatwoot` créée
- Credentials dans `/opt/keybuzz-installer/credentials/` ou `/home/user/KB/credentials/`

### Exécution

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack
# ou
cd /opt/keybuzz-installer/scripts/10_K3s_HA_Apps_Stack

# Exécuter le script de correction
bash fix_chatwoot_complete.sh
```

### Étapes du Script

1. **Diagnostic** : Affiche l'état actuel et les logs d'erreur
2. **Nettoyage** : Supprime toutes les ressources Chatwoot existantes
3. **Recréation Secrets** : Crée les secrets avec configuration corrigée
4. **Migration DB** : Exécute `db:chatwoot_prepare` avec tests de connexion
5. **Déploiement Web** : DaemonSet avec hostNetwork (5 pods)
6. **Déploiement Worker** : DaemonSet avec hostNetwork (5 pods)
7. **Services/Ingress** : Configure l'accès via http://chat.keybuzz.io
8. **Vérification** : Affiche l'état final et les logs

## 🔍 Diagnostic Post-Déploiement

### Vérifier l'État des Pods

```bash
# Via le master K3s
ssh root@10.0.0.100 "kubectl get pods -n chatwoot -o wide"

# Résultat attendu :
NAME                           READY   STATUS      RESTARTS   AGE
chatwoot-db-migrate-xxxxx      0/1     Completed   0          5m
chatwoot-web-xxxxx             1/1     Running     0          3m
chatwoot-web-yyyyy             1/1     Running     0          3m
chatwoot-worker-xxxxx          1/1     Running     0          3m
chatwoot-worker-yyyyy          1/1     Running     0          3m
```

### Voir les Logs en Temps Réel

```bash
# Logs Web
ssh root@10.0.0.100 "kubectl logs -n chatwoot -l component=web --tail=100 -f"

# Logs Worker
ssh root@10.0.0.100 "kubectl logs -n chatwoot -l component=worker --tail=100 -f"

# Logs Migration
ssh root@10.0.0.100 "kubectl logs -n chatwoot job/chatwoot-db-migrate"
```

### Tester l'Accès HTTP

```bash
# Test simple
curl -I http://chat.keybuzz.io

# Test complet
curl -v http://chat.keybuzz.io

# Depuis un worker K3s
ssh root@10.0.0.110 "curl -I http://localhost:3000"
```

### Vérifier les Connexions Backend

```bash
# Test PostgreSQL depuis un pod
ssh root@10.0.0.100 "kubectl exec -n chatwoot -it \$(kubectl get pod -n chatwoot -l component=web -o name | head -1) -- \
  sh -c 'PGPASSWORD=\$POSTGRES_PASSWORD psql -h \$POSTGRES_HOST -p \$POSTGRES_PORT -U \$POSTGRES_USERNAME -d \$POSTGRES_DATABASE -c \"\\l\"'"

# Test Redis depuis un pod
ssh root@10.0.0.100 "kubectl exec -n chatwoot -it \$(kubectl get pod -n chatwoot -l component=web -o name | head -1) -- \
  sh -c 'redis-cli -u \$REDIS_URL PING'"
```

## ⚠️ Problèmes Connus et Solutions

### Problème : Pods encore en CrashLoopBackOff

**Solution 1 : Vérifier les credentials**
```bash
# Vérifier que postgres.env existe et contient le bon mot de passe
cat /opt/keybuzz-installer/credentials/postgres.env

# Vérifier que redis.env existe
cat /opt/keybuzz-installer/credentials/redis.env
```

**Solution 2 : Vérifier la connectivité réseau**
```bash
# Depuis le master K3s, tester PostgreSQL
ssh root@10.0.0.100 "PGPASSWORD='votre_password' psql -h 10.0.0.10 -p 6432 -U chatwoot -d chatwoot -c 'SELECT version();'"

# Tester Redis
ssh root@10.0.0.100 "redis-cli -h 10.0.0.10 -p 6379 -a 'votre_password' PING"
```

**Solution 3 : Examiner les logs détaillés**
```bash
ssh root@10.0.0.100 "kubectl describe pod -n chatwoot -l component=web | tail -100"
```

### Problème : Migration DB échoue

**Cause** : Base de données non créée ou credentials incorrects

**Solution** :
```bash
# Recréer la base de données chatwoot
ssh root@10.0.0.100 "PGPASSWORD='votre_password' psql -h 10.0.0.10 -p 6432 -U postgres -c 'DROP DATABASE IF EXISTS chatwoot;'"
ssh root@10.0.0.100 "PGPASSWORD='votre_password' psql -h 10.0.0.10 -p 6432 -U postgres -c 'CREATE DATABASE chatwoot OWNER chatwoot;'"

# Relancer le script
bash fix_chatwoot_complete.sh
```

### Problème : Timeout sur Health Checks

**Symptôme** : Pods redémarrent après ~60 secondes

**Solution** : Les délais sont déjà augmentés dans le fix. Si le problème persiste :
```bash
# Augmenter les ressources CPU/Memory
# Éditer le DaemonSet
ssh root@10.0.0.100 "kubectl edit daemonset chatwoot-web -n chatwoot"

# Augmenter :
resources:
  limits:
    memory: "4Gi"  # Au lieu de 2Gi
    cpu: "2000m"   # Au lieu de 1000m
```

### Problème : "Cannot connect to database"

**Causes possibles** :
1. PgBouncer non démarré
2. Port 6432 bloqué par firewall
3. User `chatwoot` n'existe pas dans PostgreSQL

**Solution** :
```bash
# Vérifier PgBouncer
ssh root@10.0.0.10 "docker ps | grep pgbouncer"
ssh root@10.0.0.10 "netstat -tlnp | grep 6432"

# Vérifier user chatwoot existe
ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c '\\du'"

# Si manquant, créer :
cd /home/user/KB/scripts/08_PostgreSQL_16_HA_Patroni
bash 02_prepare_database_DIRECT.sh
```

## 📚 Architecture Finale

```
┌─────────────────────────────────────────────────────────────┐
│                   Ingress NGINX                              │
│              http://chat.keybuzz.io                          │
└────────────────────┬────────────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────────────┐
│              Service: chatwoot (ClusterIP)                   │
│                    Port: 3000                                │
└────────────────────┬────────────────────────────────────────┘
                     │
     ┌───────────────┴───────────────┐
     │                               │
┌────┴─────────────┐        ┌───────┴──────────┐
│  DaemonSet Web   │        │  DaemonSet Worker│
│  5 pods (1/node) │        │  5 pods (1/node) │
│  hostPort: 3000  │        │  Sidekiq         │
└────┬─────────────┘        └───────┬──────────┘
     │                              │
     └──────────────┬───────────────┘
                    │
     ┌──────────────┴──────────────┐
     │                             │
┌────┴────────────┐      ┌─────────┴────────┐
│  PostgreSQL     │      │  Redis           │
│  10.0.0.10:6432 │      │  10.0.0.10:6379  │
│  (PgBouncer)    │      │  (Sentinel)      │
└─────────────────┘      └──────────────────┘
```

## 🎯 Prochaines Étapes

Une fois Chatwoot opérationnel :

1. **Accéder à l'interface**
   ```
   http://chat.keybuzz.io
   ```

2. **Créer le premier compte** (sera automatiquement admin)

3. **Configurer le workspace** :
   - Nom de l'organisation
   - Fuseau horaire
   - Langue

4. **Configurer les channels** :
   - Website widget
   - Email
   - API
   - Intégrations (Facebook, Twitter, etc.)

5. **Inviter les agents**

6. **Configurer les automations**

7. **Surveiller les performances**
   ```bash
   # Métrique des pods
   ssh root@10.0.0.100 "kubectl top pods -n chatwoot"

   # Logs d'activité
   ssh root@10.0.0.100 "kubectl logs -n chatwoot -l component=web --tail=100 -f"
   ```

## 📞 Support

Si le problème persiste après avoir appliqué ce fix :

1. **Collecter les logs complets** :
   ```bash
   ssh root@10.0.0.100 "kubectl logs -n chatwoot -l component=web --all-containers=true --tail=500" > chatwoot_web_logs.txt
   ssh root@10.0.0.100 "kubectl describe pods -n chatwoot" > chatwoot_pods_describe.txt
   ssh root@10.0.0.100 "kubectl get events -n chatwoot --sort-by='.lastTimestamp'" > chatwoot_events.txt
   ```

2. **Vérifier la version de Chatwoot** :
   ```bash
   ssh root@10.0.0.100 "kubectl get daemonset chatwoot-web -n chatwoot -o jsonpath='{.spec.template.spec.containers[0].image}'"
   ```

3. **Comparer avec un déploiement qui fonctionne** (ex: n8n) :
   ```bash
   ssh root@10.0.0.100 "kubectl get pods -n n8n -o wide"
   ```

## 📝 Notes de Version

- **Version** : 1.0
- **Date** : 2025-11-13
- **Auteur** : Claude (Assistant IA)
- **Testé sur** : K3s HA (3 masters + 5 workers)
- **Image Chatwoot** : `chatwoot/chatwoot:latest`

## 🔐 Sécurité

⚠️ **Important** :
- Les secrets K8s sont stockés en base64 (pas chiffré)
- Changez le `SECRET_KEY_BASE` après la première installation
- Configurez SSL/TLS en production (Let's Encrypt)
- Limitez l'accès réseau via NetworkPolicies
- Activez RBAC pour K8s

Pour activer SSL :
```bash
# Installer cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Configurer Let's Encrypt
# (instructions complètes dans le guide Ingress NGINX)
```
