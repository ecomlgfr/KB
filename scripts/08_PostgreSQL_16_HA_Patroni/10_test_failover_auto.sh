#!/usr/bin/env bash
set -u; set -o pipefail

VIP="10.0.0.10"; RW=5432; RO=5433; PGB=6432

echo "== RW check =="
psql -h $VIP -p $RW -U postgres -d postgres -c 'select inet_server_addr(),pg_is_in_recovery();'

echo "== RO check =="
psql -h $VIP -p $RO -U postgres -d postgres -c 'select inet_server_addr(),pg_is_in_recovery();'

echo "== Pool (PgBouncer via LB) =="
psql -h $VIP -p $PGB -U pgbouncer -d postgres -c 'select 1;'

echo "== Switchover (manuel si besoin via patronictl), puis re-check RW/RO/POOL =="
