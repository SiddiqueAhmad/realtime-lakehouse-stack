#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
TABLE_FORMAT=iceberg exec bash test-governance.sh
