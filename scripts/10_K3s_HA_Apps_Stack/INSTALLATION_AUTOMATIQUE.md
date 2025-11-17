# Installation Automatique MariaDB Galera + ProxySQL + ERPNext

**Version**: 2.1 (Automated)
**Date**: 2025-11-13

---

## 🚀 Installation en 1 seule commande

Cette version permet une installation **100% automatique** de toute la stack depuis le serveur `install-01`, **sans aucune interaction humaine**.

---

## 📋 Prérequis

### Infrastructure

✅ Serveurs déjà provisionnés:
- 3 serveurs MariaDB (DB01, DB02, DB03) - 10.0.0.101-103
- 2 serveurs ProxySQL (PROXY01, PROXY02) - 10.0.0.104-105
- Cluster K3s opérationnel
- Hetzner Load Balancer créé (10.0.0.10)

✅ Volumes déjà montés:
- `/opt/keybuzz/mariadb/data` sur DB01, DB02, DB03
- `/opt/keybuzz/mariadb/logs` sur DB01, DB02, DB03
- `/opt/keybuzz/mariadb/backups` sur DB01, DB02, DB03

✅ Accès SSH:
- Clé SSH configurée dans `~/.ssh/id_rsa` (ou autre chemin défini dans .env)
- Accès root sans mot de passe sur tous les serveurs
- Test: `ssh root@10.0.0.101 "echo OK"`

✅ Réseau:
- Réseau privé Hetzner 10.0.0.0/16 configuré
- Tous les serveurs dans le même réseau privé

---

## 📁 Fichiers d'installation

```
scripts/10_K3s_HA_Apps_Stack/
├── .env.mariadb_proxysql_erpnext       # Configuration centrale (À CONFIGURER)
├── generate_credentials.sh             # Générateur de credentials
├── install_mariadb_galera_auto.sh      # Installation MariaDB (non-interactif)
├── install_proxysql_auto.sh            # Installation ProxySQL (non-interactif)
├── deploy_erpnext_auto.sh              # Déploiement ERPNext (non-interactif)
└── install_all_from_master.sh          # 🎯 SCRIPT MAÎTRE D'ORCHESTRATION
```

---

## 🔧 Configuration

### Étape 1: Configurer le fichier .env

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack/

# Éditer le fichier .env
nano .env.mariadb_proxysql_erpnext
```

**Configuration minimale requise**:

```bash
# TOPOLOGY (vérifier les IPs)
DB01_IP="10.0.0.101"
DB02_IP="10.0.0.102"
DB03_IP="10.0.0.103"
PROXY01_IP="10.0.0.104"
PROXY02_IP="10.0.0.105"
HETZNER_LB_IP="10.0.0.10"

# PATHS (volumes déjà montés)
MARIADB_DATA_DIR="/opt/keybuzz/mariadb/data"
MARIADB_LOG_DIR="/opt/keybuzz/mariadb/logs"
MARIADB_BACKUP_DIR="/opt/keybuzz/mariadb/backups"

# ERPNEXT
ERPNEXT_SITE_NAME="erp.keybuzz.local"  # Adapter votre domaine

# SSH
SSH_USER="root"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"

# OPTIONS
SKIP_XFS_FORMAT="true"  # true si volumes déjà montés et formatés
AUTO_CONFIRM="true"

# CREDENTIALS (laisser vide, seront générés automatiquement)
MYSQL_ROOT_PASSWORD=""
SST_PASSWORD=""
PROXYSQL_MONITOR_PASSWORD=""
ERPNEXT_DB_PASSWORD=""
MYSQLD_EXPORTER_PASSWORD=""
PROXYSQL_ADMIN_PASSWORD=""
ERPNEXT_ADMIN_PASSWORD=""
```

### Étape 2: Vérifier l'accès SSH

```bash
# Tester l'accès à tous les serveurs
for ip in 10.0.0.101 10.0.0.102 10.0.0.103 10.0.0.104 10.0.0.105; do
  echo -n "Test SSH $ip: "
  ssh -o ConnectTimeout=5 root@$ip "echo OK" 2>/dev/null || echo "FAILED"
done
```

**Si échec**: Configurer l'accès SSH sans mot de passe:
```bash
ssh-copy-id root@10.0.0.101
ssh-copy-id root@10.0.0.102
# etc.
```

---

## 🎯 Installation

### Commande unique

```bash
cd /home/user/KB/scripts/10_K3s_HA_Apps_Stack/

