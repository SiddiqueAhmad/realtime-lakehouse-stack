#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
command -v python3 >/dev/null || { echo 'Python 3.10+ is required for the test runner' >&2; exit 1; }
compose=(docker compose -f docker-compose.yml)
"${compose[@]}" up -d --wait postgres minio
"${compose[@]}" run --rm minio-init
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then "${compose[@]}" build governed-query; fi
python3 tests/test_governance.py
