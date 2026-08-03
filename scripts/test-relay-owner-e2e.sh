#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/menubar-visual/QuotaBarVisual.app"
APP_BINARY="${APP_PATH}/Contents/MacOS/QuotaBar"
REPORT_FIXTURE="${ROOT_DIR}/apps/cli/test/fixtures/relay-owner-e2e-report.json"
REPORT_RUNNER="${ROOT_DIR}/apps/cli/test/support/edge-report-e2e.ts"
OUTPUT_DIR="${ROOT_DIR}/dist/menubar-relay-e2e"
TIMEOUT_SECONDS=30
APP_PID=""
CLI_PID=""
RELAY_PID=""
WORK_DIR=""

usage() {
  cat <<'EOF'
Usage: test-relay-owner-e2e.sh

Runs the real QuotaBar owner path against a loopback self-hosted QuotaRelay and
isolated QuotaCLI edge state. The LaunchServices-started Visual App uses production
URLSession, state, Defaults, and Keychain boundaries. No provider credentials are read.
The verified remote Overview screenshot is written to dist/menubar-relay-e2e.
EOF
}

fail() {
  printf 'relay owner-path e2e failed: %s\n' "$1" >&2
  exit 1
}

stop_process() {
  local pid="$1"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    local attempts=0
    while kill -0 "$pid" 2>/dev/null && [[ $attempts -lt 25 ]]; do
      sleep 0.2
      attempts=$((attempts + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
  return 0
}

cleanup() {
  stop_process "$CLI_PID"
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    if [[ -n "$WORK_DIR" && -d "${WORK_DIR}/coordination" ]]; then
      printf 'cancel' >"${WORK_DIR}/coordination/cancel.tmp" 2>/dev/null || true
      mv "${WORK_DIR}/coordination/cancel.tmp" "${WORK_DIR}/coordination/cancel" \
        2>/dev/null || true
      local cancel_attempts=0
      while kill -0 "$APP_PID" 2>/dev/null && [[ $cancel_attempts -lt 25 ]]; do
        sleep 0.2
        cancel_attempts=$((cancel_attempts + 1))
      done
    fi
    local app_command
    app_command="$(ps -p "$APP_PID" -o command= 2>/dev/null || true)"
    if [[ "$app_command" == *"$APP_BINARY"* ]]; then
      stop_process "$APP_PID"
    fi
  fi
  stop_process "$RELAY_PID"
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_file() {
  local path="$1"
  local label="$2"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [[ $SECONDS -lt $deadline ]]; do
    if [[ -s "$path" ]]; then
      return
    fi
    if [[ -n "$WORK_DIR" && -s "${WORK_DIR}/coordination/failed" ]]; then
      fail "QuotaBar reported a fixed acceptance failure while waiting for ${label}"
    fi
    sleep 0.1
  done
  fail "timed out waiting for ${label}"
}

write_marker() {
  local path="$1"
  local temporary="${path}.tmp"
  printf 'ready' >"$temporary"
  mv "$temporary" "$path"
}

cli_environment() {
  /usr/bin/env \
    HOME="${WORK_DIR}/home" \
    PATH="${WORK_DIR}/empty-bin" \
    XDG_CONFIG_HOME="${WORK_DIR}/config" \
    CODEX_HOME="${WORK_DIR}/codex" \
    CLAUDE_CONFIG_DIR="${WORK_DIR}/claude" \
    GROK_HOME="${WORK_DIR}/grok" \
    CODEX_CLI_PATH="${WORK_DIR}/empty-bin/missing-codex" \
    CLAUDE_CLI_PATH="${WORK_DIR}/empty-bin/missing-claude" \
    GROK_CLI_PATH="${WORK_DIR}/empty-bin/missing-grok" \
    LANG=C \
    LC_ALL=C \
    "$@"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "this E2E requires macOS (QuotaBar + Keychain)"

BUN_PATH="$(command -v bun || true)"
NODE_PATH="$(command -v node || true)"
[[ -x "$BUN_PATH" ]] || fail "bun is required on PATH"
[[ -x "$NODE_PATH" ]] || fail "node is required on PATH"
for tool in /usr/bin/openssl /usr/bin/open /usr/bin/sips /usr/bin/swiftc; do
  [[ -x "$tool" ]] || fail "required macOS tool is unavailable: $tool"
done
[[ -f "$REPORT_FIXTURE" && -f "$REPORT_RUNNER" ]] || fail "E2E support files are missing"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quota-relay-owner-e2e.XXXXXX")"
chmod 700 "$WORK_DIR"
mkdir -m 700 \
  "${WORK_DIR}/coordination" \
  "${WORK_DIR}/config" \
  "${WORK_DIR}/home" \
  "${WORK_DIR}/empty-bin" \
  "${WORK_DIR}/codex" \
  "${WORK_DIR}/claude" \
  "${WORK_DIR}/grok"

RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OWNER_TOKEN="$(/usr/bin/openssl rand -hex 32)"
OWNER_TOKEN_FILE="${WORK_DIR}/owner-token"
DEFAULTS_SUITE="io.gotry.quotabar.e2e.${RUN_ID}"
KEYCHAIN_SERVICE="io.gotry.quotabar.relay-owner.e2e.${RUN_ID}"
COORDINATION_DIR="${WORK_DIR}/coordination"
SCREENSHOT_PATH="${WORK_DIR}/relay-overview.png"
printf '%s' "$OWNER_TOKEN" >"$OWNER_TOKEN_FILE"
chmod 600 "$OWNER_TOKEN_FILE"

cd "$ROOT_DIR"
./scripts/package-menubar-visual.sh >/dev/null
[[ -x "$APP_BINARY" ]] || fail "QuotaBar Visual App was not built"

HOST=127.0.0.1 \
  PORT=0 \
  QUOTA_RELAY_OWNER_TOKEN="$OWNER_TOKEN" \
  QUOTA_RELAY_DATABASE_PATH="${WORK_DIR}/relay.db" \
  QUOTA_RELAY_INSTANCE_ID="owner-e2e-${RUN_ID}" \
  "$BUN_PATH" apps/relay/src/self-hosted.ts \
  >"${WORK_DIR}/relay.stdout.log" 2>"${WORK_DIR}/relay.stderr.log" &
RELAY_PID=$!

RELAY_ORIGIN=""
relay_deadline=$((SECONDS + TIMEOUT_SECONDS))
while [[ $SECONDS -lt $relay_deadline ]]; do
  if ! kill -0 "$RELAY_PID" 2>/dev/null; then
    fail "self-hosted Relay exited before becoming ready"
  fi
  RELAY_ORIGIN="$(
    sed -nE 's/.*listening on 127\.0\.0\.1:([0-9]+).*/http:\/\/127.0.0.1:\1/p' \
      "${WORK_DIR}/relay.stdout.log" | tail -n 1
  )"
  [[ -n "$RELAY_ORIGIN" ]] && break
  sleep 0.1
done
[[ -n "$RELAY_ORIGIN" ]] || fail "self-hosted Relay did not publish its loopback origin"

/usr/bin/open -n "$APP_PATH" --args \
  --data-source fixture \
  --fixture loading \
  --route overview \
  --appearance light \
  --text-size standard \
  --screenshot-output "$SCREENSHOT_PATH" \
  --relay-acceptance-origin "$RELAY_ORIGIN" \
  --relay-acceptance-owner-token-file "$OWNER_TOKEN_FILE" \
  --relay-acceptance-directory "$COORDINATION_DIR" \
  --relay-acceptance-defaults-suite "$DEFAULTS_SUITE" \
  --relay-acceptance-keychain-service "$KEYCHAIN_SERVICE"

wait_for_file "${COORDINATION_DIR}/app.pid" "QuotaBar process identity"
APP_PID="$(<"${COORDINATION_DIR}/app.pid")"
[[ "$APP_PID" =~ ^[0-9]+$ ]] || fail "QuotaBar returned an invalid process identifier"
app_command="$(ps -p "$APP_PID" -o command= 2>/dev/null || true)"
[[ "$app_command" == *"$APP_BINARY"* ]] || fail "QuotaBar process identity did not match the app bundle"
wait_for_file "${COORDINATION_DIR}/ready.json" "QuotaBar Relay profile and Keychain persistence"

cli_environment \
  "$BUN_PATH" apps/cli/src/main.ts edge pair --relay "$RELAY_ORIGIN" \
  >"${WORK_DIR}/pair.stdout.log" 2>"${WORK_DIR}/pair.stderr.log" &
CLI_PID=$!

PAIRING_CODE=""
pairing_deadline=$((SECONDS + TIMEOUT_SECONDS))
while [[ $SECONDS -lt $pairing_deadline ]]; do
  PAIRING_CODE="$(sed -n 's/^Pairing code: //p' "${WORK_DIR}/pair.stdout.log" | tail -n 1)"
  [[ -n "$PAIRING_CODE" ]] && break
  if ! kill -0 "$CLI_PID" 2>/dev/null; then
    fail "QuotaCLI exited before publishing a pairing code"
  fi
  sleep 0.1
done
[[ -n "$PAIRING_CODE" ]] || fail "QuotaCLI did not publish a pairing code"
printf '%s' "$PAIRING_CODE" >"${COORDINATION_DIR}/pairing-code.txt.tmp"
mv "${COORDINATION_DIR}/pairing-code.txt.tmp" "${COORDINATION_DIR}/pairing-code.txt"
wait_for_file "${COORDINATION_DIR}/pairing-approved" "QuotaBar pairing approval"

pair_exit_deadline=$((SECONDS + TIMEOUT_SECONDS))
while kill -0 "$CLI_PID" 2>/dev/null && [[ $SECONDS -lt $pair_exit_deadline ]]; do
  sleep 0.1
done
kill -0 "$CLI_PID" 2>/dev/null && fail "QuotaCLI pairing did not finish"
if wait "$CLI_PID"; then
  pair_status=0
else
  pair_status=$?
fi
CLI_PID=""
[[ $pair_status -eq 0 ]] || fail "QuotaCLI pairing failed"
rg -F "Pairing complete." "${WORK_DIR}/pair.stdout.log" >/dev/null \
  || fail "QuotaCLI did not confirm pairing"
if rg -F "$OWNER_TOKEN" "${WORK_DIR}/pair.stdout.log" "${WORK_DIR}/pair.stderr.log" >/dev/null; then
  fail "QuotaCLI pairing output exposed the owner credential"
fi

if cli_environment \
  "$BUN_PATH" "$REPORT_RUNNER" "$REPORT_FIXTURE" \
  >"${WORK_DIR}/report.stdout.log" 2>"${WORK_DIR}/report.stderr.log"; then
  report_status=0
else
  report_status=$?
fi
[[ $report_status -eq 1 ]] || fail "QuotaCLI report returned an unexpected status"
rg -F "Uploaded 1 snapshot with sequence 0." "${WORK_DIR}/report.stdout.log" >/dev/null \
  || fail "QuotaCLI did not upload the deterministic non-empty snapshot"
write_marker "${COORDINATION_DIR}/report-ready"

wait_for_file "${COORDINATION_DIR}/snapshot.json" "QuotaBar remote Overview state"
wait_for_file "$SCREENSHOT_PATH" "QuotaBar remote Overview screenshot"
"$NODE_PATH" -e '
  const fs = require("node:fs");
  const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (result.provider !== "codex" || result.fingerprint !== "e2e-codex-account" ||
      result.window_id !== "five_hour" || result.used_percent !== 42 ||
      result.remaining_percent !== 58 || result.source !== "Remote" || result.restored !== true) {
    process.exit(1);
  }
' "${COORDINATION_DIR}/snapshot.json" || fail "QuotaBar returned an invalid remote Overview result"

WINDOW_FINDER="${WORK_DIR}/find-menubar-visual-window"
/usr/bin/swiftc scripts/find-menubar-visual-window.swift -o "$WINDOW_FINDER"
window_info="$($WINDOW_FINDER "$APP_PID" "QuotaBar Visual QA")" \
  || fail "QuotaBar acceptance window was not discoverable by exact PID"
IFS=$'\t' read -r window_id window_width window_height <<<"$window_info"
[[ "$window_id" =~ ^[0-9]+$ && "$window_width" -ge 300 && "$window_height" -ge 300 ]] \
  || fail "QuotaBar acceptance window bounds were invalid"
pixel_width="$(/usr/bin/sips -g pixelWidth "$SCREENSHOT_PATH" | awk '/pixelWidth:/ { print $2 }')"
pixel_height="$(/usr/bin/sips -g pixelHeight "$SCREENSHOT_PATH" | awk '/pixelHeight:/ { print $2 }')"
[[ "$pixel_width" -ge 300 && "$pixel_height" -ge 300 ]] \
  || fail "QuotaBar acceptance screenshot dimensions were invalid"

write_marker "${COORDINATION_DIR}/revoke-request"
wait_for_file "${COORDINATION_DIR}/revoked" "QuotaBar device revocation"

if cli_environment \
  "$BUN_PATH" "$REPORT_RUNNER" "$REPORT_FIXTURE" \
  >"${WORK_DIR}/rejected.stdout.log" 2>"${WORK_DIR}/rejected.stderr.log"; then
  rejected_status=0
else
  rejected_status=$?
fi
[[ $rejected_status -eq 1 ]] || fail "revoked QuotaCLI report returned an unexpected status"
if rg -F "Uploaded" "${WORK_DIR}/rejected.stdout.log" >/dev/null; then
  fail "revoked QuotaCLI credential still uploaded a snapshot"
fi
last_sequence="$($NODE_PATH -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(value.last_sequence));
' "${WORK_DIR}/config/quotacli/edge.json")"
[[ "$last_sequence" == "0" ]] || fail "rejected report advanced the local sequence"

cli_environment \
  "$BUN_PATH" apps/cli/src/main.ts edge unpair \
  >"${WORK_DIR}/unpair.stdout.log" 2>"${WORK_DIR}/unpair.stderr.log"
[[ ! -e "${WORK_DIR}/config/quotacli/edge.json" ]] || fail "QuotaCLI credential remained after unpair"
write_marker "${COORDINATION_DIR}/rejection-confirmed"
wait_for_file "${COORDINATION_DIR}/completed.json" "QuotaBar persistence cleanup"
"$NODE_PATH" -e '
  const fs = require("node:fs");
  const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (result.cleaned !== true) process.exit(1);
' "${COORDINATION_DIR}/completed.json" || fail "QuotaBar did not confirm cleanup"

app_exit_deadline=$((SECONDS + 5))
while kill -0 "$APP_PID" 2>/dev/null && [[ $SECONDS -lt $app_exit_deadline ]]; do
  sleep 0.1
done
kill -0 "$APP_PID" 2>/dev/null && fail "QuotaBar acceptance app did not exit after cleanup"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
cp "$SCREENSHOT_PATH" "${OUTPUT_DIR}/relay-overview.png.tmp"
mv "${OUTPUT_DIR}/relay-overview.png.tmp" "${OUTPUT_DIR}/relay-overview.png"

printf 'Relay owner-path E2E passed: pair → non-empty report → Remote Overview → revoke → reject → restore/cleanup (%sx%s): %s\n' \
  "$pixel_width" "$pixel_height" "${OUTPUT_DIR}/relay-overview.png"
