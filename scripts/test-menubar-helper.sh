#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_PATH="${1:-${ROOT_DIR}/dist/menubar/QuotaBar.app/Contents/Helpers/quota-service}"
if [[ "$HELPER_PATH" != /* ]]; then
  HELPER_PATH="${ROOT_DIR}/${HELPER_PATH}"
fi
if [[ ! -x "$HELPER_PATH" ]]; then
  echo "missing executable helper: $HELPER_PATH" >&2
  echo "package QuotaBar first with pnpm build:menubar:app" >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-helper-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -m 700 -p \
  "$TEST_ROOT/home" \
  "$TEST_ROOT/config" \
  "$TEST_ROOT/data" \
  "$TEST_ROOT/codex" \
  "$TEST_ROOT/claude" \
  "$TEST_ROOT/grok" \
  "$TEST_ROOT/pi"

cd "$ROOT_DIR"
env -i \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$TEST_ROOT/home" \
  XDG_CONFIG_HOME="$TEST_ROOT/config" \
  XDG_DATA_HOME="$TEST_ROOT/data" \
  CODEX_HOME="$TEST_ROOT/codex" \
  CLAUDE_CONFIG_DIR="$TEST_ROOT/claude" \
  GROK_HOME="$TEST_ROOT/grok" \
  PI_CODING_AGENT_DIR="$TEST_ROOT/pi" \
  QUOTA_LIVE_HELPER="$HELPER_PATH" \
  swift test --package-path apps/menubar --filter LocalServiceClientTests
