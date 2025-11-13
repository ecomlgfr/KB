# 🧪 Suite de Tests Infrastructure KeyBuzz

Documentation complète pour tester l'infrastructure KeyBuzz (Hetzner, sans WireGuard).

---

## 📋 Vue d'ensemble

Cette suite comprend **3 scripts de test complets** qui valident tous les aspects de votre infrastructure haute disponibilité :

1. **test_infrastructure_complete.sh** - Tests exhaustifs sans modification
2. **test_failover_safe.sh** - Tests de basculement automatique (SAFE)
3. **test_performance_load.sh** - Tests de charge et performance

---

## 🎯 Script 1: test_infrastructure_complete.sh

### Description
Test **NON DESTRUCTIF** de tous les composants de l'infrastructure. Vérifie la connectivité, l'état des services, et le bon fonctionnement général.

### Ce qui est testé

#### ✅ TEST 1: Connectivité SSH
- Connexion SSH vers tous les nœuds (db-master, db-slave, haproxy, redis, rabbitmq, k3s)
- Vérification de l'accessibilité des IPs privées depuis install-01

#### ✅ TEST 2: PostgreSQL + Patroni
- État des containers Patroni sur les 3 nœuds
- Détection du leader actuel
- Nombre de replicas en streaming
- Connexions directes à chaque nœud PostgreSQL
- État de la réplication (`pg_stat_replication`)

#### ✅ TEST 3: HAProxy + PgBouncer
- État des containers HAProxy et PgBouncer sur haproxy-01/02
- Accessibilité des ports:
  - 5432 (HAProxy write)
  - 5433 (HAProxy read)
  - 6432 (PgBouncer)
  - 8404 (HAProxy stats)
- Test de connexion SQL via la VIP 10.0.0.10

#### ✅ TEST 4: Redis + Sentinel
- État des containers Redis et Sentinel sur les 3 nœuds
- Détection du master Redis actuel
- Nombre de sentinels actifs
- Test PING sur chaque nœud
- Accessibilité via HAProxy (port 6379)
- Test write/read via la VIP

#### ✅ TEST 5: RabbitMQ Cluster
- État des containers RabbitMQ sur les 3 nœuds
- Ports AMQP (5672) et Management (15672)
- État du cluster (nombre de nœuds)
- Accessibilité via HAProxy et VIP

#### ✅ TEST 6: K3s Cluster
- État du service K3s sur les masters
- Nombre de nœuds ready
- Pods système en cours d'exécution
- HAProxy K3s API (port 6443)

#### ✅ TEST 7: Applications
- Pods n8n et Chatwoot dans K3s
- Simulation de connexion applicative à PostgreSQL

#### ✅ TEST 8: Volumes et Stockage
- Volumes montés sur les nœuds critiques
- Espace disque disponible
- Alertes si > 80% utilisé

#### ✅ TEST 9: Sécurité et Firewall
- État UFW sur les nœuds
- Authentification SSH (vérification clés uniquement)

#### ✅ TEST 10: Performance et Latence
- Latence réseau inter-nœuds (ping)
- Test de charge simple (10 connexions PostgreSQL)

### Utilisation

```bash
# Copier sur install-01
scp test_infrastructure_complete.sh root@install-01:/opt/keybuzz-installer/

# Se connecter à install-01
ssh root@install-01

# Rendre exécutable
chmod +x /opt/keybuzz-installer/test_infrastructure_complete.sh

# Lancer le test
cd /opt/keybuzz-installer
./test_infrastructure_complete.sh
```

### Résultat attendu

```
═══════════════════════════════════════════════════════════════════
  RÉSUMÉ DES TESTS
═══════════════════════════════════════════════════════════════════

  Total tests exécutés : 85
  ✓ OK Tests réussis    : 82
  ✗ KO Tests échoués    : 3

✓ OK Infrastructure EXCELLENTE (96% de réussite)

🎉 Votre infrastructure KeyBuzz est opérationnelle et performante !
```

### Temps d'exécution
**~5-8 minutes** pour tester toute l'infrastructure

---

## 🔥 Script 2: test_failover_safe.sh

