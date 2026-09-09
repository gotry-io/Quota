#!/usr/bin/env bash
# Export the managed D1 database `quota` to a SQL dump via wrangler.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <file>" >&2
  exit 2
fi

output="$1"
if [[ "${output}" != /* ]]; then
  output="${PWD}/${output}"
fi

mkdir -p "$(dirname "${output}")"

cd "${ROOT_DIR}/apps/relay"
pnpm exec wrangler d1 export quota --remote --output "${output}"
