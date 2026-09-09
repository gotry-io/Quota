#!/bin/sh
# Snapshot a Relay SQLite database with sqlite3 .backup and keep the newest
# RELAY_BACKUP_KEEP dated files (default 14). Used by deploy/relay Compose and
# for a manual run on the host.
#
#   relay-sqlite-backup.sh [--loop] [sqlite-path] [backup-dir]
#
# --loop waits until 03:00 in TZ each day, then backups (Compose backup service).
set -eu

loop=0
if [ "${1:-}" = "--loop" ]; then
  loop=1
  shift
fi

SOURCE="${1:-${RELAY_SQLITE_PATH:-/data/relay.sqlite}}"
BACKUP_DIR="${2:-${RELAY_BACKUP_DIR:-/backups}}"
KEEP="${RELAY_BACKUP_KEEP:-14}"

backup_once() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 is required" >&2
    return 1
  fi
  if [ ! -f "${SOURCE}" ]; then
    echo "sqlite database not found: ${SOURCE}" >&2
    return 1
  fi

  mkdir -p "${BACKUP_DIR}"
  stamp="$(date +%Y%m%d)"
  dest="${BACKUP_DIR}/relay-${stamp}.sqlite"

  sqlite3 "${SOURCE}" ".backup ${dest}"
  echo "wrote ${dest}"

  # Keep the newest KEEP files named relay-YYYYMMDD.sqlite; drop the rest.
  # shellcheck disable=SC2012
  set -- $(ls -1 "${BACKUP_DIR}"/relay-*.sqlite 2>/dev/null | sort -r)
  index=0
  for file in "$@"; do
    index=$((index + 1))
    if [ "${index}" -gt "${KEEP}" ]; then
      rm -f "${file}"
    fi
  done
}

if [ "${loop}" -eq 1 ]; then
  echo "relay backup scheduler started TZ=${TZ:-UTC}"
  while true; do
    current="$(date +%H:%M)"
    case "${current}" in
      03:00)
        backup_once || echo "relay backup failed"
        sleep 60
        ;;
      *)
        sleep 20
        ;;
    esac
  done
fi

backup_once
