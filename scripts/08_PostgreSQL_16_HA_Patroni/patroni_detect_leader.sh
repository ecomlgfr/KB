#!/usr/bin/env bash
set -euo pipefail

# ====== VARS (à ajuster si besoin) ======
DB_NODES=("10.0.0.120" "10.0.0.121" "10.0.0.122")
PATRONI_PORT=8008
SSH_USER="root"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no"

echo "╔═════════════════════════════════════════╗"
echo "║       PATRONI_DETECT_LEADER (API)       ║"
echo "╚═════════════════════════════════════════╝"

LEADER_IP=""
for ip in "${DB_NODES[@]}"; do
  # Essaye localement via curl si dispo, sinon via SSH sur le nœud.
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -s --max-time 2 http://${ip}:${PATRONI_PORT}/cluster || true)"
  else
    out="$(ssh ${SSH_OPTS} ${SSH_USER}@${ip} "curl -s --max-time 2 http://127.0.0.1:${PATRONI_PORT}/cluster" || true)"
  fi
  if [[ -n "$out" ]]; then
    role=$(echo "$out" | grep -Eo '"role":\s*"leader"' || true)
    if [[ -n "$role" ]]; then
      # Identifie la ligne où role=leader et récupère host/ip
      # Patroni /cluster renvoie un JSON avec le "leader".
      host=$(echo "$out" | grep -Eo '"host":\s*"[^"]+"' | head -n1 | cut -d'"' -f4)
      # Si host n'est pas une IP, on suppose que c’est $ip actuel.
      if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        LEADER_IP="$host"
      else
        LEADER_IP="$ip"
      fi
      echo "Leader Patroni détecté : ${LEADER_IP}"
      break
    fi
  fi
done

if [[ -z "${LEADER_IP}" ]]; then
  echo "KO: Impossible de détecter le leader Patroni (API indisponible ?)"
  exit 1
fi

# Expose proprement pour d’autres scripts
echo "${LEADER_IP}" > /tmp/patroni_leader_ip
echo "Leader IP sauvegardé : /tmp/patroni_leader_ip"
