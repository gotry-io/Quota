#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/menubar-visual/QuotaBarVisual.app"
APP_BINARY="${APP_PATH}/Contents/MacOS/QuotaBar"
REPORT_FIXTURE="${ROOT_DIR}/apps/cli/test/fixtures/relay-controller-e2e-report.json"
REPORT_RUNNER="${ROOT_DIR}/apps/cli/test/support/edge-report-e2e.ts"
MANAGED_RELAY_SERVER="${ROOT_DIR}/apps/relay/test/support/managed-relay-e2e.ts"
OUTPUT_DIR="${ROOT_DIR}/dist/menubar-relay-e2e"
TIMEOUT_SECONDS=30
APP_PID=""
CLI_PID=""
RELAY_PID=""
WORK_DIR=""
CURRENT_MODE=""

usage() {
  cat <<'EOF'
Usage: test-relay-controller-e2e.sh [--mode self-hosted|managed]

Runs the real QuotaBar controller path against loopback QuotaRelay instances and
isolated QuotaCLI edge state. With no --mode, self-hosted and managed run in order.
The LaunchServices-started Visual App uses production URLSession, Relay state,
Defaults, and Keychain boundaries. No provider credentials are read. Screenshots
are written to dist/menubar-relay-e2e.
EOF
}

fail() {
  local prefix="relay controller e2e"
  if [[ -n "$CURRENT_MODE" ]]; then
    prefix="${prefix} (${CURRENT_MODE})"
  fi
  printf '%s failed: %s\n' "$prefix" "$1" >&2
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
  APP_PID=""
  CLI_PID=""
  RELAY_PID=""
  WORK_DIR=""
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

REQUESTED_MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --mode)
    [[ $# -ge 2 ]] || fail "--mode requires self-hosted or managed"
    REQUESTED_MODE="$2"
    shift 2
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    fail "unknown argument: $1"
    ;;
  esac
done
if [[ -n "$REQUESTED_MODE" && "$REQUESTED_MODE" != "self-hosted" && "$REQUESTED_MODE" != "managed" ]]; then
  fail "--mode must be self-hosted or managed"
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "this E2E requires macOS (QuotaBar + Keychain)"

BUN_PATH="$(command -v bun || true)"
NODE_PATH="$(command -v node || true)"
[[ -x "$BUN_PATH" ]] || fail "bun is required on PATH"
[[ -x "$NODE_PATH" ]] || fail "node is required on PATH"
for tool in /usr/bin/openssl /usr/bin/open /usr/bin/sips /usr/bin/swiftc; do
  [[ -x "$tool" ]] || fail "required macOS tool is unavailable: $tool"
done
for support_file in "$REPORT_FIXTURE" "$REPORT_RUNNER" "$MANAGED_RELAY_SERVER"; do
  [[ -f "$support_file" ]] || fail "E2E support file is missing: $support_file"
done

cd "$ROOT_DIR"
./scripts/package-menubar-visual.sh >/dev/null
[[ -x "$APP_BINARY" ]] || fail "QuotaBar Visual App was not built"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

run_mode() {
  CURRENT_MODE="$1"
  APP_PID=""
  CLI_PID=""
  RELAY_PID=""
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quota-relay-controller-e2e.${CURRENT_MODE}.XXXXXX")"
  chmod 700 "$WORK_DIR"
  mkdir -m 700 \
    "${WORK_DIR}/coordination" \
    "${WORK_DIR}/config" \
    "${WORK_DIR}/home" \
    "${WORK_DIR}/empty-bin" \
    "${WORK_DIR}/codex" \
    "${WORK_DIR}/claude" \
    "${WORK_DIR}/grok"

  local run_id
  local controller_token=""
  local controller_token_file=""
  local defaults_suite
  local keychain_service
  local coordination_dir="${WORK_DIR}/coordination"
  local screenshot_path="${WORK_DIR}/relay-overview.png"
  run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  defaults_suite="io.gotry.quotabar.e2e.${run_id}"
  keychain_service="io.gotry.quotabar.relay-controller.e2e.${run_id}"

  if [[ "$CURRENT_MODE" == "self-hosted" ]]; then
    controller_token="$(/usr/bin/openssl rand -hex 32)"
    controller_token_file="${WORK_DIR}/controller-token"
    printf '%s' "$controller_token" >"$controller_token_file"
    chmod 600 "$controller_token_file"
    HOST=127.0.0.1 \
      PORT=0 \
      QUOTA_RELAY_CONTROLLER_TOKEN="$controller_token" \
      QUOTA_RELAY_DATABASE_PATH="${WORK_DIR}/relay.db" \
      QUOTA_RELAY_INSTANCE_ID="self-hosted-controller-e2e-${run_id}" \
      "$BUN_PATH" apps/relay/src/self-hosted.ts \
      >"${WORK_DIR}/relay.stdout.log" 2>"${WORK_DIR}/relay.stderr.log" &
  else
    HOST=127.0.0.1 \
      PORT=0 \
      QUOTA_RELAY_DATABASE_PATH="${WORK_DIR}/relay.db" \
      QUOTA_RELAY_INSTANCE_ID="managed-controller-e2e-${run_id}" \
      "$BUN_PATH" "$MANAGED_RELAY_SERVER" \
      >"${WORK_DIR}/relay.stdout.log" 2>"${WORK_DIR}/relay.stderr.log" &
  fi
  RELAY_PID=$!

  local relay_origin=""
  local relay_deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [[ $SECONDS -lt $relay_deadline ]]; do
    if ! kill -0 "$RELAY_PID" 2>/dev/null; then
      fail "QuotaRelay exited before becoming ready"
    fi
    relay_origin="$(
      sed -nE 's/.*listening on 127\.0\.0\.1:([0-9]+).*/http:\/\/127.0.0.1:\1/p' \
        "${WORK_DIR}/relay.stdout.log" | tail -n 1
    )"
    [[ -n "$relay_origin" ]] && break
    sleep 0.1
  done
  [[ -n "$relay_origin" ]] || fail "QuotaRelay did not publish its loopback origin"

  local app_arguments=(
    --data-source fixture
    --fixture loading
    --route overview
    --appearance light
    --text-size standard
    --screenshot-output "$screenshot_path"
    --relay-acceptance-mode "$CURRENT_MODE"
    --relay-acceptance-origin "$relay_origin"
    --relay-acceptance-directory "$coordination_dir"
    --relay-acceptance-defaults-suite "$defaults_suite"
    --relay-acceptance-keychain-service "$keychain_service"
  )
  if [[ "$CURRENT_MODE" == "self-hosted" ]]; then
    app_arguments+=(--relay-acceptance-controller-token-file "$controller_token_file")
  fi
  /usr/bin/open -n "$APP_PATH" --args "${app_arguments[@]}"

  wait_for_file "${coordination_dir}/app.pid" "QuotaBar process identity"
  APP_PID="$(<"${coordination_dir}/app.pid")"
  [[ "$APP_PID" =~ ^[0-9]+$ ]] || fail "QuotaBar returned an invalid process identifier"
  local app_command
  app_command="$(ps -p "$APP_PID" -o command= 2>/dev/null || true)"
  [[ "$app_command" == *"$APP_BINARY"* ]] || fail "QuotaBar process identity did not match the app bundle"
  wait_for_file "${coordination_dir}/ready.json" "QuotaBar Relay profile and Keychain persistence"
  "$NODE_PATH" -e '
    const fs = require("node:fs");
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (result.mode !== process.argv[2]) process.exit(1);
  ' "${coordination_dir}/ready.json" "$CURRENT_MODE" || fail "QuotaBar registered the wrong Relay mode"

  cli_environment \
    "$BUN_PATH" apps/cli/src/main.ts edge pair --relay "$relay_origin" \
    >"${WORK_DIR}/pair.stdout.log" 2>"${WORK_DIR}/pair.stderr.log" &
  CLI_PID=$!

  local pairing_code=""
  local pairing_deadline=$((SECONDS + TIMEOUT_SECONDS))
  while [[ $SECONDS -lt $pairing_deadline ]]; do
    pairing_code="$(sed -n 's/^Pairing code: //p' "${WORK_DIR}/pair.stdout.log" | tail -n 1)"
    [[ -n "$pairing_code" ]] && break
    if ! kill -0 "$CLI_PID" 2>/dev/null; then
      fail "QuotaCLI exited before publishing a pairing code"
    fi
    sleep 0.1
  done
  [[ -n "$pairing_code" ]] || fail "QuotaCLI did not publish a pairing code"
  printf '%s' "$pairing_code" >"${coordination_dir}/pairing-code.txt.tmp"
  mv "${coordination_dir}/pairing-code.txt.tmp" "${coordination_dir}/pairing-code.txt"
  wait_for_file "${coordination_dir}/pairing-approved" "QuotaBar pairing approval"

  local pair_exit_deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "$CLI_PID" 2>/dev/null && [[ $SECONDS -lt $pair_exit_deadline ]]; do
    sleep 0.1
  done
  kill -0 "$CLI_PID" 2>/dev/null && fail "QuotaCLI pairing did not finish"
  local pair_status
  if wait "$CLI_PID"; then
    pair_status=0
  else
    pair_status=$?
  fi
  CLI_PID=""
  [[ $pair_status -eq 0 ]] || fail "QuotaCLI pairing failed"
  rg -F "Pairing complete." "${WORK_DIR}/pair.stdout.log" >/dev/null \
    || fail "QuotaCLI did not confirm pairing"
  if [[ -n "$controller_token" ]] && \
    rg -F "$controller_token" "${WORK_DIR}/pair.stdout.log" "${WORK_DIR}/pair.stderr.log" >/dev/null; then
    fail "QuotaCLI pairing output exposed the controller credential"
  fi

  local report_status
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
  write_marker "${coordination_dir}/report-ready"

  wait_for_file "${coordination_dir}/snapshot.json" "QuotaBar remote Overview state"
  wait_for_file "$screenshot_path" "QuotaBar remote Overview screenshot"
  "$NODE_PATH" -e '
    const fs = require("node:fs");
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (result.provider !== "codex" || result.fingerprint !== "e2e-codex-account" ||
        result.window_id !== "five_hour" || result.used_percent !== 42 ||
        result.remaining_percent !== 58 || result.source !== "Remote" || result.restored !== true) {
      process.exit(1);
    }
  ' "${coordination_dir}/snapshot.json" || fail "QuotaBar returned an invalid remote Overview result"

  local window_finder="${WORK_DIR}/find-menubar-visual-window"
  /usr/bin/swiftc scripts/find-menubar-visual-window.swift -o "$window_finder"
  local window_info
  window_info="$($window_finder "$APP_PID" "QuotaBar Visual QA")" \
    || fail "QuotaBar acceptance window was not discoverable by exact PID"
  local window_id
  local window_width
  local window_height
  IFS=$'\t' read -r window_id window_width window_height <<<"$window_info"
  [[ "$window_id" =~ ^[0-9]+$ && "$window_width" -ge 300 && "$window_height" -ge 300 ]] \
    || fail "QuotaBar acceptance window bounds were invalid"
  local pixel_width
  local pixel_height
  pixel_width="$(/usr/bin/sips -g pixelWidth "$screenshot_path" | awk '/pixelWidth:/ { print $2 }')"
  pixel_height="$(/usr/bin/sips -g pixelHeight "$screenshot_path" | awk '/pixelHeight:/ { print $2 }')"
  [[ "$pixel_width" -ge 300 && "$pixel_height" -ge 300 ]] \
    || fail "QuotaBar acceptance screenshot dimensions were invalid"

  write_marker "${coordination_dir}/revoke-request"
  wait_for_file "${coordination_dir}/revoked" "QuotaBar device revocation"

  local rejected_status
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
  local last_sequence
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
  write_marker "${coordination_dir}/rejection-confirmed"
  wait_for_file "${coordination_dir}/completed.json" "QuotaBar local and remote cleanup"
  "$NODE_PATH" -e '
    const fs = require("node:fs");
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (result.cleaned !== true || result.mode !== process.argv[2]) process.exit(1);
  ' "${coordination_dir}/completed.json" "$CURRENT_MODE" || fail "QuotaBar did not confirm cleanup"

  local app_exit_deadline=$((SECONDS + 5))
  while kill -0 "$APP_PID" 2>/dev/null && [[ $SECONDS -lt $app_exit_deadline ]]; do
    sleep 0.1
  done
  kill -0 "$APP_PID" 2>/dev/null && fail "QuotaBar acceptance app did not exit after cleanup"
  APP_PID=""

  local output_path="${OUTPUT_DIR}/${CURRENT_MODE}-relay-overview.png"
  cp "$screenshot_path" "${output_path}.tmp"
  mv "${output_path}.tmp" "$output_path"

  stop_process "$RELAY_PID"
  RELAY_PID=""
  local completed_work_dir="$WORK_DIR"
  rm -rf "$completed_work_dir"
  WORK_DIR=""
  [[ ! -e "$completed_work_dir" ]] || fail "temporary E2E state was not removed"

  printf 'Relay controller E2E passed (%s): pair → non-empty report → Remote Overview → device revoke → reject → CLI unpair → controller/local cleanup (%sx%s): %s\n' \
    "$CURRENT_MODE" "$pixel_width" "$pixel_height" "$output_path"
}

if [[ -n "$REQUESTED_MODE" ]]; then
  run_mode "$REQUESTED_MODE"
else
  run_mode self-hosted
  run_mode managed
fi
