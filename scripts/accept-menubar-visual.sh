#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/menubar-visual/QuotaBarVisual.app"
OUTPUT_DIR="${ROOT_DIR}/dist/menubar-visual/screenshots"
WINDOW_TITLE="QuotaBar Visual QA"
WINDOW_TIMEOUT_SECONDS=15
NO_BUILD=0
APP_PID=""
CURRENT_SCREENSHOT=""

usage() {
  cat <<'EOF'
Usage: accept-menubar-visual.sh [--no-build] [--output-dir <directory>]

Builds and launches the deterministic QuotaBar Visual QA app, then waits for each
fixture window's self-captured PNG (no Screen Recording permission required).
EOF
}

fail() {
  printf 'visual acceptance failed: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

for tool in /usr/bin/swiftc /usr/bin/sips; do
  [[ -x "$tool" ]] || fail "required macOS tool is unavailable: $tool"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-visual-acceptance.XXXXXX")"
WINDOW_FINDER="${WORK_DIR}/find-menubar-visual-window"
SCREENSHOT_VALIDATOR="${WORK_DIR}/validate-menubar-screenshot"

stop_app() {
  if [[ -z "$APP_PID" ]]; then
    return
  fi
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    local attempts=0
    while kill -0 "$APP_PID" 2>/dev/null && [[ $attempts -lt 25 ]]; do
      sleep 0.2
      attempts=$((attempts + 1))
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill -KILL "$APP_PID" 2>/dev/null || true
    fi
  fi
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
}

cleanup() {
  stop_app
  if [[ -n "$CURRENT_SCREENSHOT" ]]; then
    rm -f "$CURRENT_SCREENSHOT"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $NO_BUILD -eq 0 ]]; then
  "${ROOT_DIR}/scripts/package-menubar-visual.sh" >/dev/null
fi

APP_BINARY="${APP_PATH}/Contents/MacOS/QuotaBar"
[[ -x "$APP_BINARY" ]] || fail "visual app is missing; run without --no-build first: $APP_PATH"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

"/usr/bin/swiftc" \
  "${ROOT_DIR}/scripts/find-menubar-visual-window.swift" \
  -o "$WINDOW_FINDER"
"/usr/bin/swiftc" \
  "${ROOT_DIR}/scripts/validate-menubar-screenshot.swift" \
  -o "$SCREENSHOT_VALIDATOR"

# name|fixture|route|appearance|text-size
SCENARIOS=(
  "overview-light|content|overview|light|standard"
  "overview-dark|content|overview|dark|standard"
  "overview-loading|loading|overview|light|standard"
  "overview-cached-error|cached-refresh-error|overview|light|standard"
  "overview-empty|empty|overview|light|standard"
  "overview-unavailable|unavailable|overview|dark|standard"
  "overview-a11y|content|overview|light|accessibility"
  "settings|content|settings|light|standard"
  "agents|content|agents|light|standard"
  "provider-codex|content|provider-codex|light|standard"
  "provider-openrouter|content|provider-openrouter|light|standard"
  "remote-devices|content|remote-devices|dark|standard"
  "pair-device|content|pair-device|light|standard"
  "pair-device-dark|content|pair-device|dark|standard"
  "remote-devices-a11y|content|remote-devices|dark|accessibility"
  "pair-device-a11y|content|pair-device|light|accessibility"
  "settings-a11y|content|settings|light|accessibility"
)