./install_all_from_master.sh
```

**C'est tout !** Le script va:

1. ✅ Générer les credentials aléatoires (si vides)
2. ✅ Tester la connectivité SSH vers tous les serveurs
3. ✅ Copier les fichiers sur les serveurs distants
4. ✅ Installer MariaDB Galera sur DB01, DB02, DB03 (parallèle)
5. ✅ Bootstrapper le cluster Galera sur DB01
6. ✅ Démarrer DB02 et DB03
7. ✅ Vérifier le cluster (3 nœuds)
8. ✅ Installer ProxySQL sur PROXY01, PROXY02 (parallèle)
9. ✅ Vérifier les backends ProxySQL
10. ✅ Tester le Hetzner Load Balancer
11. ✅ Déployer ERPNext sur K3s
12. ✅ Afficher le résumé avec tous les credentials

---

## ⏱️ Durée d'installation

| Étape | Durée estimée |
|-------|---------------|
| Génération credentials | 5 secondes |
| Test SSH | 10 secondes |
| Copie fichiers | 15 secondes |
| Installation MariaDB (3 nœuds parallèle) | 10-15 minutes |
| Bootstrap cluster | 2 minutes |
| Installation ProxySQL (2 nœuds parallèle) | 5 minutes |
| Déploiement ERPNext | 10-15 minutes |
| **TOTAL** | **30-40 minutes** |

---

## 📊 Suivi de l'installation

Le script affiche en temps réel:
- ✅ Étapes terminées (vert)
- ⚠️  Avertissements (jaune)
- ✗ Erreurs (rouge)
- ℹ️  Informations (cyan)

Exemple de sortie:

```
[2025-11-13 21:00:00] ℹ️  Début de l'orchestration complète...
[2025-11-13 21:00:05] ✓ Credentials générés
[2025-11-13 21:00:15] ✓ Tous les serveurs accessibles
[2025-11-13 21:00:30] ✓ Fichiers copiés sur tous les serveurs
[2025-11-13 21:01:00]   Lancement installation sur DB01...
[2025-11-13 21:01:00]   Lancement installation sur DB02...
[2025-11-13 21:01:00]   Lancement installation sur DB03...
[2025-11-13 21:15:00] ✓ MariaDB installé sur les 3 nœuds
[2025-11-13 21:15:05] ✓ DB01 bootstrappé
[2025-11-13 21:16:00] ✓ Cluster Galera opérationnel (3 nœuds)
...
```

---

## 🔍 Vérifications post-installation

### MariaDB Galera

```bash
# Depuis install-01
ssh root@10.0.0.101 "mysql -u root -p'<PASSWORD>' -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\""
# Doit afficher: 3

ssh root@10.0.0.101 "mysql -u root -p'<PASSWORD>' -e \"SHOW STATUS LIKE 'wsrep_local_state_comment';\""
# Doit afficher: Synced
```

### ProxySQL

```bash
# Backends MariaDB
ssh root@10.0.0.104 "mysql -h 127.0.0.1 -P 6032 -uadmin -p'<PASSWORD>' \
  -e 'SELECT hostgroup_id, hostname, port, status FROM mysql_servers;'"
# Doit afficher 6 lignes (3 writers + 3 readers)
```

### Hetzner Load Balancer

```bash
# Test connexion via LB
ssh root@10.0.0.101 "mysql -h 10.0.0.10 -P 6033 -uerpnext -p'<PASSWORD>' erpnext -e 'SELECT 1;'"
# Doit retourner: 1
```

### ERPNext

```bash
# Depuis install-01
kubectl get pods -n erpnext
# Tous les pods doivent être Running

# Accès web
curl -k https://erp.keybuzz.local
# Doit retourner la page de login ERPNext
```

---

## 📁 Récupération des credentials

Après installation, les credentials sont sauvegardés sur chaque serveur:

### MariaDB

```bash
# Sur DB01
ssh root@10.0.0.101 "cat /opt/keybuzz/mariadb/credentials_DB01.sh"

# Sur DB02
ssh root@10.0.0.102 "cat /opt/keybuzz/mariadb/credentials_DB02.sh"

# Sur DB03
ssh root@10.0.0.103 "cat /opt/keybuzz/mariadb/credentials_DB03.sh"
```

### ProxySQL

```bash
# Sur PROXY01
ssh root@10.0.0.104 "cat /opt/keybuzz/proxysql/credentials_PROXY01.sh"

# Sur PROXY02
ssh root@10.0.0.105 "cat /opt/keybuzz/proxysql/credentials_PROXY02.sh"
```

### ERPNext

```bash
# Sur install-01
cat /opt/keybuzz/erpnext/credentials_erpnext.sh
```

**Format des fichiers de credentials**: Scripts bash sourcables

```bash
# Exemple: credentials_DB01.sh
export MYSQL_ROOT_PASSWORD="xxxxxxxxx"
export SST_PASSWORD="xxxxxxxxx"
export PROXYSQL_MONITOR_PASSWORD="xxxxxxxxx"
export ERPNEXT_DB_PASSWORD="xxxxxxxxx"
# etc.
```

**Utilisation**:

```bash
# Sourcer le fichier
source /opt/keybuzz/mariadb/credentials_DB01.sh

