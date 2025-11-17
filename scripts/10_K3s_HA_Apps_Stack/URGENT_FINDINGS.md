# ⚠️ DÉCOUVERTES URGENTES - Timeout 50s

**Date**: 2025-11-17
**Criticité**: HAUTE

## 🔴 Problème Critique Identifié

### Timeout de 50s - SOURCE IDENTIFIÉE

Le diagnostic révèle que **le timeout de 50s NE VIENT PAS de K3s/Ingress** mais d'un composant **EXTERNE**.

#### Preuves

1. **Test direct NodePort K3s** (bypass tout Load Balancer) :
   ```bash
   curl -H "Host: monitor.keybuzz.io" http://10.0.0.100:31695/
   → HTTP 403 en 0.007s ✅ (réponse instantanée)
   ```

2. **Test via URL publique** (avec Load Balancer) :
   ```bash
   curl https://monitor.keybuzz.io
   → HTTP 504 après EXACTEMENT 50s ❌
   ```

3. **Tous les services timeout à 50s** :
   - monitor.keybuzz.io (Grafana) : 50.061s
   - connect.keybuzz.io (Connect API) : 50.022s
   - erp.keybuzz.io (ERPNext) : 50.055s

**Conclusion** : Il y a un composant entre le client et K3s qui a un timeout configuré à **50 secondes**.

### Composants Suspects (par ordre de probabilité)

#### 1. **HAProxy** (10.0.0.11 et 10.0.0.12) - TRÈS PROBABLE ⚠️
HAProxy est devant les masters K3s et route le trafic HTTPS. La configuration par défaut d'HAProxy a souvent des timeouts à 50s.

**Localisation** : `/etc/haproxy/haproxy.cfg`

**Configuration à vérifier** :
```haproxy
defaults
    timeout connect 5s      # ← Peut être 50s
    timeout client  50s     # ← SUSPECT
    timeout server  50s     # ← SUSPECT
```

**Correction requise** :
```haproxy
defaults
    timeout connect 10s
    timeout client  600s    # ← Augmenter à 10 minutes
    timeout server  600s    # ← Augmenter à 10 minutes
```

**Commandes** :
```bash
# Sur HAProxy 10.0.0.11
sudo nano /etc/haproxy/haproxy.cfg
# Modifier les timeouts
sudo haproxy -c -f /etc/haproxy/haproxy.cfg  # Vérifier config
sudo systemctl reload haproxy

# Sur HAProxy 10.0.0.12 (même chose)
```

#### 2. **Load Balancer Hetzner Cloud** - PROBABLE
Si un Load Balancer Hetzner est configuré devant HAProxy, il peut avoir un timeout par défaut.

**Vérification** :
```bash
# Vérifier si des services K8s utilisent un LB Hetzner
kubectl get svc -A | grep LoadBalancer

# Vérifier annotations Hetzner
kubectl get svc -A -o yaml | grep -A 5 "hetzner"
```

**Correction** : Via interface web Hetzner Cloud ou annotations K8s

#### 3. **Firewall/Proxy Intermédiaire** - POSSIBLE
Un firewall ou proxy entre le client et les serveurs peut avoir un timeout de connexion.

## 🟡 ERPNext Non Déployé

### Découverte

```bash
kubectl get pods -n erpnext
→ No resources found in erpnext namespace.

kubectl get namespaces | grep erp
→ (vide - namespace n'existe pas)
```

**ERPNext n'est PAS déployé** dans le cluster K3s !

### Implications

- Les erreurs ERPNext dans le résumé précédent étaient basées sur des informations incorrectes
- Il faut soit :
  1. Déployer ERPNext
  2. Ou confirmer que ERPNext est déployé ailleurs (VM dédiée ?)
  3. Ou confirmer que erp.keybuzz.io n'est pas encore en production

### Actions Requises

1. **Vérifier si ERPNext existe ailleurs** :
   ```bash
   # Chercher dans tous les namespaces
   kubectl get pods -A | grep -i erp

   # Chercher VM dédiée
   grep -i erp /opt/keybuzz-installer/servers.tsv
   ```

2. **Si ERPNext doit être déployé** : Créer un nouveau ticket/tâche pour déploiement ERPNext

## ✅ Ce Qui Fonctionne

1. **K3s/Ingress NGINX** : Répond instantanément en NodePort (0.007s)
2. **DNS Kubernetes** : Fonctionnel (corrigé précédemment)
3. **Redis** : Accessible et fonctionnel
4. **Format URL Redis** : `redis://default:PASSWORD@host:port/db` ✅

