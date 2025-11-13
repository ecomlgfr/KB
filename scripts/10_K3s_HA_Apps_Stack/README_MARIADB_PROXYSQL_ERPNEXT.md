# Installation MariaDB Galera + ProxySQL + ERPNext - KeyBuzz v2.0

**Date**: 2025-11-13
**Auteur**: Claude AI Assistant
**Version**: 2.0

---

## 📋 Table des Matières

1. [Vue d'ensemble](#vue-densemble)
2. [Architecture](#architecture)
3. [Prérequis](#prérequis)
4. [Installation complète](#installation-complète)
5. [Vérifications](#vérifications)
6. [Maintenance](#maintenance)
7. [Troubleshooting](#troubleshooting)
8. [Améliorations vs v1.0](#améliorations-vs-v10)

---

## Vue d'ensemble

Cette documentation décrit l'installation complète d'une stack MariaDB Galera haute disponibilité avec ProxySQL et ERPNext sur Kubernetes K3s.

### Composants

- **MariaDB Galera Cluster**: Base de données synchrone 3 nœuds
- **ProxySQL**: Proxy SQL avec load balancing et failover automatique
- **Hetzner Load Balancer**: Load balancer L4 TCP pour ProxySQL
- **ERPNext**: Application ERP sur K3s

### Topologie

```
┌─────────────────────────────────────────────────────────────┐
│                    Hetzner Load Balancer                    │
│                    10.0.0.10:6033 (TCP)                     │
└─────────────────────┬───────────────────────────────────────┘
                      │
         ┌────────────┴────────────┐
         │                         │
         ▼                         ▼
┌────────────────┐        ┌────────────────┐
│  ProxySQL 01   │        │  ProxySQL 02   │
│  10.0.0.104    │        │  10.0.0.105    │
│  Port: 6033    │        │  Port: 6033    │
└────────┬───────┘        └────────┬───────┘
         │                         │
         └────────────┬────────────┘
                      │
         ┌────────────┴────────────┬────────────┐
         ▼                         ▼            ▼
┌────────────────┐        ┌────────────────┐   ┌────────────────┐
│  MariaDB DB01  │◄──────►│  MariaDB DB02  │◄─►│  MariaDB DB03  │
│  10.0.0.101    │  Sync  │  10.0.0.102    │   │  10.0.0.103    │
│  Port: 3306    │        │  Port: 3306    │   │  Port: 3306    │
│  Galera: 4567  │        │  Galera: 4567  │   │  Galera: 4567  │
└────────────────┘        └────────────────┘   └────────────────┘
                      │
                      ▼
        ┌─────────────────────────────┐
        │      K3s Cluster            │
        │   ERPNext Namespace         │
        │   - Backend (Gunicorn)      │
        │   - Frontend (Nginx)        │
        │   - Scheduler               │
        │   - Workers (3 types)       │
        │   - Socketio                │
        │   - Redis (cache/queue)     │
        └─────────────────────────────┘
```

---

## Architecture

### MariaDB Galera Cluster

**Nœuds**: 3 (DB01, DB02, DB03)

| Composant | Description | Port |
|-----------|-------------|------|
| MariaDB | Base de données | 3306 |
| Galera Cluster | Réplication synchrone | 4567 (TCP/UDP) |
| SST | State Snapshot Transfer | 4444 |
| IST | Incremental State Transfer | 4568 |
| mysqld_exporter | Métriques Prometheus | 9104 |

**Caractéristiques**:
- Réplication synchrone multi-master
- SST via `xtrabackup-v2` (plus performant que rsync)
- XFS filesystem sur `/opt/keybuzz/mariadb/data`
- Monitoring ProxySQL intégré
- Certification de toutes les transactions
- Détection automatique des nœuds défaillants

### ProxySQL

**Nœuds**: 2 (PROXY01, PROXY02)

| Composant | Description | Port |
|-----------|-------------|------|
| MySQL Interface | Port application | 6033 |
| Admin Interface | Port gestion | 6032 |

**Caractéristiques**:
- Read/Write split automatique
- Health checks toutes les 10 secondes
- Failover automatique en cas de panne
- Query routing intelligent
- Connection pooling
- Query caching

**Hostgroups**:
- **Hostgroup 10**: Writers (tous les nœuds Galera)
- **Hostgroup 20**: Readers (tous les nœuds Galera)
- **Hostgroup 30**: Offline (nœuds en maintenance)

**Query Rules**:
1. `SELECT ... FOR UPDATE` → Writer hostgroup
2. `SELECT` → Reader hostgroup
3. Tout le reste → Writer hostgroup

### Hetzner Load Balancer

**Configuration**:
- Type: TCP (Layer 4)
- IP: 10.0.0.10
- Port: 6033
- Backends:
  - 10.0.0.104:6033 (PROXY01)
  - 10.0.0.105:6033 (PROXY02)
- Health Check: TCP sur port 6033
- Algorithm: Round Robin

### ERPNext sur K3s

**Namespace**: `erpnext`

**Composants déployés**:

| Component | Type | Replicas | Description |
|-----------|------|----------|-------------|
| redis-cache | Deployment | 1 | Cache L1 |
| redis-queue | Deployment | 1 | Queue RQ |
| redis-socketio | Deployment | 1 | Real-time |
| backend | Deployment | 2 | Gunicorn WSGI |
| frontend | Deployment | 2 | Nginx reverse proxy |
| scheduler | Deployment | 1 | Cron jobs |
| worker-default | Deployment | 2 | Background jobs |
| worker-short | Deployment | 2 | Quick tasks |
| worker-long | Deployment | 1 | Long tasks |
| socketio | Deployment | 1 | WebSocket |

**Storage**:
- PVC `erpnext-sites`: 10Gi (ReadWriteMany)
- StorageClass: `longhorn`

---

## Prérequis

### Infrastructure

- 3 serveurs pour MariaDB Galera (minimum 4 GB RAM, 2 vCPU)
- 2 serveurs pour ProxySQL (minimum 2 GB RAM, 1 vCPU)
- K3s cluster opérationnel (3 masters + 5 workers)
- Hetzner Cloud avec réseau privé 10.0.0.0/16
- Disque supplémentaire pour MariaDB (recommandé: SSD NVMe, min 100GB)

### Réseau

- Réseau privé Hetzner configuré (10.0.0.0/16)
- Hetzner Load Balancer créé et configuré
- DNS résolu pour le domaine ERPNext

### Software

- Ubuntu 22.04 LTS (pour MariaDB et ProxySQL)
- K3s v1.28+ (sur le cluster Kubernetes)
- kubectl configuré
- Ingress NGINX installé sur K3s
- Cert-manager installé (pour TLS)
- Longhorn storage class disponible

---

## Installation complète

### Étape 1: Installation MariaDB Galera

**Sur chaque nœud DB01, DB02, DB03**:

```bash
# Copier le script
scp install_mariadb_galera_keybuzz.sh root@10.0.0.101:/root/

# Se connecter au serveur
ssh root@10.0.0.101

# Rendre exécutable
chmod +x install_mariadb_galera_keybuzz.sh

# Exécuter l'installation
./install_mariadb_galera_keybuzz.sh
```

**Le script va**:
1. Détecter le nœud automatiquement (DB01, DB02, ou DB03)
2. Demander le disque pour XFS (ex: sdb, nvme1n1)
3. Formater le disque en XFS et monter sur `/opt/keybuzz/mariadb/data`
4. Configurer UFW (ports 22, 3306, 4444, 4567, 4568, 9104)
5. Installer MariaDB 10.11 + Galera 4 + Percona XtraBackup
6. Configurer Galera avec SST `xtrabackup-v2`
7. Créer les utilisateurs:
   - `root` (admin)
   - `sst_user` (pour Galera SST)
   - `proxysql-cluster` (monitoring ProxySQL)
   - `mysqld_exporter` (Prometheus)
   - `erpnext` (application)
8. Installer mysqld_exporter
9. Sauvegarder les credentials dans `/opt/keybuzz/mariadb/credentials_DBxx.txt`

**⚠️ IMPORTANT**: NE PAS démarrer MariaDB encore!

#### Bootstrap du cluster (DB01 UNIQUEMENT)

Après installation sur les 3 nœuds:

```bash
# Sur DB01 uniquement
ssh root@10.0.0.101

# Bootstrap le cluster
systemctl stop mariadb
galera_new_cluster

# Démarrer l'exporter
systemctl start mysqld_exporter

# Vérifier le cluster
mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Doit afficher: wsrep_cluster_size | 1
```

#### Démarrage des autres nœuds

```bash
# Sur DB02
ssh root@10.0.0.102
systemctl start mariadb
systemctl start mysqld_exporter

# Sur DB03
ssh root@10.0.0.103
systemctl start mariadb
systemctl start mysqld_exporter
```

#### Vérification du cluster

```bash
# Sur n'importe quel nœud
mysql -u root -p -e "SHOW STATUS LIKE 'wsrep%';"
```

**Métriques importantes**:
- `wsrep_cluster_size`: 3 (nombre de nœuds)
- `wsrep_cluster_status`: Primary
- `wsrep_connected`: ON
- `wsrep_ready`: ON
- `wsrep_local_state_comment`: Synced

---

### Étape 2: Installation ProxySQL

**Sur chaque nœud PROXY01, PROXY02**:

```bash
# Copier le script
scp install_proxysql_keybuzz.sh root@10.0.0.104:/root/

# Se connecter au serveur
ssh root@10.0.0.104

# Rendre exécutable
chmod +x install_proxysql_keybuzz.sh

# Exécuter l'installation
./install_proxysql_keybuzz.sh
```

**Le script va demander**:
- ProxySQL Monitor User: `proxysql-cluster` (défaut)
- ProxySQL Monitor Password: (copier depuis `/opt/keybuzz/mariadb/credentials_DB01.txt`)
- Application User: `erpnext` (défaut)
- Application Password: (copier depuis `/opt/keybuzz/mariadb/credentials_DB01.txt`)

**Le script va**:
1. Détecter le nœud automatiquement (PROXY01 ou PROXY02)
2. Configurer UFW (ports 22, 6032, 6033)
3. Installer ProxySQL 2.5.5
4. Configurer les backends MariaDB (3 nœuds)
5. Configurer les hostgroups (Writer: 10, Reader: 20)
6. Configurer les query rules (read/write split)
7. Créer l'utilisateur application
8. Sauvegarder les credentials dans `/opt/keybuzz/proxysql/credentials_PROXYxx.txt`

#### Vérification ProxySQL

```bash
# Connexion admin
mysql -h 10.0.0.104 -P 6032 -uadmin -p

# Vérifier les backends
SELECT hostgroup_id, hostname, port, status
FROM stats_mysql_connection_pool
ORDER BY hostgroup_id, hostname;

# Vérifier les health checks
SELECT * FROM monitor.mysql_server_ping_log
ORDER BY time_start_us DESC LIMIT 10;

# Tester la connexion applicative
mysql -h 10.0.0.104 -P 6033 -uerpnext -p erpnext
```

---

### Étape 3: Configuration Hetzner Load Balancer

**Via l'interface Hetzner Cloud**:

1. Créer un Load Balancer:
   - Type: LB11 (ou supérieur)
   - Location: Même que vos serveurs
   - Réseau: Réseau privé 10.0.0.0/16
   - IP privée: 10.0.0.10

2. Configurer le service:
   - Protocol: TCP
   - Port: 6033
   - Destination Port: 6033

3. Ajouter les targets:
   - 10.0.0.104 (PROXY01)
   - 10.0.0.105 (PROXY02)

4. Configurer Health Check:
   - Protocol: TCP
   - Port: 6033
   - Interval: 10s
   - Timeout: 5s
   - Retries: 3

5. Configurer l'algorithme:
   - Round Robin (défaut)

#### Test du Load Balancer

```bash
# Depuis n'importe quel serveur du réseau privé
mysql -h 10.0.0.10 -P 6033 -uerpnext -p erpnext -e "SELECT @@hostname;"

# Exécuter plusieurs fois pour voir la rotation
for i in {1..10}; do
  mysql -h 10.0.0.10 -P 6033 -uerpnext -p'PASSWORD' erpnext \
    -e "SELECT @@hostname AS backend;" 2>/dev/null
  sleep 1
done
```

---

### Étape 4: Déploiement ERPNext sur K3s

**Sur un master K3s**:

```bash
# Copier le script
scp deploy_erpnext_k3s.sh user@k3s-master:/home/user/

# Se connecter au master
ssh user@k3s-master

# Rendre exécutable
chmod +x deploy_erpnext_k3s.sh

# Exécuter le déploiement
./deploy_erpnext_k3s.sh
```

**Le script va demander**:
- Database User: `erpnext` (défaut)
- Database Password: (copier depuis credentials)
- Database Root Password: (pour l'init)
- Site Name: `erp.keybuzz.local` (ou votre domaine)

**Le script va**:
1. Vérifier les prérequis (kubectl, K3s, Ingress NGINX)
2. Créer le namespace `erpnext`
3. Déployer 3 instances Redis (cache, queue, socketio)
4. Créer les secrets Kubernetes
5. Créer le PVC pour les sites (10Gi)
6. Lancer le job de création du site ERPNext
7. Déployer tous les composants:
   - Backend (2 replicas)
   - Frontend (2 replicas)
   - Scheduler (1 replica)
   - Workers: default (2), short (2), long (1)
   - Socketio (1 replica)
8. Créer l'Ingress avec TLS
9. Sauvegarder les credentials

**⚠️ IMPORTANT**: Le job de création du site peut prendre 5-10 minutes!

#### Surveillance du déploiement

```bash
# Suivre le job de création
kubectl logs -n erpnext job/erpnext-create-site -f

# Vérifier tous les pods
kubectl get pods -n erpnext -o wide

# Vérifier l'ingress
kubectl describe ingress -n erpnext erpnext

# Vérifier les secrets
kubectl get secrets -n erpnext
```

---

## Vérifications

### MariaDB Galera

```bash
# État du cluster
mysql -u root -p -e "
SHOW STATUS LIKE 'wsrep_cluster_size';
SHOW STATUS LIKE 'wsrep_cluster_status';
SHOW STATUS LIKE 'wsrep_ready';
SHOW STATUS LIKE 'wsrep_local_state_comment';
"

# Tester l'écriture et la réplication
# Sur DB01
mysql -u root -p -e "
USE erpnext;
CREATE TABLE test_replication (id INT PRIMARY KEY, data VARCHAR(100));
INSERT INTO test_replication VALUES (1, 'Test from DB01');
"

# Sur DB02 (vérifier que la donnée est répliquée)
mysql -u root -p -e "SELECT * FROM erpnext.test_replication;"

# Nettoyage
mysql -u root -p -e "DROP TABLE erpnext.test_replication;"

# Vérifier les métriques Prometheus
curl http://10.0.0.101:9104/metrics | grep mysql_up
```

### ProxySQL

```bash
# Statistiques de connexion
mysql -h 10.0.0.104 -P 6032 -uadmin -p -e "
SELECT * FROM stats_mysql_connection_pool;
"

# Query rules actives
mysql -h 10.0.0.104 -P 6032 -uadmin -p -e "
SELECT * FROM stats_mysql_query_rules;
"

# Queries executées
mysql -h 10.0.0.104 -P 6032 -uadmin -p -e "
SELECT * FROM stats_mysql_commands_counters;
"

# Test read/write split
# SELECT devrait aller sur hostgroup 20 (readers)
mysql -h 10.0.0.10 -P 6033 -uerpnext -p erpnext -e "SELECT 1;"

# INSERT devrait aller sur hostgroup 10 (writers)
mysql -h 10.0.0.10 -P 6033 -uerpnext -p erpnext -e "
CREATE TABLE test_split (id INT);
INSERT INTO test_split VALUES (1);
DROP TABLE test_split;
"
```

### Hetzner Load Balancer

```bash
# Test de connexion via LB
for i in {1..20}; do
  echo -n "Request $i: "
  mysql -h 10.0.0.10 -P 6033 -uerpnext -p'PASSWORD' erpnext \
    -e "SELECT 'Connected' AS status;" 2>/dev/null | grep Connected
  sleep 0.5
done
```

**Via l'interface Hetzner Cloud**:
- Vérifier les health checks (doivent être verts)
- Vérifier les métriques de trafic
- Vérifier que les 2 backends sont actifs

### ERPNext

```bash
# État des pods
kubectl get pods -n erpnext

# Tous les pods doivent être Running et Ready

# Logs backend
kubectl logs -n erpnext -l app.kubernetes.io/component=backend --tail=50

# Logs socketio (si CrashLoopBackOff précédemment)
kubectl logs -n erpnext -l app.kubernetes.io/component=socketio --tail=50

# Connexion depuis un pod
kubectl exec -n erpnext -it deployment/erpnext-backend -- bash

# Depuis le pod:
bench --site erp.keybuzz.local console
# Puis en Python:
# import frappe
# print(frappe.db.get_value("User", "Administrator", "email"))
```

**Accès web**:
1. Ouvrir https://erp.keybuzz.local (ou votre domaine)
2. Login: `Administrator`
3. Password: (voir `/opt/keybuzz/erpnext/credentials_erpnext.txt`)

---

## Maintenance

### Backup MariaDB

#### Backup avec mariadb-backup

```bash
#!/bin/bash
# Script de backup MariaDB Galera
# /opt/keybuzz/scripts/backup_mariadb.sh

BACKUP_DIR="/opt/keybuzz/mariadb/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="mariadb_backup_$DATE"

mkdir -p "$BACKUP_DIR/$BACKUP_NAME"

mariadb-backup --backup \
  --target-dir="$BACKUP_DIR/$BACKUP_NAME" \
  --user=root \
  --password='ROOT_PASSWORD'

# Préparer le backup
mariadb-backup --prepare \
  --target-dir="$BACKUP_DIR/$BACKUP_NAME"

echo "Backup terminé: $BACKUP_DIR/$BACKUP_NAME"

# Compression
tar -czf "$BACKUP_DIR/$BACKUP_NAME.tar.gz" \
  -C "$BACKUP_DIR" "$BACKUP_NAME"

rm -rf "$BACKUP_DIR/$BACKUP_NAME"

# Rotation (garder 7 jours)
find "$BACKUP_DIR" -name "mariadb_backup_*.tar.gz" -mtime +7 -delete
```

#### Restoration

```bash
# Arrêter MariaDB
systemctl stop mariadb

# Nettoyer le datadir
rm -rf /opt/keybuzz/mariadb/data/*

# Extraire le backup
tar -xzf /opt/keybuzz/mariadb/backups/mariadb_backup_XXXXXX.tar.gz \
  -C /opt/keybuzz/mariadb/backups/

# Copier les données
mariadb-backup --copy-back \
  --target-dir=/opt/keybuzz/mariadb/backups/mariadb_backup_XXXXXX

# Permissions
chown -R mysql:mysql /opt/keybuzz/mariadb/data

# Redémarrer (en bootstrap si c'est le 1er noeud)
galera_new_cluster
# ou
systemctl start mariadb
```

### Mise à jour MariaDB

⚠️ **Procédure rolling update** (sans downtime):

```bash
# 1. Sur DB03 (noeud 3)
systemctl stop mariadb
apt-get update
apt-get install --only-upgrade mariadb-server
systemctl start mariadb
# Attendre que le noeud rejoigne le cluster (wsrep_local_state_comment: Synced)

# 2. Sur DB02 (noeud 2)
systemctl stop mariadb
apt-get update
apt-get install --only-upgrade mariadb-server
systemctl start mariadb
# Attendre sync

# 3. Sur DB01 (noeud 1 - bootstrap)
systemctl stop mariadb
apt-get update
apt-get install --only-upgrade mariadb-server
systemctl start mariadb
```

### Mise à jour ProxySQL

```bash
# Mise à jour PROXY02 en premier
ssh root@10.0.0.105
apt-get update
apt-get install --only-upgrade proxysql
systemctl restart proxysql

# Vérifier que le LB bascule tout sur PROXY01

# Mise à jour PROXY01
ssh root@10.0.0.104
apt-get update
apt-get install --only-upgrade proxysql
systemctl restart proxysql
```

### Mise à jour ERPNext

```bash
# Mise à jour de l'image Docker

# 1. Changer la version dans le script ou manuellement
export NEW_VERSION="v15.1.0"

# 2. Update des deployments
kubectl set image deployment/erpnext-backend \
  backend=frappe/erpnext:$NEW_VERSION -n erpnext

kubectl set image deployment/erpnext-frontend \
  nginx=frappe/erpnext:$NEW_VERSION -n erpnext

kubectl set image deployment/erpnext-scheduler \
  scheduler=frappe/erpnext:$NEW_VERSION -n erpnext

kubectl set image deployment/erpnext-worker-default \
  worker=frappe/erpnext:$NEW_VERSION -n erpnext

kubectl set image deployment/erpnext-worker-short \
  worker=frappe/erpnext:$NEW_VERSION -n erpnext

kubectl set image deployment/erpnext-worker-long \
  worker=frappe/erpnext:$NEW_VERSION -n erpnext

kubectl set image deployment/erpnext-socketio \
  socketio=frappe/erpnext:$NEW_VERSION -n erpnext

# 3. Exécuter les migrations
kubectl exec -n erpnext -it deployment/erpnext-backend -- bash
bench --site erp.keybuzz.local migrate
bench --site erp.keybuzz.local build
```

---

## Troubleshooting

### MariaDB Galera

#### Problème: Nœud ne rejoint pas le cluster

**Symptômes**:
```
wsrep_cluster_size: 1
wsrep_cluster_status: non-Primary
```

**Diagnostic**:
```bash
# Vérifier les logs
tail -f /opt/keybuzz/mariadb/logs/mariadb_error.log

# Vérifier la connectivité Galera
nc -vz 10.0.0.101 4567
nc -vz 10.0.0.102 4567
nc -vz 10.0.0.103 4567

# Vérifier UFW
ufw status verbose
```

**Solution**:
```bash
# Si le cluster est completement down, re-bootstrap
# Sur DB01
systemctl stop mariadb
galera_new_cluster

# Sur DB02 et DB03
systemctl start mariadb
```

#### Problème: Split brain (2 clusters séparés)

**Symptômes**:
- 2 nœuds affichent `wsrep_cluster_size: 2`
- 1 nœud affiche `wsrep_cluster_size: 1`

**Solution**:
```bash
# Arrêter TOUS les nœuds
systemctl stop mariadb  # sur DB01, DB02, DB03

# Identifier le nœud le plus à jour
cat /opt/keybuzz/mariadb/data/grastate.dat
# Regarder "seqno" - prendre le plus élevé

# Bootstrap le nœud le plus à jour (ex: DB01)
galera_new_cluster

# Démarrer les autres
systemctl start mariadb  # sur DB02, DB03
```

#### Problème: SST échoue

**Symptômes**:
```
SST failed, node will be removed from cluster
```

**Diagnostic**:
```bash
# Vérifier que xtrabackup est installé
which xtrabackup

# Vérifier les credentials SST
mysql -u sst_user -p -e "SELECT 1;"

# Vérifier le port 4444
nc -vz 10.0.0.101 4444
```

**Solution**:
```bash
# Forcer un nouveau SST
systemctl stop mariadb
rm -rf /opt/keybuzz/mariadb/data/*
mysql_install_db --user=mysql --datadir=/opt/keybuzz/mariadb/data
chown -R mysql:mysql /opt/keybuzz/mariadb/data
systemctl start mariadb
```

### ProxySQL

#### Problème: Tous les backends sont DOWN

**Diagnostic**:
```bash
mysql -h 127.0.0.1 -P 6032 -uadmin -p -e "
SELECT * FROM mysql_servers;
SELECT * FROM monitor.mysql_server_ping_log ORDER BY time_start_us DESC LIMIT 10;
"
```

**Causes communes**:
1. Mauvais credentials monitor
2. MariaDB bloque les connexions
3. Réseau

**Solution**:
```bash
# Vérifier le user monitor depuis MariaDB
mysql -h 10.0.0.101 -P 3306 -uproxysql-cluster -p -e "SELECT 1;"

# Reconfigurer le monitor password dans ProxySQL
mysql -h 127.0.0.1 -P 6032 -uadmin -p <<EOF
UPDATE global_variables SET variable_value='NEW_PASSWORD'
WHERE variable_name='mysql-monitor_password';
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
EOF

# Redémarrer ProxySQL
systemctl restart proxysql
```

#### Problème: Queries ne sont pas routées correctement

**Diagnostic**:
```bash
mysql -h 127.0.0.1 -P 6032 -uadmin -p -e "
SELECT * FROM stats_mysql_query_rules;
"
```

**Solution**:
```bash
# Recharger les rules
mysql -h 127.0.0.1 -P 6032 -uadmin -p <<EOF
LOAD MYSQL QUERY RULES FROM CONFIG;
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
EOF
```

### Hetzner Load Balancer

#### Problème: Health checks échouent

**Diagnostic**:
- Vérifier l'interface Hetzner Cloud → Load Balancers → Health
- Rouge = backend down
- Vert = backend up

**Solution**:
```bash
# Vérifier que ProxySQL écoute sur 6033
netstat -tlnp | grep 6033

# Vérifier depuis le réseau privé
mysql -h 10.0.0.104 -P 6033 -uerpnext -p -e "SELECT 1;"

# Si ProxySQL ne répond pas
systemctl restart proxysql
```

### ERPNext

#### Problème: Pod socketio en CrashLoopBackOff

**Diagnostic**:
```bash
kubectl logs -n erpnext -l app.kubernetes.io/component=socketio --tail=100
```

**Causes communes**:
1. Redis socketio non accessible
2. Dépendance Node.js manquante
3. Configuration site incorrecte

**Solutions**:

**A. Redis non accessible**:
```bash
# Vérifier Redis
kubectl get pods -n erpnext -l app=redis-socketio

# Tester la connexion
kubectl exec -n erpnext deployment/erpnext-socketio -- nc -vz redis-socketio 6379
```

**B. Configuration**:
```bash
# Vérifier la config site
kubectl exec -n erpnext -it deployment/erpnext-backend -- bash
cat sites/erp.keybuzz.local/site_config.json

# Doit contenir redis_socketio
```

**C. Redémarrage simple**:
```bash
kubectl delete pod -n erpnext -l app.kubernetes.io/component=socketio
```

#### Problème: ERPNext ne se connecte pas à MariaDB

**Diagnostic**:
```bash
# Logs backend
kubectl logs -n erpnext -l app.kubernetes.io/component=backend --tail=100

# Tester la connexion DB depuis un pod
kubectl exec -n erpnext -it deployment/erpnext-backend -- bash
mysql -h 10.0.0.10 -P 6033 -uerpnext -p erpnext -e "SELECT 1;"
```

**Solution**:
```bash
# Vérifier les secrets
kubectl get secret -n erpnext erpnext-secrets -o yaml

# Recréer les secrets si nécessaire
kubectl delete secret -n erpnext erpnext-secrets
# Puis relancer le script deploy_erpnext_k3s.sh
```

---

## Améliorations vs v1.0

Cette version 2.0 corrige tous les problèmes identifiés dans la version initiale:

### ✅ MariaDB Galera

| Amélioration | v1.0 | v2.0 |
|--------------|------|------|
| Filesystem | Système par défaut | XFS dédié sur `/opt/keybuzz/mariadb/data` |
| SST Method | `rsync` (lent) | `xtrabackup-v2` (rapide, sans lock) |
| UFW | Incomplet | Tous les ports configurés (22, 3306, 4444, 4567 TCP/UDP, 4568, 9104) |
| Monitoring ProxySQL | User manquant | User `proxysql-cluster` créé |
| Privileges ERPNext | `*.*` (too much) | `erpnext.*` (least privilege) |
| pxc_strict_mode | Présent (Percona only) | Retiré (MariaDB standard) |
| mysqld_exporter | Non installé | Installé et configuré |
| Documentation | Basique | Complète avec troubleshooting |

### ✅ ProxySQL

| Amélioration | v1.0 | v2.0 |
|--------------|------|------|
| Monitoring User | `monitor` (generic) | `proxysql-cluster` (spécifique) |
| Load Balancer | Keepalived VIP (complexe) | Hetzner LB (simple, géré) |
| Health Checks | Basiques | Complets avec ping/connect/read_only |
| Query Rules | Simples | Optimisées avec read/write split |
| Credentials | Codés en dur | Générés aléatoirement |
| Documentation | Manquante | Complète avec exemples |

### ✅ ERPNext

| Amélioration | v1.0 | v2.0 |
|--------------|------|------|
| DB Connection | Direct MariaDB | Via Hetzner LB → ProxySQL (HA) |
| Secrets | Inline dans YAML | Kubernetes Secrets |
| Socketio | CrashLoopBackOff | Configuration corrigée |
| PVC | Taille fixe | Configurable, ReadWriteMany |
| Resources | Non définis | Requests/Limits définis |
| Health Checks | Basiques | Readiness + Liveness configurés |
| Ingress | HTTP only | HTTPS avec cert-manager |

### ✅ Général

| Amélioration | v1.0 | v2.0 |
|--------------|------|------|
| Scripts | Manuels, incomplets | Automatisés, interactifs |
| Credentials | En clair | Sauvegardés de façon sécurisée |
| Validation | Manuelle | Automatique avec checks |
| Rollback | Non prévu | Possibilité de rollback |
| Documentation | Absente | README complet 15KB+ |
| Monitoring | Absent | Prometheus ready (mysqld_exporter) |
| Backup | Non documenté | Scripts et procédures |
| Disaster Recovery | Non prévu | Procédures complètes |

---

## Support et Contribution

### Logs et Credentials

Tous les credentials sont sauvegardés dans:
- MariaDB: `/opt/keybuzz/mariadb/credentials_DBxx.txt`
- ProxySQL: `/opt/keybuzz/proxysql/credentials_PROXYxx.txt`
- ERPNext: `/opt/keybuzz/erpnext/credentials_erpnext.txt`

⚠️ **IMPORTANT**: Ces fichiers contiennent des informations sensibles!
- Permissions: 600 (lecture seule par root)
- À sauvegarder dans un gestionnaire de mots de passe
- NE PAS commiter dans Git

### Commandes de debug utiles

```bash
# MariaDB Galera - Vue d'ensemble
mysql -u root -p -e "SHOW STATUS LIKE 'wsrep%';" | grep -E "cluster|ready|connected|local_state"

# ProxySQL - État complet
mysql -h 127.0.0.1 -P 6032 -uadmin -p <<EOF
SELECT 'Connection Pool' AS section;
SELECT * FROM stats_mysql_connection_pool;
SELECT 'Query Rules' AS section;
SELECT * FROM stats_mysql_query_rules;
SELECT 'Commands' AS section;
SELECT * FROM stats_mysql_commands_counters;
EOF

# ERPNext - Vue d'ensemble
kubectl get all -n erpnext
kubectl top pods -n erpnext

# Hetzner LB - Test complet
for i in {1..50}; do
  mysql -h 10.0.0.10 -P 6033 -uerpnext -p'PASSWORD' erpnext \
    -e "SELECT @@hostname, NOW();" 2>/dev/null
  sleep 0.2
done | sort | uniq -c
```

---

**FIN DE LA DOCUMENTATION**

Pour toute question ou problème, se référer à la section [Troubleshooting](#troubleshooting).

Les scripts sont conçus pour être **idempotents** et peuvent être relancés en cas d'échec partiel.