# Utiliser les variables
mysql -u root -p"$MYSQL_ROOT_PASSWORD"
```

---

## 🔒 Sécurité

⚠️ **IMPORTANT**:

1. **Fichier .env**: Contient tous les credentials
   - Permissions: `chmod 600 .env.mariadb_proxysql_erpnext`
   - **NE JAMAIS commiter dans Git**
   - Sauvegarder dans un gestionnaire de mots de passe

2. **Credentials sur serveurs**: Permissions 600 (lecture root uniquement)

3. **Backup**: Copier le `.env` dans un endroit sûr:
   ```bash
   cp .env.mariadb_proxysql_erpnext ~/credentials_backup_$(date +%Y%m%d).env
   chmod 600 ~/credentials_backup_*.env
   ```

---

## 🛠️ Troubleshooting

### Erreur: "Serveurs non accessibles via SSH"

```bash
# Vérifier les clés SSH
ssh-add -l

# Tester manuellement
ssh -vvv root@10.0.0.101
```

**Solution**: Configurer l'accès SSH sans mot de passe

### Erreur: "Cluster Galera size != 3"

```bash
# Vérifier les logs sur chaque nœud
ssh root@10.0.0.101 "tail -f /opt/keybuzz/mariadb/logs/mariadb_error.log"
```

**Solution**: Vérifier la connectivité réseau entre DB01, DB02, DB03 (port 4567)

### Erreur: "ProxySQL backends DOWN"

```bash
# Vérifier les credentials monitor
ssh root@10.0.0.101 "mysql -u proxysql-cluster -p'<PASSWORD>' -e 'SELECT 1;'"
```

**Solution**: Reconfigurer le mot de passe monitor dans le `.env` et relancer

### Erreur: "ERPNext pods CrashLoopBackOff"

```bash
# Voir les logs du pod
kubectl logs -n erpnext <pod-name>

# Vérifier la connexion DB
kubectl exec -n erpnext deployment/erpnext-backend -- \
  mysql -h 10.0.0.10 -P 6033 -uerpnext -p'<PASSWORD>' erpnext -e "SELECT 1;"
```

---

## 🔄 Réinstallation

Pour réinstaller complètement:

1. **Nettoyer les serveurs**:
   ```bash
   # Sur chaque serveur MariaDB
   systemctl stop mariadb mysqld_exporter
   rm -rf /opt/keybuzz/mariadb/data/*

   # Sur chaque serveur ProxySQL
   systemctl stop proxysql
   rm -rf /var/lib/proxysql/*
   ```

2. **Nettoyer K3s**:
   ```bash
   kubectl delete namespace erpnext
   ```

3. **Relancer l'installation**:
   ```bash
   ./install_all_from_master.sh
   ```

---

## 📞 Support

### Logs d'installation

Tous les logs sont disponibles sur les serveurs:

- MariaDB: `/opt/keybuzz/mariadb/logs/mariadb_error.log`
- ProxySQL: `/var/lib/proxysql/proxysql.log`
- ERPNext: `kubectl logs -n erpnext <pod-name>`

### Commandes utiles

```bash
# État complet du cluster Galera
for host in 10.0.0.101 10.0.0.102 10.0.0.103; do
  echo "=== $host ==="
  ssh root@$host "mysql -u root -p'<PASSWORD>' \
    -e \"SHOW STATUS LIKE 'wsrep%';\" | grep -E '(cluster|ready|connected|state)'"
done

# État ProxySQL
ssh root@10.0.0.104 "mysql -h 127.0.0.1 -P 6032 -uadmin -p'<PASSWORD>' \
  -e 'SELECT * FROM stats_mysql_connection_pool;'"

# État ERPNext
kubectl get all -n erpnext
kubectl top pods -n erpnext
```

---

## ✅ Checklist finale

Après installation, vérifier:

- [ ] MariaDB Galera: `wsrep_cluster_size = 3`
- [ ] MariaDB Galera: `wsrep_local_state_comment = Synced` sur chaque nœud
- [ ] ProxySQL: 6 backends configurés (3 writers + 3 readers)
- [ ] ProxySQL: Health checks verts
- [ ] Hetzner LB: Connexion réussie via 10.0.0.10:6033
- [ ] ERPNext: Tous les pods Running
- [ ] ERPNext: Site accessible via HTTPS
- [ ] Credentials sauvegardés dans un endroit sûr
- [ ] Backup du fichier `.env` effectué

---

**Bonne installation !** 🚀

Pour plus de détails, voir:
- `README_MARIADB_PROXYSQL_ERPNEXT.md` (documentation complète)
- `QUICK_START_MARIADB_PROXYSQL_ERPNEXT.md` (guide rapide)
