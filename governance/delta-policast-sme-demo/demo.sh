#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
bash seed-demo.sh
for principal in admin physician analyst; do
  echo "===== Healthcare fixture: $principal ====="
  docker compose -f docker-compose.yml run --rm governed-query "$principal" \
    --table patients --sql "$(cat fixtures/healthcare/query.sql)"
done
echo '===== Trading fixture: same binary, different schema and policies ====='
docker compose -f docker-compose.yml run --rm governed-query finance_reader \
  --table invoices --sql "$(cat fixtures/trading/query.sql)"
