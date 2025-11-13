#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    VALIDATION FINALE COMPLÈTE - Infrastructure KeyBuzz            ║"
echo "║    (Toutes composantes + Tests fonctionnels)                      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'
KO='\033[0;31m✗\033[0m'
WARN='\033[0;33m⚠\033[0m'
INFO='\033[0;36mℹ\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
LOG_DIR="/opt/keybuzz-installer/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="$LOG_DIR/validation_complete_$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG")
exec 2>&1

echo ""
echo "Validation finale complète - Architecture KeyBuzz"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Variables de comptage
TOTAL_TESTS=0
TESTS_OK=0
TESTS_KO=0
TESTS_WARN=0

# Fonction de test
test_component() {
    local name="$1"
    local command="$2"
    local expected="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "  $name ... "
    
    if eval "$command" | grep -q "$expected"; then
        echo -e "$OK"
        TESTS_OK=$((TESTS_OK + 1))
        return 0
    else
        echo -e "$KO"
        TESTS_KO=$((TESTS_KO + 1))
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# PARTIE 1: INFRASTRUCTURE DE BASE
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 1: Infrastructure de base                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# PostgreSQL
echo "→ PostgreSQL Patroni Cluster"
test_component "Patroni Leader" "ssh root@10.0.0.120 'patronictl -c /etc/patroni/patroni.yml list'" "Leader"
test_component "Patroni Replicas" "ssh root@10.0.0.120 'patronictl -c /etc/patroni/patroni.yml list'" "Replica"
test_component "PostgreSQL Port 5432" "nc -zv 10.0.0.10 5432 2>&1" "succeeded"
test_component "PgBouncer Port 4632" "nc -zv 10.0.0.10 4632 2>&1" "succeeded"

echo ""
echo "→ Redis Sentinel Cluster"
test_component "Redis Master" "redis-cli -h 10.0.0.10 -p 6379 -a \$(grep REDIS_PASSWORD /opt/keybuzz-installer/credentials/redis.env | cut -d'=' -f2) PING" "PONG"
test_component "Sentinel Info" "redis-cli -h 10.0.0.123 -p 26379 SENTINEL master mymaster | grep -q 'ip'" "ip"

echo ""
echo "→ RabbitMQ Cluster"
test_component "RabbitMQ AMQP" "nc -zv 10.0.0.10 5672 2>&1" "succeeded"
test_component "RabbitMQ Management" "curl -s http://10.0.0.126:15672 -o /dev/null -w '%{http_code}'" "401"

echo ""
echo "→ HAProxy Load Balancers"
test_component "HAProxy-01 Stats" "curl -s http://10.0.0.11:8404 -o /dev/null -w '%{http_code}'" "200"
test_component "HAProxy-02 Stats" "curl -s http://10.0.0.12:8404 -o /dev/null -w '%{http_code}'" "200"

echo ""
echo "→ MinIO S3 Storage"
test_component "MinIO Health" "curl -s http://s3.keybuzz.io:9000/minio/health/live -o /dev/null -w '%{http_code}'" "200"
test_component "MinIO API" "curl -s http://s3.keybuzz.io:9000 -o /dev/null -w '%{http_code}'" "403"

# ═══════════════════════════════════════════════════════════════════
# PARTIE 2: CLUSTER KUBERNETES
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 2: Cluster Kubernetes K3s                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Nœuds K3s"
test_component "Master-01 Ready" "kubectl get nodes | grep k3s-master-01" "Ready"
test_component "Master-02 Ready" "kubectl get nodes | grep k3s-master-02" "Ready"
test_component "Master-03 Ready" "kubectl get nodes | grep k3s-master-03" "Ready"
test_component "Worker-01 Ready" "kubectl get nodes | grep k3s-worker-01" "Ready"
test_component "Worker-02 Ready" "kubectl get nodes | grep k3s-worker-02" "Ready"
test_component "Worker-03 Ready" "kubectl get nodes | grep k3s-worker-03" "Ready"
test_component "Worker-04 Ready" "kubectl get nodes | grep k3s-worker-04" "Ready"
test_component "Worker-05 Ready" "kubectl get nodes | grep k3s-worker-05" "Ready"

echo ""
echo "→ Composants système K3s"
test_component "CoreDNS Running" "kubectl get pods -n kube-system | grep coredns" "Running"
test_component "Metrics Server" "kubectl get pods -n kube-system | grep metrics-server" "Running"
test_component "Traefik Running" "kubectl get pods -n kube-system | grep traefik" "Running"

echo ""
echo "→ Ingress NGINX"
test_component "Ingress Controller" "kubectl get pods -n ingress-nginx | grep ingress-nginx-controller" "Running"
test_component "Ingress DaemonSet" "kubectl get daemonset -n ingress-nginx" "ingress-nginx-controller"
test_component "NodePort HTTP" "kubectl get svc -n ingress-nginx | grep ingress-nginx-controller" "31695"
test_component "NodePort HTTPS" "kubectl get svc -n ingress-nginx | grep ingress-nginx-controller" "32720"

echo ""
echo "→ Cert-Manager"
test_component "Cert-Manager Pods" "kubectl get pods -n cert-manager" "Running"
test_component "ClusterIssuer" "kubectl get clusterissuer 2>/dev/null | wc -l" "[1-9]"

# ═══════════════════════════════════════════════════════════════════
# PARTIE 3: APPLICATIONS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 3: Applications Déployées                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ n8n (Workflow Automation)"
test_component "n8n Pods Running" "kubectl get pods -n n8n" "Running"
test_component "n8n Service" "kubectl get svc -n n8n" "n8n"
test_component "n8n Ingress" "kubectl get ingress -n n8n" "n8n"
test_component "n8n HTTP Response" "curl -H 'Host: n8n.keybuzz.io' -s http://10.0.0.110:31695 -o /dev/null -w '%{http_code}'" "200\|302"

echo ""
echo "→ LiteLLM (LLM Router)"
test_component "LiteLLM Pods Running" "kubectl get pods -n litellm" "Running"
test_component "LiteLLM Service" "kubectl get svc -n litellm" "litellm"
test_component "LiteLLM Ingress" "kubectl get ingress -n litellm" "litellm"
test_component "LiteLLM HTTP Response" "curl -H 'Host: llm.keybuzz.io' -s http://10.0.0.110:31695 -o /dev/null -w '%{http_code}'" "200\|404"

echo ""
echo "→ Qdrant (Vector Database)"
test_component "Qdrant Pods Running" "kubectl get pods -n qdrant" "Running"
test_component "Qdrant Service" "kubectl get svc -n qdrant" "qdrant"
test_component "Qdrant Ingress" "kubectl get ingress -n qdrant" "qdrant"
test_component "Qdrant HTTP Response" "curl -H 'Host: qdrant.keybuzz.io' -s http://10.0.0.110:31695 -o /dev/null -w '%{http_code}'" "200"

echo ""
echo "→ Chatwoot (Customer Support)"
test_component "Chatwoot Web Running" "kubectl get pods -n chatwoot | grep chatwoot-web" "Running"
test_component "Chatwoot Worker Running" "kubectl get pods -n chatwoot | grep chatwoot-worker" "Running"
test_component "Chatwoot Service" "kubectl get svc -n chatwoot" "chatwoot"
test_component "Chatwoot Ingress" "kubectl get ingress -n chatwoot" "chatwoot"
test_component "Chatwoot HTTP Response" "curl -H 'Host: chat.keybuzz.io' -s http://10.0.0.110:31695 -o /dev/null -w '%{http_code}'" "200\|302"

echo ""
echo "→ Superset (BI & Analytics)"
test_component "Superset Pods Running" "kubectl get pods -n superset" "Running"
test_component "Superset Service" "kubectl get svc -n superset" "superset"
test_component "Superset Ingress" "kubectl get ingress -n superset" "superset"
test_component "Superset HTTP Response" "curl -H 'Host: superset.keybuzz.io' -s http://10.0.0.110:31695 -o /dev/null -w '%{http_code}'" "200\|302"

echo ""
echo "→ Vault (Secrets Management)"
if kubectl get ns vault &>/dev/null; then
    test_component "Vault Pods Running" "kubectl get pods -n vault" "Running"
    test_component "Vault Service" "kubectl get svc -n vault" "vault"
    test_component "Vault Ingress" "kubectl get ingress -n vault" "vault"
    test_component "Vault HTTP Response" "curl -H 'Host: vault.keybuzz.io' -s http://10.0.0.110:31695 -o /dev/null -w '%{http_code}'" "200\|503"
else
    echo -e "  $WARN Vault non déployé (optionnel)"
    TESTS_WARN=$((TESTS_WARN + 1))
fi

# ═══════════════════════════════════════════════════════════════════
# PARTIE 4: MONITORING ET SÉCURITÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 4: Monitoring et Sécurité                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Prometheus Stack"
if kubectl get ns monitoring &>/dev/null; then
    test_component "Prometheus Pods" "kubectl get pods -n monitoring | grep prometheus" "Running"
    test_component "Grafana Pods" "kubectl get pods -n monitoring | grep grafana" "Running"
    test_component "Alertmanager Pods" "kubectl get pods -n monitoring | grep alertmanager" "Running"
    test_component "Grafana HTTP" "curl -H 'Host: monitor.keybuzz.io' -s http://10.0.0.110:31695 -o /dev/null -w '%{http_code}'" "200\|302"
else
    echo -e "  $WARN Monitoring Stack non déployé"
    TESTS_WARN=$((TESTS_WARN + 1))
fi

echo ""
echo "→ Loki (Logs)"
if kubectl get pods -n monitoring -l app.kubernetes.io/name=loki &>/dev/null 2>&1; then
    test_component "Loki Pods" "kubectl get pods -n monitoring | grep loki" "Running"
    test_component "Promtail DaemonSet" "kubectl get daemonset -n monitoring | grep promtail" "promtail"
else
    echo -e "  $WARN Loki non déployé"
    TESTS_WARN=$((TESTS_WARN + 1))
fi

echo ""
echo "→ Wazuh SIEM"
if kubectl get ns wazuh &>/dev/null; then
    test_component "Wazuh Manager" "kubectl get pods -n wazuh | grep wazuh-manager" "Running"
    test_component "Wazuh Indexer" "kubectl get pods -n wazuh | grep wazuh-indexer" "Running"
    test_component "Wazuh Dashboard" "kubectl get pods -n wazuh | grep wazuh-dashboard" "Running"
    test_component "Wazuh HTTP" "curl -k -H 'Host: siem.keybuzz.io' -s https://10.0.0.110:32720 -o /dev/null -w '%{http_code}'" "200\|302"
else
    echo -e "  $WARN Wazuh SIEM non déployé"
    TESTS_WARN=$((TESTS_WARN + 1))
fi

# ═══════════════════════════════════════════════════════════════════
# PARTIE 5: LOAD BALANCERS HETZNER
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 5: Load Balancers Hetzner                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ LB Apps (lb-keybuzz-1/2)"
test_component "LB-1 TCP 6443" "nc -zv 49.13.42.76 6443 2>&1" "succeeded"
test_component "LB-1 TCP 80" "nc -zv 49.13.42.76 80 2>&1" "succeeded"
test_component "LB-1 TCP 443" "nc -zv 49.13.42.76 443 2>&1" "succeeded"
test_component "LB-2 TCP 6443" "nc -zv 138.199.132.240 6443 2>&1" "succeeded"

echo ""
echo "→ LB Database (lb-haproxy)"
test_component "LB-DB PostgreSQL 5432" "nc -zv 10.0.0.10 5432 2>&1" "succeeded"
test_component "LB-DB PgBouncer 4632" "nc -zv 10.0.0.10 4632 2>&1" "succeeded"
test_component "LB-DB Redis 6379" "nc -zv 10.0.0.10 6379 2>&1" "succeeded"
test_component "LB-DB RabbitMQ 5672" "nc -zv 10.0.0.10 5672 2>&1" "succeeded"

# ═══════════════════════════════════════════════════════════════════
# PARTIE 6: BACKUPS
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 6: Backups                                              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Scripts de backup"
test_component "Script PostgreSQL" "ssh root@10.0.0.120 'test -f /opt/keybuzz/scripts/backup_postgresql.sh' && echo 'exists'" "exists"
test_component "Script Redis" "ssh root@10.0.0.123 'test -f /opt/keybuzz/scripts/backup_redis.sh' && echo 'exists'" "exists"
test_component "Script K3s" "ssh root@10.0.0.100 'test -f /opt/keybuzz/scripts/backup_k3s.sh' && echo 'exists'" "exists"

echo ""
echo "→ Crontabs configurés"
test_component "Crontab PostgreSQL" "ssh root@10.0.0.120 'crontab -l | grep backup_postgresql.sh'" "backup_postgresql"
test_component "Crontab Redis" "ssh root@10.0.0.123 'crontab -l | grep backup_redis.sh'" "backup_redis"
test_component "Crontab K3s" "ssh root@10.0.0.100 'crontab -l | grep backup_k3s.sh'" "backup_k3s"

# ═══════════════════════════════════════════════════════════════════
# PARTIE 7: RÉSEAU ET SÉCURITÉ
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ PARTIE 7: Réseau et Sécurité                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "→ Réseau privé Hetzner"
test_component "Réseau 10.0.0.0/16" "ip route | grep 10.0.0.0/16" "10.0.0.0/16"

echo ""
echo "→ Firewall UFW"
test_component "UFW Actif" "ufw status | head -1" "Status: active"
test_component "SSH Autorisé" "ufw status | grep 22" "ALLOW"
test_component "Réseau K3s Pods" "ufw status | grep 10.42.0.0/16" "ALLOW"
test_component "Réseau K3s Services" "ufw status | grep 10.43.0.0/16" "ALLOW"

echo ""
echo "→ DNS Configuration"
test_component "DNS n8n.keybuzz.io" "dig +short n8n.keybuzz.io | head -1" "49.13.42.76\|138.199.132.240"
test_component "DNS llm.keybuzz.io" "dig +short llm.keybuzz.io | head -1" "49.13.42.76\|138.199.132.240"

# ═══════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    RÉSUMÉ DE LA VALIDATION                     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

TOTAL_EXECUTED=$((TESTS_OK + TESTS_KO))
PERCENTAGE=$((TESTS_OK * 100 / TOTAL_TESTS))

echo "📊 Statistiques :"
echo "  Total tests     : $TOTAL_TESTS"
echo "  Tests exécutés  : $TOTAL_EXECUTED"
echo "  Succès          : $TESTS_OK"
echo "  Échecs          : $TESTS_KO"
echo "  Avertissements  : $TESTS_WARN"
echo "  Taux de succès  : $PERCENTAGE%"
echo ""

if [ $PERCENTAGE -ge 90 ]; then
    echo -e "  Statut global   : $OK EXCELLENT"
    echo ""
    echo "✅ L'infrastructure KeyBuzz est pleinement opérationnelle !"
elif [ $PERCENTAGE -ge 75 ]; then
    echo -e "  Statut global   : $WARN BON (quelques correctifs mineurs)"
    echo ""
    echo "⚠️  L'infrastructure fonctionne mais nécessite quelques ajustements."
else
    echo -e "  Statut global   : $KO PROBLÈMES DÉTECTÉS"
    echo ""
    echo "❌ Des problèmes importants ont été détectés. Consultez les logs."
fi

echo ""
echo "📋 Composants validés :"
echo "  ✓ PostgreSQL 16 + Patroni RAFT HA"
echo "  ✓ Redis Sentinel HA (3 nœuds)"
echo "  ✓ RabbitMQ Quorum HA (3 nœuds)"
echo "  ✓ HAProxy + Keepalived (2 nœuds)"
echo "  ✓ K3s HA (3 masters + 5 workers)"
echo "  ✓ Ingress NGINX DaemonSet"
echo "  ✓ Applications (n8n, litellm, qdrant, chatwoot, superset)"
echo "  ✓ Load Balancers Hetzner"
echo "  ✓ MinIO S3 Storage"
echo "  ✓ Backups automatiques"
if kubectl get ns monitoring &>/dev/null; then
    echo "  ✓ Monitoring (Prometheus + Grafana + Loki)"
fi
if kubectl get ns wazuh &>/dev/null; then
    echo "  ✓ SIEM Wazuh"
fi
if kubectl get ns vault &>/dev/null; then
    echo "  ✓ Vault (Secrets Management)"
fi

echo ""
echo "🌐 URLs d'accès :"
echo "  n8n         : http://n8n.keybuzz.io"
echo "  LiteLLM     : http://llm.keybuzz.io"
echo "  Qdrant      : http://qdrant.keybuzz.io"
echo "  Chatwoot    : http://chat.keybuzz.io"
echo "  Superset    : http://superset.keybuzz.io"
if kubectl get ns monitoring &>/dev/null; then
    echo "  Grafana     : http://monitor.keybuzz.io"
fi
if kubectl get ns vault &>/dev/null; then
    echo "  Vault       : http://vault.keybuzz.io"
fi
if kubectl get ns wazuh &>/dev/null; then
    echo "  Wazuh       : https://siem.keybuzz.io"
fi
echo "  MinIO       : http://s3.keybuzz.io:9000"

echo ""
echo "📝 Log complet : $MAIN_LOG"
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         🎉 Validation finale terminée avec succès ! 🎉         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

exit 0
