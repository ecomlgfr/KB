#!/usr/bin/env bash
echo "═══ Diagnostic Cluster Patroni RAFT ═══"
echo ""

# 1. Vérifier les conteneurs
echo "→ Conteneurs actifs:"
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo -n "  $ip: "
    ssh root@$ip "docker ps --filter name=patroni --format '{{.Status}}' 2>/dev/null" || echo "Erreur SSH"
done
echo ""

# 2. Vérifier l'API Patroni
echo "→ API Patroni (leader):"
curl -s http://10.0.0.120:8008/cluster 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  API non accessible"
echo ""

# 3. Logs des replicas (30 dernières lignes)
for ip in 10.0.0.121 10.0.0.122; do
    echo "→ Logs replica $ip (30 dernières lignes):"
    ssh root@$ip "docker logs patroni 2>&1 | tail -30"
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo ""
done

# 4. État de la réplication PostgreSQL
echo "→ État de la réplication (depuis le leader):"
ssh root@10.0.0.120 "docker exec patroni psql -U postgres -c 'SELECT * FROM pg_stat_replication;' 2>/dev/null" || echo "  Pas de connexion"
echo ""

# 5. Vérifier les ports
echo "→ Test connectivité ports:"
for ip in 10.0.0.121 10.0.0.122; do
    echo "  Depuis leader vers $ip:"
    echo -n "    Port 5432 (PostgreSQL): "
    ssh root@10.0.0.120 "timeout 2 nc -zv $ip 5432 2>&1" | grep -q succeeded && echo "OK" || echo "KO"
    echo -n "    Port 7000 (RAFT): "
    ssh root@10.0.0.120 "timeout 2 nc -zv $ip 7000 2>&1" | grep -q succeeded && echo "OK" || echo "KO"
    echo -n "    Port 8008 (API): "
    ssh root@10.0.0.120 "timeout 2 nc -zv $ip 8008 2>&1" | grep -q succeeded && echo "OK" || echo "KO"
done
echo ""

# 6. Vérifier les données
echo "→ Répertoires de données:"
for ip in 10.0.0.120 10.0.0.121 10.0.0.122; do
    echo "  $ip:"
    ssh root@$ip "ls -lh /opt/keybuzz/postgres/data/ 2>/dev/null | head -5"
done
