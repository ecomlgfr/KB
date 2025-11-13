#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         DIAGNOSTIC_PATRONI_RAFT - Analyse des erreurs              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
DB_NODES=(db-master-01 db-slave-01 db-slave-02)

# Récupérer les IPs
declare -A NODE_IPS
for node in "${DB_NODES[@]}"; do
    NODE_IPS[$node]=$(awk -F'\t' -v h="$node" '$2==h {print $3}' "$SERVERS_TSV")
done

echo ""
echo "1. État des containers Docker..."
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "$node ($ip):"
    
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CHECK'
    # Container status
    echo -n "  Container: "
    if docker ps | grep -q patroni; then
        echo "RUNNING"
        
        # Logs d'erreur
        echo "  Dernières erreurs:"
        docker logs patroni 2>&1 | grep -E "ERROR|FATAL|Failed|error|Error" | tail -5 | sed 's/^/    /'
        
        # Processus
        echo -n "  Processus Patroni: "
        docker exec patroni ps aux | grep -q patroni && echo "OK" || echo "KO"
        
        # Test port Raft
        echo -n "  Port Raft 7000: "
        docker exec patroni netstat -tln | grep -q ":7000" && echo "LISTENING" || echo "NOT LISTENING"
        
        # Test port API
        echo -n "  Port API 8008: "
        docker exec patroni netstat -tln | grep -q ":8008" && echo "LISTENING" || echo "NOT LISTENING"
        
        # Test port PostgreSQL
        echo -n "  Port PG 5432: "
        docker exec patroni netstat -tln | grep -q ":5432" && echo "LISTENING" || echo "NOT LISTENING"
        
    else
        echo "NOT RUNNING"
        
        # Container existe?
        if docker ps -a | grep -q patroni; then
            echo "  Container existe mais arrêté"
            echo "  Derniers logs avant arrêt:"
            docker logs patroni --tail 20 2>&1 | grep -E "ERROR|FATAL|error" | tail -10 | sed 's/^/    /'
        else
            echo "  Pas de container"
        fi
    fi
    
    # Vérifier la config
    echo "  Config Patroni:"
    if [ -f /opt/keybuzz/patroni/config/patroni.yml ]; then
        echo "    Section raft présente: $(grep -c "^raft:" /opt/keybuzz/patroni/config/patroni.yml)"
        echo "    self_addr: $(grep "self_addr:" /opt/keybuzz/patroni/config/patroni.yml | head -1)"
        echo "    Nb partner_addrs: $(grep -c "^\s*-.*:7000" /opt/keybuzz/patroni/config/patroni.yml)"
    else
        echo "    Fichier config absent!"
    fi
    
    # Vérifier le répertoire Raft
    echo "  Répertoire Raft:"
    if [ -d /opt/keybuzz/postgres/raft ]; then
        echo "    Existe: OUI"
        echo "    Permissions: $(ls -ld /opt/keybuzz/postgres/raft | awk '{print $3":"$4}')"
        echo "    Contenu: $(ls -la /opt/keybuzz/postgres/raft 2>/dev/null | wc -l) fichiers"
    else
        echo "    Existe: NON"
    fi
    
    echo ""
CHECK
done

echo "2. Test de connectivité réseau..."
echo ""

# Tester la connectivité entre les nœuds sur port 7000
for source in "${DB_NODES[@]}"; do
    for target in "${DB_NODES[@]}"; do
        [ "$source" = "$target" ] && continue
        
        source_ip="${NODE_IPS[$source]}"
        target_ip="${NODE_IPS[$target]}"
        
        echo -n "  $source → $target (port 7000): "
        
        if ssh -o StrictHostKeyChecking=no root@"$source_ip" \
            "timeout 2 nc -zv $target_ip 7000 2>&1 | grep -q 'succeeded\|Connected'" 2>/dev/null; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    done
done

echo ""
echo "3. Vérification des images Docker..."
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo -n "  $node - Image patroni-pg17-raft: "
    
    if ssh -o StrictHostKeyChecking=no root@"$ip" \
        "docker images | grep -q 'patroni-pg17-raft'" 2>/dev/null; then
        echo -e "$OK"
    else
        echo -e "$KO"
    fi
done

echo ""
echo "4. Test direct de l'API Patroni..."
echo ""

for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    echo "$node:"
    
    # Test depuis l'intérieur du container
    echo -n "  API interne (localhost): "
    ssh -o StrictHostKeyChecking=no root@"$ip" \
        "docker exec patroni curl -s http://localhost:8008/patroni" &>/dev/null && echo -e "$OK" || echo -e "$KO"
    
    # Test depuis l'hôte
    echo -n "  API externe ($ip): "
    curl -s "http://$ip:8008/patroni" &>/dev/null && echo -e "$OK" || echo -e "$KO"
done

echo ""
echo "5. Recommandations..."
echo ""

# Analyser les problèmes
PROBLEMS=0

# Vérifier si les containers tournent
RUNNING=0
for node in "${DB_NODES[@]}"; do
    ip="${NODE_IPS[$node]}"
    ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q patroni" 2>/dev/null && RUNNING=$((RUNNING + 1))
done

if [ "$RUNNING" -eq 0 ]; then
    echo -e "$KO Aucun container Patroni n'est en cours d'exécution"
    echo ""
    echo "Actions suggérées:"
    echo "  1. Relancer les containers manuellement pour voir les erreurs:"
    echo "     ssh root@10.0.0.120 'docker start patroni && docker logs -f patroni'"
    echo ""
    echo "  2. Vérifier les permissions des volumes:"
    echo "     ssh root@10.0.0.120 'chown -R 999:999 /opt/keybuzz/postgres'"
    echo ""
    echo "  3. Reconstruire l'image si nécessaire:"
    echo "     ./fix_patroni_bootstrap_raft.sh"
elif [ "$RUNNING" -lt 3 ]; then
    echo -e "$KO Seulement $RUNNING/3 containers sont actifs"
    echo ""
    echo "Relancer les containers arrêtés:"
    for node in "${DB_NODES[@]}"; do
        ip="${NODE_IPS[$node]}"
        if ! ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q patroni" 2>/dev/null; then
            echo "  ssh root@$ip 'docker start patroni'"
        fi
    done
else
    echo -e "$OK Tous les containers sont actifs"
    echo ""
    echo "Si l'API ne répond toujours pas:"
    echo "  1. Vérifier les logs pour des erreurs Raft"
    echo "  2. S'assurer que le port 7000 est bien ouvert dans UFW"
    echo "  3. Vérifier que les adresses IP dans patroni.yml sont correctes"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