## 📋 Actions Immédiates Requises

### 1. URGENT : Corriger Timeout HAProxy

**Priorité** : P0 (Bloquant)

**Sur HAProxy 10.0.0.11** :
```bash
ssh root@10.0.0.11
sudo nano /etc/haproxy/haproxy.cfg

# Chercher et modifier:
defaults
    timeout connect 10s
    timeout client  600s
    timeout server  600s

# Sauvegarder et vérifier
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl reload haproxy
```

**Sur HAProxy 10.0.0.12** (identique)

**Test après correction** :
```bash
curl -w "Time: %{time_total}s\n" https://monitor.keybuzz.io
# Attendu: < 5s au lieu de 50s
```

### 2. Vérifier Load Balancer Hetzner

**Priorité** : P1

Si un LB Hetzner est utilisé, vérifier sa configuration :
- Timeout par défaut
- Health checks
- Backend timeouts

### 3. Clarifier État ERPNext

**Priorité** : P2

Déterminer :
- ERPNext doit-il être déployé ?
- Est-il sur une VM dédiée ?
- Quel est le statut de erp.keybuzz.io ?

### 4. Exécuter Script de Vérification

**Priorité** : P1

```bash
ssh root@10.0.0.20
cd /opt/keybuzz-installer/KB/scripts/10_K3s_HA_Apps_Stack/
./find_timeout_and_fix.sh
```

Ce script va :
- Confirmer la source du timeout
- Corriger nginx.conf (block 300s)
- Afficher config HAProxy
- Donner instructions précises

## 📊 État Actuel des Services

| Service | K3s Status | URL Status | Notes |
|---------|-----------|------------|-------|
| Grafana | ✅ Running | ⚠️ Timeout 50s | K3s OK, problème HAProxy |
| Connect API | ✅ Running | ⚠️ Timeout 50s | K3s OK, problème HAProxy |
| n8n | ✅ Running | ? | À tester |
| LiteLLM | ✅ Running | ? | À tester |
| Chatwoot | ✅ Running | ? | À tester |
| ERPNext | ❌ Not deployed | ⚠️ Timeout 50s | Non déployé ! |

## 🎯 Résultat Attendu Après Correction HAProxy

Après avoir augmenté les timeouts HAProxy à 600s :

```bash
# Test Grafana
curl -w "Time: %{time_total}s\n" https://monitor.keybuzz.io
→ HTTP 200/302 en < 5s ✅

# Test Connect API
curl -w "Time: %{time_total}s\n" https://connect.keybuzz.io
→ HTTP 200/302 en < 5s ✅
```

Tous les services devraient répondre normalement sans timeout.

## 📞 Prochaines Étapes

1. **MAINTENANT** : Corriger timeouts HAProxy (10 minutes)
2. **Ensuite** : Tester tous les services (5 minutes)
3. **Puis** : Clarifier statut ERPNext (à déterminer)
4. **Enfin** : Déployer applications restantes (Wazuh, MinIO, etc.)

## 📝 Notes Techniques

### Configuration HAProxy Recommandée

```haproxy
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 10s
    timeout client  600s    # 10 minutes
    timeout server  600s    # 10 minutes
    timeout http-request 10s
    timeout http-keep-alive 10s

frontend k3s_ingress_https
    bind *:443 ssl crt /etc/ssl/certs/keybuzz.pem
    mode http
    default_backend k3s_ingress_nodes

backend k3s_ingress_nodes
    mode http
    balance roundrobin
    option httpchk GET /healthz
    http-check expect status 200
    server k3s-master-01 10.0.0.100:31695 check
    server k3s-master-02 10.0.0.101:31695 check
    server k3s-master-03 10.0.0.102:31695 check
    server k3s-worker-01 10.0.0.110:31695 check
    server k3s-worker-02 10.0.0.111:31695 check
```

### Vérifications Post-Correction

```bash
# 1. Vérifier HAProxy actif
sudo systemctl status haproxy

# 2. Vérifier config chargée
sudo haproxy -vv

# 3. Tester backend
curl -H "Host: monitor.keybuzz.io" http://10.0.0.11/

# 4. Logs en temps réel
sudo tail -f /var/log/haproxy.log
```

---

**Ce document sera mis à jour après correction HAProxy.**
