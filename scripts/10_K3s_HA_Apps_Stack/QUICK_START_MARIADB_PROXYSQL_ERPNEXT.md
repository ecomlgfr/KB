# Quick Start - Installation MariaDB Galera + ProxySQL + ERPNext

**Version**: 2.0 KeyBuzz Standards
**Date**: 2025-11-13

---

## 📁 Fichiers créés

```
scripts/10_K3s_HA_Apps_Stack/
├── install_mariadb_galera_keybuzz.sh    (21K) ✅ Exécutable
├── install_proxysql_keybuzz.sh          (18K) ✅ Exécutable
├── deploy_erpnext_k3s.sh                (28K) ✅ Exécutable
├── README_MARIADB_PROXYSQL_ERPNEXT.md   (27K) 📖 Documentation complète
└── QUICK_START_MARIADB_PROXYSQL_ERPNEXT.md (ce fichier)
```

---

## 🚀 Installation en 4 étapes

### Étape 1: MariaDB Galera (3 serveurs)

```bash
# Sur DB01 (10.0.0.101)
./install_mariadb_galera_keybuzz.sh
# Suivre les instructions → Choisir le disque pour XFS
# NE PAS démarrer MariaDB!

# Sur DB02 (10.0.0.102)
./install_mariadb_galera_keybuzz.sh
# NE PAS démarrer MariaDB!

# Sur DB03 (10.0.0.103)
./install_mariadb_galera_keybuzz.sh
# NE PAS démarrer MariaDB!

# Bootstrap le cluster (DB01 uniquement)
ssh root@10.0.0.101
galera_new_cluster
systemctl start mysqld_exporter

# Démarrer les autres nœuds
ssh root@10.0.0.102 "systemctl start mariadb mysqld_exporter"
ssh root@10.0.0.103 "systemctl start mariadb mysqld_exporter"

# Vérifier le cluster (doit afficher: 3)
mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

**✅ Résultat attendu**: 3 nœuds MariaDB en cluster synchrone

---

### Étape 2: ProxySQL (2 serveurs)

```bash
# Sur PROXY01 (10.0.0.104)
./install_proxysql_keybuzz.sh
# Entrer les credentials depuis /opt/keybuzz/mariadb/credentials_DB01.txt:
# - proxysql-cluster password
# - erpnext password

# Sur PROXY02 (10.0.0.105)
./install_proxysql_keybuzz.sh
# Mêmes credentials

# Vérifier ProxySQL
mysql -h 10.0.0.104 -P 6032 -uadmin -p'ADMIN_PASSWORD'
SELECT * FROM mysql_servers;
# Doit afficher les 3 backends MariaDB
```

**✅ Résultat attendu**: 2 ProxySQL avec 3 backends configurés

---

### Étape 3: Hetzner Load Balancer

**Via l'interface Hetzner Cloud**:

1. Créer un Load Balancer:
   - Type: LB11
   - Réseau: Réseau privé 10.0.0.0/16
   - IP: 10.0.0.10

2. Service:
   - Protocol: TCP
   - Port: 6033

3. Targets:
   - 10.0.0.104:6033 (PROXY01)
   - 10.0.0.105:6033 (PROXY02)

4. Health Check:
   - Protocol: TCP Port 6033

**Test**:
```bash
mysql -h 10.0.0.10 -P 6033 -uerpnext -p'ERPNEXT_PASSWORD' erpnext -e "SELECT 1;"
```

**✅ Résultat attendu**: Connexion réussie via le LB

---

### Étape 4: ERPNext sur K3s

```bash
# Sur un master K3s
./deploy_erpnext_k3s.sh

# Entrer les informations:
# - Database Password (erpnext)
# - Database Root Password
# - Site Name (ex: erp.keybuzz.local)

# Le script va:
# 1. Créer le namespace erpnext
# 2. Déployer Redis (3 instances)
# 3. Créer le site ERPNext (5-10 min)
# 4. Déployer tous les composants
# 5. Configurer l'Ingress

# Surveiller le déploiement
kubectl get pods -n erpnext -w

# Vérifier l'accès
curl -k https://erp.keybuzz.local
```

**✅ Résultat attendu**: ERPNext accessible via HTTPS

---

## 📊 Vérifications rapides

### MariaDB Galera
```bash
# Cluster size (doit être 3)
mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"

# État (doit être Synced)
mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

### ProxySQL
```bash
# Backends (doit afficher 6 lignes: 3 writers + 3 readers)
mysql -h 10.0.0.104 -P 6032 -uadmin -p -e "SELECT * FROM mysql_servers;"

# Health checks
mysql -h 10.0.0.104 -P 6032 -uadmin -p -e "SELECT * FROM stats_mysql_connection_pool;"
```

