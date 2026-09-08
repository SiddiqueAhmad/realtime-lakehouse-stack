#!/usr/bin/env bash
set -euo pipefail

docker compose up -d postgres minio
docker compose run --rm minio-init

docker compose build --pull governed-query

for principal in admin physician analyst; do
  echo
  echo "============================================================"
  echo " Running governed query as: $principal"
  echo "============================================================"
  docker compose run --rm governed-query "$principal"
done
