#!/bin/sh
# Restore a Relay SQLite snapshot taken by relay-sqlite-backup.sh.
#
#   relay-sqlite-restore.sh [--force] <snapshot> <target>
#
# Refuses a snapshot that fails PRAGMA integrity_check, or that names a
# d1_migrations row this checkout does not have. Fewer rows than the
# checkout is fine: Relay applies the rest on start. Refuses to overwrite
# a non-empty target unless --force. Writes via a temp file and rename.
# Does not invoke docker; wrap the volumes in the runbook.
#
# RELAY_MIGRATIONS_DIR overrides the checkout's apps/relay/migrations
# (set this when the script is bind-mounted away from the repository).
set -eu

ROOT_DIR="$(cd "$(dirname -- "$0")/.." && pwd)"
MIGRATIONS_DIR="${RELAY_MIGRATIONS_DIR:-${ROOT_DIR}/apps/relay/migrations}"

usage() {
  echo "usage: $0 [--force] <snapshot> <target>" >&2
  exit 2
}

force=0
snapshot=""
target=""
for arg in "$@"; do
  case "${arg}" in
    --force)
      force=1
      ;;
    --help | -h)
      usage
      ;;
    --)
      usage
      ;;
    -*)
      echo "unknown option: ${arg}" >&2
      usage
      ;;
    *)
      if [ -z "${snapshot}" ]; then
        snapshot="${arg}"
      elif [ -z "${target}" ]; then
        target="${arg}"
      else
        usage
      fi
      ;;
  esac
done

if [ -z "${snapshot}" ] || [ -z "${target}" ]; then
  usage
fi

case "${snapshot}" in
  /*) ;;
  *) snapshot="${PWD}/${snapshot}" ;;
esac
case "${target}" in
  /*) ;;
  *) target="${PWD}/${target}" ;;
esac

case "${snapshot}${target}" in
  *"'"*)
    echo "paths must not contain a single quote" >&2
    exit 1
    ;;
esac

if [ "${snapshot}" = "${target}" ]; then
  echo "snapshot and target are the same path: ${snapshot}" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required" >&2
  exit 1
fi

if [ ! -f "${snapshot}" ]; then
  echo "snapshot not found: ${snapshot}" >&2
  exit 1
fi

if [ -d "${target}" ]; then
  echo "target is a directory: ${target}" >&2
  exit 1
fi

if [ -s "${target}" ] && [ "${force}" -eq 0 ]; then
  echo "refusing to overwrite non-empty target: ${target} (pass --force)" >&2
  exit 1
fi

if [ ! -d "${MIGRATIONS_DIR}" ]; then
  echo "migrations directory not found: ${MIGRATIONS_DIR}" >&2
  exit 1
fi

checkout=0
for file in "${MIGRATIONS_DIR}"/*.sql; do
  if [ ! -e "${file}" ]; then
    echo "no .sql migrations in ${MIGRATIONS_DIR}" >&2
    exit 1
  fi
  checkout=$((checkout + 1))
done

# A .backup of a WAL database is itself WAL. sqlite3 -readonly cannot create
# the -shm file, and PRAGMA integrity_check then fails with CANTOPEN. Copy
# first and check the copy; do not open the snapshot for write.
target_dir="$(dirname -- "${target}")"
mkdir -p "${target_dir}"
tmp="${target}.tmp.$$"
cleanup() {
  rm -f "${tmp}" "${tmp}-wal" "${tmp}-shm"
}
trap cleanup EXIT INT TERM
cp "${snapshot}" "${tmp}"
if [ ! -s "${tmp}" ]; then
  echo "restore produced an empty file" >&2
  exit 1
fi

set +e
check="$(sqlite3 -bail "${tmp}" "PRAGMA integrity_check;" 2>&1)"
check_status=$?
set -e
if [ "${check_status}" -ne 0 ] || [ "${check}" != "ok" ]; then
  echo "snapshot failed integrity_check: ${check}" >&2
  exit 1
fi

set +e
has_ledger="$(sqlite3 -bail "${tmp}" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='d1_migrations';" 2>&1)"
ledger_status=$?
set -e
if [ "${ledger_status}" -ne 0 ] || [ "${has_ledger}" != "1" ]; then
  echo "d1_migrations table is missing in snapshot" >&2
  exit 1
fi

set +e
snapshot_names="$(sqlite3 -bail "${tmp}" "SELECT name FROM d1_migrations ORDER BY name;" 2>&1)"
names_status=$?
set -e
if [ "${names_status}" -ne 0 ]; then
  echo "could not read d1_migrations: ${snapshot_names}" >&2
  exit 1
fi

unknown=0
snapshot_count=0
if [ -n "${snapshot_names}" ]; then
  while IFS= read -r name; do
    [ -z "${name}" ] && continue
    snapshot_count=$((snapshot_count + 1))
    if [ ! -f "${MIGRATIONS_DIR}/${name}" ]; then
      echo "snapshot names unknown migration: ${name}" >&2
      unknown=1
    fi
  done <<EOF
${snapshot_names}
EOF
fi
if [ "${unknown}" -ne 0 ]; then
  exit 1
fi

# Checkpoint WAL into the main file so the restored target is one file.
sqlite3 -bail "${tmp}" "PRAGMA journal_mode=DELETE;" >/dev/null
rm -f "${tmp}-wal" "${tmp}-shm"

mv -f "${tmp}" "${target}"
rm -f "${target}-wal" "${target}-shm"

echo "restored ${snapshot} to ${target}"
echo "integrity_check: ok"
echo "d1_migrations: ${snapshot_count} in snapshot, ${checkout} in checkout (start applies any remainder)"
if [ "${force}" -eq 1 ]; then
  echo "overwrite: --force"
fi
