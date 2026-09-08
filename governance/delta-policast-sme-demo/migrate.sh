#!/usr/bin/env bash
# Upgrade the current control plane in place; never remove Docker volumes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
compose=(docker compose -f docker-compose.yml)
"${compose[@]}" up -d --wait postgres
for migration in postgres/migrations/*.sql; do
  echo "Applying $migration"
  "${compose[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 \
    -U governance -d governance < "$migration"
done
