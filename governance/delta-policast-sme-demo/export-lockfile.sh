#!/usr/bin/env bash
# Export the exact lockfile from the successfully built image, not a new resolution.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ -e app/Cargo.lock ]]; then echo 'app/Cargo.lock already exists; refusing to overwrite it' >&2; exit 1; fi
trap 'rm -f app/Cargo.lock.tmp' EXIT
docker compose -f docker-compose.yml run --rm --no-deps --entrypoint cat governed-query \
  /usr/share/governed-query/Cargo.lock > app/Cargo.lock.tmp
test -s app/Cargo.lock.tmp
mv app/Cargo.lock.tmp app/Cargo.lock
echo 'Exported app/Cargo.lock. Review and commit it; subsequent builds use --locked.'
