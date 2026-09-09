#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else "Python 3.10+ required")'
: "${STANDARD_IMAGE:=ducklake-standard:patched}"
export STANDARD_IMAGE
if [[ ${SKIP_BUILD:-0} != 1 ]]; then
  docker build --progress=plain -f Dockerfile --build-arg FIXES=1 -t "$STANDARD_IMAGE" ../..
fi
docker image inspect "$STANDARD_IMAGE" >/dev/null
docker compose up -d --wait postgres minio
docker compose run --rm minio-init
exec python3 run.py "$@"