capture_scenario() {
  local scenario="$1"
  local name fixture route appearance text_size
  IFS='|' read -r name fixture route appearance text_size <<<"$scenario"

  local fixed_user_home="${WORK_DIR}/home-${name}"
  local stdout_log="${WORK_DIR}/${name}.stdout.log"
  local stderr_log="${WORK_DIR}/${name}.stderr.log"
  local screenshot="${OUTPUT_DIR}/${name}.png"
  mkdir -p "$fixed_user_home"
  rm -f "$screenshot"
  CURRENT_SCREENSHOT="$screenshot"

  CFFIXED_USER_HOME="$fixed_user_home" \
    "$APP_BINARY" \
      --data-source fixture \
      --fixture "$fixture" \
      --route "$route" \
      --appearance "$appearance" \
      --text-size "$text_size" \
      --screenshot-output "$screenshot" \
      >"$stdout_log" 2>"$stderr_log" &
  APP_PID=$!

  local deadline=$((SECONDS + WINDOW_TIMEOUT_SECONDS))
  local window_info=""
  local saw_png=0
  while [[ $SECONDS -lt $deadline ]]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      if [[ -s "$screenshot" ]]; then
        saw_png=1
        if [[ -n "$window_info" ]]; then
          break
        fi
      fi
      tail -n 20 "$stderr_log" >&2 || true
      fail "${name}: app exited before visual acceptance completed"
    fi
    if [[ -z "$window_info" ]]; then
      if window_info="$($WINDOW_FINDER "$APP_PID" "$WINDOW_TITLE" 2>/dev/null)"; then
        :
      else
        window_info=""
      fi
    fi
    if [[ -s "$screenshot" ]]; then
      saw_png=1
    fi
    if [[ -n "$window_info" && $saw_png -eq 1 ]]; then
      break
    fi
    sleep 0.2
  done

  [[ -n "$window_info" ]] \
    || fail "${name}: window '${WINDOW_TITLE}' did not appear within ${WINDOW_TIMEOUT_SECONDS}s"
  [[ $saw_png -eq 1 ]] \
    || fail "${name}: self-captured screenshot was not written within ${WINDOW_TIMEOUT_SECONDS}s"

  local window_id window_width window_height
  IFS=$'\t' read -r window_id window_width window_height <<<"$window_info"
  [[ "$window_id" =~ ^[0-9]+$ ]] || fail "${name}: invalid window identifier"
  [[ "$window_width" -ge 300 && "$window_height" -ge 300 ]] \
    || fail "${name}: window bounds are unexpectedly small (${window_width}x${window_height})"

  [[ -s "$screenshot" ]] || fail "${name}: screenshot is missing or empty"

  local pixel_width pixel_height byte_count
  pixel_width="$(/usr/bin/sips -g pixelWidth "$screenshot" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
  pixel_height="$(/usr/bin/sips -g pixelHeight "$screenshot" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
  byte_count="$(wc -c <"$screenshot" | tr -d '[:space:]')"
  [[ "$pixel_width" =~ ^[0-9]+$ && "$pixel_height" =~ ^[0-9]+$ ]] \
    || fail "${name}: screenshot dimensions could not be read"
  [[ "$pixel_width" -eq 320 && "$pixel_height" -ge 480 && "$pixel_height" -le 540 ]] \
    || fail "${name}: screenshot dimensions violate the fixed panel contract (${pixel_width}x${pixel_height})"
  [[ "$byte_count" -ge 1024 ]] || fail "${name}: screenshot contains too little image data"
  "$SCREENSHOT_VALIDATOR" "$screenshot" \
    || fail "${name}: screenshot pixel validation failed"

  printf '%s\t%sx%s\n' "$screenshot" "$pixel_width" "$pixel_height"
  CURRENT_SCREENSHOT=""
  stop_app
}

for scenario in "${SCENARIOS[@]}"; do
  capture_scenario "$scenario"
done

for comparison in \
  "overview-light:overview-a11y" \
  "settings:settings-a11y" \
  "remote-devices:remote-devices-a11y" \
  "pair-device:pair-device-a11y"; do
  IFS=':' read -r standard_name accessibility_name <<<"$comparison"
  if cmp -s \
    "${OUTPUT_DIR}/${standard_name}.png" \
    "${OUTPUT_DIR}/${accessibility_name}.png"; then
    fail "${accessibility_name}: accessibility text size did not change rendered pixels"
  fi
done

printf 'visual acceptance passed: %s\n' "$OUTPUT_DIR"
