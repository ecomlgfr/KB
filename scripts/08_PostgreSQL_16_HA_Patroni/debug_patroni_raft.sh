#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║         DEBUG_PATRONI_RAFT - Analyse détaillée                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32m✓\033[0m'; KO='\033[0;31m✗\033[0m'

echo ""
echo "1. Logs détaillés de db-master-01..."
echo "═══════════════════════════════════════════════════════════════════"

ssh -o StrictHostKeyChecking=no root@10.0.0.120 bash <<'DEBUG'
echo "Container status:"
docker ps -a | grep patroni

echo ""
echo "Derniers logs (50 lignes):"
docker logs patroni --tail 50 2>&1

echo ""
echo "Configuration YAML:"
echo "---"
cat /opt/keybuzz/patroni/config/patroni.yml
echo "---"

echo ""
echo "Permissions des répertoires:"
ls -ld /opt/keybuzz/postgres/data
ls -ld /opt/keybuzz/postgres/raft
ls -ld /opt/keybuzz/postgres/archive

echo ""
echo "Test manuel du container:"
docker run --rm \
  --name patroni-test \
  --network host \
  --user 999:999 \
  -v /opt/keybuzz/postgres/data:/var/lib/postgresql/data \
  -v /opt/keybuzz/postgres/raft:/opt/keybuzz/postgres/raft \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg17-raft:latest \
  python3 -c "import yaml; print('Python OK'); import patroni; print('Patroni importé')"

echo ""
echo "Test de parsing YAML:"
docker run --rm \
  --network host \
  -v /opt/keybuzz/patroni/config/patroni.yml:/etc/patroni/patroni.yml:ro \
  patroni-pg17-raft:latest \
  python3 -c "import yaml; config = yaml.safe_load(open('/etc/patroni/patroni.yml')); print('YAML valide'); print('Raft config:', config.get('raft', {}))"
DEBUG

echo ""
echo "═══════════════════════════════════════════════════════════════════"