### ⚠️ IMPORTANT
Ce script **ARRÊTE TEMPORAIREMENT** des services pour tester les basculements automatiques. 
- **NE TOUCHE PAS** au firewall (pas de coupure réseau)
- **REDÉMARRE AUTOMATIQUEMENT** tous les services après chaque test
- **SAFE** pour l'infrastructure (testé en production)

### Ce qui est testé

#### 🔄 TEST 1: Failover PostgreSQL/Patroni
**Scénario**: Arrêt du leader Patroni actuel

**Étapes**:
1. Détection du leader actuel (ex: db-master-01)
2. Arrêt du container Patroni sur le leader
3. Attente du failover automatique (~30s)
4. Vérification du nouveau leader
5. Test de connectivité pendant le failover
6. Redémarrage de l'ancien leader
7. Vérification que le nœud rejoint en tant que replica

**Résultat attendu**: 
- Nouveau leader élu en < 30 secondes
- PostgreSQL reste accessible via VIP (tolérance < 5s d'interruption)
- Ancien leader rejoint le cluster en tant que replica

#### 🔄 TEST 2: Failover HAProxy/Keepalived (VIP)
**Scénario**: Arrêt de Keepalived sur le MASTER VIP

**Étapes**:
1. Détection du nœud MASTER actuel (qui possède la VIP)
2. Arrêt de Keepalived sur le MASTER
3. Attente du basculement (~10s)
4. Vérification que la VIP est sur le BACKUP
5. Test de connectivité pendant le basculement
6. Redémarrage de Keepalived sur l'ancien MASTER
7. Vérification du retour automatique (préemption)

**Résultat attendu**:
- VIP bascule en < 10 secondes
- Services restent accessibles (tolérance < 5s)
- VIP retourne automatiquement sur le MASTER d'origine (préemption active)

#### 🔄 TEST 3: Failover Redis Sentinel
**Scénario**: Arrêt du Redis master actuel

**Étapes**:
1. Détection du master Redis (via Sentinel)
2. Test d'écriture AVANT le failover
3. Arrêt du container Redis master
4. Attente de la promotion Sentinel (~30s)
5. Vérification du nouveau master
6. Test d'écriture après failover
7. Redémarrage de l'ancien master
8. Vérification qu'il rejoint en tant que replica

**Résultat attendu**:
- Nouveau master promu en < 30 secondes
- Écritures restent possibles après ~5s
- HAProxy détecte automatiquement le nouveau master

#### 🔄 TEST 4: Résilience RabbitMQ
**Scénario**: Arrêt d'un nœud RabbitMQ

**Étapes**:
1. État du cluster AVANT
2. Arrêt d'un nœud (ex: rabbitmq-01)
3. Test de connectivité via VIP
4. Redémarrage du nœud
5. Vérification de la réintégration au cluster

**Résultat attendu**:
- RabbitMQ reste accessible via VIP (HAProxy route vers les 2 autres nœuds)
- Nœud redémarré rejoint le cluster automatiquement
- Quorum maintenu (2/3 nœuds suffisent)

#### 🔄 TEST 5: Résilience Applicative
**Scénario**: Simulation de charge continue pendant les failovers

**Étapes**:
1. 20 connexions successives à PostgreSQL
2. Test de persistence de données (CREATE TABLE, INSERT, SELECT)
3. Vérification que les applications peuvent continuer à fonctionner

**Résultat attendu**:
- Au moins 18/20 connexions réussies
- Données persistées correctement
- Aucune perte de données

### Utilisation

```bash
# Copier sur install-01
scp test_failover_safe.sh root@install-01:/opt/keybuzz-installer/

# Se connecter à install-01
ssh root@install-01

# Rendre exécutable
chmod +x /opt/keybuzz-installer/test_failover_safe.sh

# Lancer le test (confirmation demandée)
cd /opt/keybuzz-installer
./test_failover_safe.sh

# Le script demande confirmation
Voulez-vous continuer ? (yes/no): yes
```

### Temps d'exécution
**~10-15 minutes** (attente des failovers automatiques)

### ⚠️ À savoir
- **Interruption de service**: < 5 secondes par failover (acceptable en production)
- **Tous les services sont restaurés**: Le script redémarre automatiquement tous les services arrêtés
- **Logs détaillés**: Chaque étape est documentée dans `/opt/keybuzz-installer/logs/test_failover_YYYYMMDD_HHMMSS.log`

---

## ⚡ Script 3: test_performance_load.sh

### Description
Tests de **charge et performance** pour valider les capacités de l'infrastructure sous stress.

### Ce qui est testé

#### ⚡ TEST 1: Performance PostgreSQL
- **Charge simultanée**: 50 connexions parallèles
- **Throughput**: 1000 requêtes séquentielles
- **Statistiques PgBouncer**: Pools de connexions
- **Métriques**:
  - Latence moyenne par requête
  - Requêtes par seconde (QPS)
  - Taux de réussite

#### ⚡ TEST 2: Performance Redis
- **Latence**: 100 opérations SET/GET
- **Throughput**: 1000 SET rapides
- **Métriques**:
  - Latence moyenne par opération
  - Opérations par seconde (OPS)

#### ⚡ TEST 3: Utilisation des ressources
- **CPU**: Utilisation sur chaque nœud
- **RAM**: Mémoire utilisée/disponible
- **Disk I/O**: Utilisation des disques

#### ⚡ TEST 4: Latence réseau
- **Matrice de ping**: Entre tous les nœuds critiques
- **Détection**: Latences anormales (> 5ms sur réseau privé)

#### ⚡ TEST 5: Statistiques PostgreSQL avancées
- **Réplication lag**: Retard entre master et replicas
- **Connexions actives**: Nombre de clients connectés
- **Slow queries**: Top 5 des requêtes lentes (si `pg_stat_statements` activé)

#### ⚡ TEST 6: Charge mixte (réaliste)
- **Scénario**: 50 workers x 10 itérations
- **Opérations**: PostgreSQL + Redis simultanément
- **Métriques**: Taux de réussite sous charge réaliste

### Utilisation

```bash
# Copier sur install-01
scp test_performance_load.sh root@install-01:/opt/keybuzz-installer/

# Se connecter à install-01
ssh root@install-01

# Rendre exécutable
chmod +x /opt/keybuzz-installer/test_performance_load.sh

# Lancer le test
cd /opt/keybuzz-installer
./test_performance_load.sh
```

### Temps d'exécution
**~8-12 minutes** (tests de charge)

### Résultats attendus (référence)

**PostgreSQL**:
- Throughput: > 500 QPS (requêtes/seconde)
- Latence: < 10ms par requête
- Connexions simultanées: 50/50 réussies

**Redis**:
- Throughput: > 5000 OPS (opérations/seconde)
- Latence: < 2ms par opération

**Charge mixte**:
- Taux de réussite: > 95%
- PostgreSQL: > 450/500 requêtes
- Redis: > 475/500 opérations

**Ressources**:
- CPU: < 60% en moyenne
- RAM: < 75%
- Latence réseau: < 2ms (réseau privé Hetzner)

---

## 📊 Interprétation des résultats

### Codes de couleur

- **✓ OK** (vert) : Test réussi, tout fonctionne
- **✗ KO** (rouge) : Test échoué, problème critique
- **⚠ WARN** (jaune) : Avertissement, dégradation acceptable
- **ℹ INFO** (bleu) : Information neutre

### Résumé de santé

#### EXCELLENTE (> 95%)
```
✓ OK Infrastructure EXCELLENTE (98% de réussite)
🎉 Votre infrastructure KeyBuzz est opérationnelle et performante !
```
→ Infrastructure **production-ready**, aucune action requise

#### ACCEPTABLE (80-95%)
```
⚠ WARN Infrastructure ACCEPTABLE (87% de réussite)
⚠️ Quelques problèmes mineurs détectés, mais l'infrastructure fonctionne.
```
→ Infrastructure fonctionnelle, **investigation recommandée** pour les tests échoués

#### PROBLÉMATIQUE (< 80%)
```
✗ KO Infrastructure PROBLÉMATIQUE (65% de réussite)
❌ Problèmes critiques détectés. Vérifiez les logs ci-dessus.
```
→ **Action immédiate requise**, vérifier les composants en échec

---

## 🔍 Logs et débogage

### Localisation des logs

Tous les scripts génèrent des logs détaillés dans:
```
/opt/keybuzz-installer/logs/
├── test_infrastructure_YYYYMMDD_HHMMSS.log
├── test_failover_YYYYMMDD_HHMMSS.log
└── test_performance_YYYYMMDD_HHMMSS.log
```

### Consulter les logs

```bash
# Dernières lignes d'un test
tail -n 100 /opt/keybuzz-installer/logs/test_infrastructure_*.log

# Rechercher les erreurs
grep -E "KO|FAILED|ERROR" /opt/keybuzz-installer/logs/*.log

# Voir tous les résultats OK
grep "OK" /opt/keybuzz-installer/logs/test_infrastructure_*.log | grep "✓"
```

### Débogage des composants individuels

Si un test échoue, vérifier le composant directement:

**PostgreSQL/Patroni**:
```bash
ssh root@$(awk -F'\t' '$2=="db-master-01"{print $3}' /opt/keybuzz-installer/inventory/servers.tsv)
docker exec patroni patronictl list
docker logs patroni --tail 50
```

**HAProxy**:
```bash
ssh root@$(awk -F'\t' '$2=="haproxy-01"{print $3}' /opt/keybuzz-installer/inventory/servers.tsv)
docker logs haproxy --tail 50
curl http://localhost:8404/stats
```

**Redis**:
```bash
ssh root@$(awk -F'\t' '$2=="redis-01"{print $3}' /opt/keybuzz-installer/inventory/servers.tsv)
docker exec sentinel redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
docker logs redis --tail 50
```

**RabbitMQ**:
```bash
ssh root@$(awk -F'\t' '$2=="rabbitmq-01"{print $3}' /opt/keybuzz-installer/inventory/servers.tsv)
docker exec rabbitmq rabbitmqctl cluster_status
docker logs rabbitmq --tail 50
```

---

## 🎯 Cas d'usage recommandés

### Quand lancer chaque script ?

#### test_infrastructure_complete.sh
**Fréquence**: 
- **Après chaque déploiement** (nouvelle installation, mise à jour)
- **Quotidien** (monitoring automatique via cron)
- **Avant une maintenance**
- **Après un incident**

**Cas d'usage**:
- Vérifier que tout fonctionne après une installation
- Monitoring de santé régulier
- Validation avant production

#### test_failover_safe.sh
**Fréquence**: 
- **Après installation initiale** (valider la HA)
- **Mensuel** (vérifier que les failovers fonctionnent toujours)
- **Après modification infrastructure** (ajout nœud, changement config)
- **Avant une montée de version** (s'assurer que la HA fonctionne)

**Cas d'usage**:
- Valider que les mécanismes de haute disponibilité fonctionnent
- Tester la résilience avant un événement majeur
- Prouver le RTO (Recovery Time Objective) réel

⚠️ **À éviter**: 
- En heures de forte charge
- Sur une infrastructure déjà dégradée
- Sans avoir lu les logs au préalable

#### test_performance_load.sh
**Fréquence**: 
- **Après installation initiale** (baseline de performance)
- **Mensuel ou trimestriel** (détecter les dégradations)
- **Avant scaling up/down** (valider capacité actuelle)
- **Après tuning** (valider les optimisations)

**Cas d'usage**:
- Établir une baseline de performance
- Détecter les dégradations progressives
- Valider les optimisations
- Planifier le scaling

---

## 🤖 Automatisation

### Cron job pour test quotidien

```bash
# Sur install-01
crontab -e

# Ajouter:
# Test infrastructure complet chaque jour à 3h du matin
0 3 * * * /opt/keybuzz-installer/test_infrastructure_complete.sh >> /opt/keybuzz-installer/logs/cron_test.log 2>&1

# Test de performance chaque lundi à 4h
0 4 * * 1 /opt/keybuzz-installer/test_performance_load.sh >> /opt/keybuzz-installer/logs/cron_perf.log 2>&1
```

### Alertes (exemple avec un webhook)

```bash
# Ajouter à la fin de test_infrastructure_complete.sh
if [ "$PASS_PERCENT" -lt 90 ]; then
    curl -X POST https://votre-webhook.com/alert \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"⚠️ Infrastructure KeyBuzz dégradée: ${PASS_PERCENT}% OK\"}"
fi
```

---

## 📈 Métriques de référence

### Infrastructure saine

| Composant | Métrique | Valeur attendue | Alerte si |
|-----------|----------|-----------------|-----------|
| PostgreSQL | Réplication lag | < 100ms | > 1s |
| PostgreSQL | Connexions actives | < 100 | > 200 |
| PostgreSQL | QPS | > 500 | < 100 |
| Redis | Latence moyenne | < 2ms | > 10ms |
| Redis | OPS | > 5000 | < 1000 |
| HAProxy | Backend actifs | 3/3 | < 2/3 |
| Keepalived | VIP active | 1 nœud | 0 nœuds |
| Patroni | Leader | 1 nœud | 0 ou > 1 |
| K3s | Nœuds ready | 8/8 | < 6/8 |
| Latence réseau | Inter-nœuds | < 2ms | > 5ms |

---

## ❓ FAQ

### Q: Les tests cassent-ils l'infrastructure ?
**R**: Non. 
- `test_infrastructure_complete.sh` : **0% destructif** (lecture seule)
- `test_failover_safe.sh` : **Safe** (redémarre automatiquement tout)
- `test_performance_load.sh` : **Safe** (charge contrôlée)

### Q: Combien de temps d'interruption lors des tests de failover ?
**R**: 
- PostgreSQL: < 5 secondes
- HAProxy/VIP: < 3 secondes
- Redis: < 5 secondes
- RabbitMQ: 0 seconde (les 2 autres nœuds prennent le relais)

### Q: Puis-je lancer les tests en production ?
**R**: 
- `test_infrastructure_complete.sh` : **OUI** (aucun risque)
- `test_failover_safe.sh` : **OUI AVEC PRÉCAUTION** (micro-interruptions)
- `test_performance_load.sh` : **OUI HORS HEURES DE POINTE**

### Q: Que faire si un test échoue ?
**R**: 
1. Consulter les logs détaillés
2. Vérifier l'état du composant directement (docker logs, patronictl, etc.)
3. Vérifier les fichiers de configuration
4. Relancer l'installation du composant si nécessaire

### Q: Les tests modifient-ils le firewall ?
**R**: **NON**. Les scripts ne touchent JAMAIS aux règles UFW ou iptables. C'est un principe fondamental de conception pour éviter de casser les connexions.

---

## 🎓 Checklist d'utilisation

### Avant de lancer les tests

- [ ] Vous êtes sur `install-01`
- [ ] Le fichier `servers.tsv` est à jour
- [ ] Les credentials sont dans `/opt/keybuzz-installer/credentials/secrets.json`
- [ ] Tous les services sont déployés
- [ ] Vous avez lu cette documentation

### Après les tests

- [ ] Consulter le résumé affiché
- [ ] Vérifier le pourcentage de réussite
- [ ] Lire les logs pour les tests échoués
- [ ] Documenter les problèmes détectés
- [ ] Corriger les problèmes si nécessaire

---

## 📞 Support

Si vous rencontrez des problèmes avec les scripts de test:

1. **Consulter les logs détaillés** dans `/opt/keybuzz-installer/logs/`
2. **Vérifier les états des services** individuellement
3. **Relancer l'installation** du composant problématique si besoin

---

## 🚀 Résumé rapide

```bash
# Test complet (SAFE)
./test_infrastructure_complete.sh

# Test failover (DEMANDE CONFIRMATION)
./test_failover_safe.sh

# Test performance
./test_performance_load.sh
```

**Temps total**: ~25-35 minutes pour les 3 scripts

**Résultat attendu**: > 95% de tests réussis = Infrastructure production-ready ✅

---

*Documentation générée pour KeyBuzz Infrastructure v2.0 - Infrastructure Hetzner (sans WireGuard)*
