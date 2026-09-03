#!/bin/bash

set -euo pipefail

app_path="${1:-}"
expected_version="${2:-}"
expected_revision="${3:-${EZVM_EXPECTED_SOURCE_REVISION:-}}"
launch_timeout="${EZVM_LAUNCH_TIMEOUT:-10}"

fail() {
  echo "verify-release-app: $*" >&2
  exit 1
}

[[ -n "$app_path" ]] || fail "usage: $0 <EZVM.app> [expected-version]"
[[ -d "$app_path" ]] || fail "application not found: $app_path"
[[ "$launch_timeout" =~ ^[1-9][0-9]*$ ]] || fail "EZVM_LAUNCH_TIMEOUT must be a positive integer"

for command in codesign defaults open osascript pgrep plutil ps spctl; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

executable="$app_path/Contents/MacOS/EZVM"
[[ -x "$executable" ]] || fail "application executable not found: $executable"
cli="$app_path/Contents/Helpers/ezvm"
[[ -x "$cli" ]] || fail "CLI executable not found: $cli"
"$cli" doctor | ruby -rjson -e 'JSON.parse(STDIN.read)'

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

"$(dirname "$0")/verify-release-metadata.sh" \
  "$app_path" "$expected_version" "$expected_revision" clean

launch_log="$(mktemp "${TMPDIR:-/tmp}/ezvm-launch.XXXXXX")"
ready_dir="$(mktemp -d "${TMPDIR:-/tmp}/ezvm-gui-ready.XXXXXX")"
ready_file="$ready_dir/ready.json"
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -f "$launch_log" "$ready_file"
  rmdir "$ready_dir" 2>/dev/null || true
}
trap cleanup EXIT

"$(dirname "$0")/verify-production-entitlements.sh" "$app_path"

# Launch through Launch Services so macOS applies the same sandbox extensions
# as a normal Finder/Homebrew launch. Track the newly created process even when
# it never reaches the readiness marker, so the cleanup trap can still stop it.
existing_pids="$(pgrep -x EZVM 2>/dev/null | tr '\n' ' ' || true)"
[[ -z "${existing_pids// /}" ]] || \
  fail "another EZVM instance is running; quit it before release verification"
open -n --stdout "$launch_log" --stderr "$launch_log" \
  --env "EZVM_GUI_READY_FILE=$ready_file" "$app_path"

find_new_app_pid() {
  local pid
  for pid in $(pgrep -x EZVM 2>/dev/null || true); do
    if [[ "$existing_pids" != *" $pid "* ]]; then
      printf '%s\n' "$pid"
      return
    fi
  done
}

for _ in {1..50}; do
  app_pid="$(find_new_app_pid)"
  [[ -n "$app_pid" ]] && break
  sleep 0.1
done
[[ -n "$app_pid" ]] || { cat "$launch_log" >&2; fail "Launch Services did not start EZVM"; }

# SwiftUI can restore the persisted state where every window was closed.
# A normal second click on the app sends reopen/activate, so exercise that
# public lifecycle path before requiring a visible Control Center window.
osascript \
  -e 'tell application id "com.everettjf.ezvm" to reopen' \
  -e 'tell application id "com.everettjf.ezvm" to activate'

for ((second = 1; second <= launch_timeout; second++)); do
  for _ in {1..10}; do
    if [[ -z "$app_pid" ]]; then app_pid="$(find_new_app_pid)"; fi
    if [[ -f "$ready_file" ]]; then break 2; fi
    sleep 0.1
  done
done

[[ -f "$ready_file" ]] || { cat "$launch_log" >&2; fail "SwiftUI did not report a visible main window"; }
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong readiness schema" unless value["schemaVersion"] == 1
  abort "main event loop did not respond" unless value["eventLoopResponsive"] == true
  abort "window is not visible" unless value["windowVisible"] == true
  abort "window is too small" unless value["windowWidth"] >= 800 && value["windowHeight"] >= 600
  abort "wrong bundle" unless value["bundleIdentifier"] == "com.everettjf.ezvm"
' "$ready_file"

app_pid="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("pid")' "$ready_file")"
kill -0 "$app_pid" 2>/dev/null || { cat "$launch_log" >&2; fail "application exited after reporting GUI readiness"; }

process_command="$(ps -p "$app_pid" -o command=)"
[[ "$process_command" == *"/Contents/MacOS/EZVM"* ]] || \
  fail "unexpected process after launch: $process_command"

echo "Verified EZVM release app: signature, Gatekeeper, version, entitlement allowlist, and a visible SwiftUI main window."
