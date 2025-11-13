#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              DEBUG_PATRONI - Analyse des erreurs                   ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

echo ""
echo "1. État des containers..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo "  $hostname ($ip):"
    
    # État du container
    STATUS=$(ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps -a | grep patroni" 2>/dev/null || echo "  Pas de container")
    echo "    $STATUS"
    
    # Si le container existe, afficher les dernières erreurs
    if ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps -a | grep -q patroni" 2>/dev/null; then
        echo "    Dernières erreurs:"
        ssh -o StrictHostKeyChecking=no root@"$ip" "docker logs patroni 2>&1 | tail -20" 2>/dev/null | grep -E "ERROR|error|FATAL|Fatal|failed|Failed" | head -5 | sed 's/^/      /'
    fi
    echo ""
done

echo "2. Vérification des configurations..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo "  $hostname:"
    
    # Vérifier si le fichier de config existe
    if ssh -o StrictHostKeyChecking=no root@"$ip" "[ -f /opt/keybuzz/patroni/config/patroni.yml ]" 2>/dev/null; then
        echo -n "    Config présente: "
        
        # Vérifier la syntaxe YAML
        ERROR=$(ssh -o StrictHostKeyChecking=no root@"$ip" "docker run --rm -v /opt/keybuzz/patroni/config/patroni.yml:/test.yml:ro patroni:17-raft python3 -c 'import yaml; yaml.safe_load(open(\"/test.yml\"))' 2>&1" 2>/dev/null | grep -i error || echo "")
        
        if [ -z "$ERROR" ]; then
            echo -e "$OK"
        else
            echo -e "$KO"
            echo "      Erreur: $ERROR"
        fi
    else
        echo "    Config absente!"
    fi
done

echo ""
echo "3. Test de connectivité Raft (port 7000)..."
echo ""

for source in 10.0.0.120 10.0.0.121 10.0.0.122; do
    for target in 10.0.0.120 10.0.0.121 10.0.0.122; do
        [ "$source" = "$target" ] && continue
        
        echo -n "  $source → $target: "
        if ssh -o StrictHostKeyChecking=no root@"$source" "nc -zv $target 7000 2>&1 | grep -q 'succeeded\|Connected'" 2>/dev/null; then
            echo -e "$OK"
        else
            echo -e "$KO"
        fi
    done
done

echo ""
echo "4. Permissions des répertoires..."
echo ""

for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    case "$ip" in
        "10.0.0.120") hostname="db-master-01" ;;
        "10.0.0.121") hostname="db-slave-01" ;;
        "10.0.0.122") hostname="db-slave-02" ;;
    esac
    
    echo "  $hostname:"
    ssh -o StrictHostKeyChecking=no root@"$ip" bash <<'CHECK' 2>/dev/null
    echo -n "    /opt/keybuzz/postgres/data: "
    ls -ld /opt/keybuzz/postgres/data | awk '{print $3":"$4, $1}'
    
    echo -n "    /opt/keybuzz/postgres/raft: "
    ls -ld /opt/keybuzz/postgres/raft | awk '{print $3":"$4, $1}'
CHECK
done

echo ""
echo "5. Recommandations..."
echo ""

# Compter les containers running
RUNNING=0
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    ssh -o StrictHostKeyChecking=no root@"$ip" "docker ps | grep -q patroni" 2>/dev/null && RUNNING=$((RUNNING + 1))
done

if [ "$RUNNING" -eq 0 ]; then
    echo -e "$KO Aucun container Patroni en cours d'exécution"
    echo ""
    echo "Actions recommandées:"
    echo "  1. Exécuter le script de correction:"
    echo "     ./fix_and_restart.sh"
    echo ""
    echo "  2. Relancer l'installation:"
    echo "     ./02_install_patroni_raft.sh"
    echo ""
    echo "  3. Si le problème persiste, essayer le mode debug manuel:"
    echo "     ssh root@10.0.0.120"
    echo "     docker run -it --rm --network host \\"
    echo "       -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \\"
    echo "       patroni:17-raft patroni /etc/patroni/patroni.yml"
elif [ "$RUNNING" -lt 3 ]; then
    echo -e "$KO Seulement $RUNNING/3 containers actifs"
    echo "Le quorum Raft nécessite au minimum 2 nœuds."
else
    echo -e "$OK Tous les containers sont actifs"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
