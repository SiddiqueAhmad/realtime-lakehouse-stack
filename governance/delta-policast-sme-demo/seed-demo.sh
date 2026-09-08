#!/usr/bin/env bash
# Opt-in, trusted fixture setup. Existing Delta tables/metadata are preserved.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
compose=(docker compose -f docker-compose.yml)
bash migrate.sh
"${compose[@]}" up -d --wait minio
"${compose[@]}" run --rm minio-init
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then "${compose[@]}" build governed-query; fi
for fixture in healthcare trading; do
  "${compose[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 \
    -U governance -d governance < "fixtures/$fixture/governance.sql"
  "${compose[@]}" run --rm fixture-loader "/fixtures/$fixture/table.json"
done