### Hetzner LB
```bash
# Test rotation (doit alterner entre PROXY01 et PROXY02)
for i in {1..10}; do
  mysql -h 10.0.0.10 -P 6033 -uerpnext -p'PASSWORD' erpnext -e "SELECT 1;" 2>/dev/null
  sleep 0.5
done
```

### ERPNext
```bash
# Tous les pods Running
kubectl get pods -n erpnext

# Accès web
curl -k https://erp.keybuzz.local
# Login: Administrator
# Password: voir /opt/keybuzz/erpnext/credentials_erpnext.txt
```

---

## 🔐 Fichiers de credentials

Après chaque installation, les credentials sont sauvegardés:

| Composant | Fichier |
|-----------|---------|
| MariaDB DB01 | `/opt/keybuzz/mariadb/credentials_DB01.txt` |
| MariaDB DB02 | `/opt/keybuzz/mariadb/credentials_DB02.txt` |
| MariaDB DB03 | `/opt/keybuzz/mariadb/credentials_DB03.txt` |
| ProxySQL 01 | `/opt/keybuzz/proxysql/credentials_PROXY01.txt` |
| ProxySQL 02 | `/opt/keybuzz/proxysql/credentials_PROXY02.txt` |
| ERPNext | `/opt/keybuzz/erpnext/credentials_erpnext.txt` |

**⚠️ IMPORTANT**:
- Permissions: 600 (lecture seule par root)
- À copier dans un gestionnaire de mots de passe sécurisé
- NE JAMAIS commiter dans Git

---

## ⏱️ Temps d'installation estimé

| Étape | Durée | Note |
|-------|-------|------|
| MariaDB Galera (3 serveurs) | 30 min | Incluant formatage XFS |
| ProxySQL (2 serveurs) | 10 min | Installation simple |
| Hetzner LB | 5 min | Via interface web |
| ERPNext sur K3s | 20 min | Job création site = 5-10 min |
| **TOTAL** | **~65 min** | Installation complète |

---

## 📚 Documentation complète

Pour plus de détails, voir: **README_MARIADB_PROXYSQL_ERPNEXT.md**

Sections disponibles:
- Architecture détaillée
- Procédures de backup
- Mise à jour (rolling update)
- Troubleshooting complet
- Disaster recovery
- Monitoring Prometheus

---

## 🆕 Améliorations vs ancienne version

Cette version 2.0 corrige **TOUS** les problèmes de la v1.0:

✅ XFS filesystem dédié (au lieu du système par défaut)
✅ SST `xtrabackup-v2` (au lieu de `rsync`)
✅ UFW correctement configuré (tous les ports Galera)
✅ User `proxysql-cluster` créé (au lieu de manquant)
✅ Privileges `erpnext.*` uniquement (au lieu de `*.*`)
✅ `pxc_strict_mode` retiré (Percona-specific)
✅ `mysqld_exporter` installé (Prometheus monitoring)
✅ Hetzner LB (au lieu de Keepalived VIP)
✅ Secrets Kubernetes (au lieu de inline)
✅ ERPNext socketio corrigé (plus de CrashLoopBackOff)
✅ Documentation complète (27KB de docs)

---

## 💡 Conseils

1. **Toujours commencer par DB01** lors du bootstrap
2. **Attendre que chaque nœud soit Synced** avant de passer au suivant
3. **Tester le LB** avant de déployer ERPNext
4. **Sauvegarder les credentials** immédiatement après installation
5. **Activer les backups automatiques** dès que possible

---

## 🆘 Aide rapide

### MariaDB ne démarre pas
```bash
journalctl -u mariadb -n 50 --no-pager
tail -f /opt/keybuzz/mariadb/logs/mariadb_error.log
```

### ProxySQL backends DOWN
```bash
mysql -h 127.0.0.1 -P 6032 -uadmin -p
SELECT * FROM monitor.mysql_server_ping_log ORDER BY time_start_us DESC LIMIT 10;
```

### ERPNext pods CrashLoopBackOff
```bash
kubectl describe pod -n erpnext <pod-name>
kubectl logs -n erpnext <pod-name> --previous
```

### Hetzner LB health checks rouges
```bash
# Vérifier que ProxySQL écoute
netstat -tlnp | grep 6033

# Tester la connexion
mysql -h 10.0.0.104 -P 6033 -uerpnext -p -e "SELECT 1;"
```

---

**Bonne installation!** 🚀

Pour toute question, consulter: `README_MARIADB_PROXYSQL_ERPNEXT.md`
