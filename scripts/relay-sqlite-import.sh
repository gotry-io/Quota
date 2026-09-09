#!/usr/bin/env bash
# Create a new SQLite database from a wrangler D1 SQL dump and check that
# d1_migrations matches the checked-in apps/relay/migrations files.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="${ROOT_DIR}/apps/relay/migrations"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <dump.sql> <target.sqlite>" >&2
  exit 2
fi

dump="$1"
target="$2"
if [[ "${dump}" != /* ]]; then
  dump="${PWD}/${dump}"
fi
if [[ "${target}" != /* ]]; then
  target="${PWD}/${target}"
fi

if [[ ! -f "${dump}" ]]; then
  echo "dump not found: ${dump}" >&2
  exit 1
fi
if [[ -e "${target}" ]]; then
  echo "refusing to overwrite existing file: ${target}" >&2
  exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required" >&2
  exit 1
fi

mkdir -p "$(dirname "${target}")"
sqlite3 "${target}" ".read '${dump}'"

if ! sqlite3 "${target}" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='d1_migrations';" | grep -q 1; then
  echo "d1_migrations table is missing after import" >&2
  exit 1
fi

expected="$(find "${MIGRATIONS_DIR}" -maxdepth 1 -name '*.sql' -print | wc -l | tr -d ' ')"
actual="$(sqlite3 "${target}" "SELECT COUNT(*) FROM d1_migrations;")"

if [[ "${actual}" != "${expected}" ]]; then
  echo "d1_migrations row count ${actual} does not match ${expected} files in apps/relay/migrations" >&2
  exit 1
fi
