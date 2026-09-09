#!/usr/bin/env bash
# Real storage behavior tests; NOT the six manifest checks.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required"'
command -v docker >/dev/null
lane=${LANE:-all}
case "$lane" in
  all) lanes=(df53 df54) ;;
  df53|df54) lanes=("$lane") ;;
  *) echo 'LANE must be all, df53 or df54' >&2; exit 2 ;;
esac
docker compose -f docker-compose.yml up -d --wait postgres minio
docker compose -f docker-compose.yml run --rm minio-init
for version in "${lanes[@]}"; do
  if [[ ${SKIP_BUILD:-0} != 1 ]]; then
    docker build --progress=plain -f qualification/Dockerfile \
      --build-arg "LANE=$version" -t "ducklake-qualification:$version" .
  else
    docker image inspect "ducklake-qualification:$version" >/dev/null
  fi
done
exec python3 tests/test_ducklake_qualification.py --lane "$lane" "$@"
