#!/bin/bash

set -euo pipefail

app_path="${1:-}"
expected_version="${2:-}"
launch_timeout="${EASYVM_LAUNCH_TIMEOUT:-10}"

fail() {
  echo "verify-release-app: $*" >&2
  exit 1
}

[[ -n "$app_path" ]] || fail "usage: $0 <EasyVM.app> [expected-version]"
[[ -d "$app_path" ]] || fail "application not found: $app_path"
[[ "$launch_timeout" =~ ^[1-9][0-9]*$ ]] || fail "EASYVM_LAUNCH_TIMEOUT must be a positive integer"

for command in codesign defaults plutil spctl; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

executable="$app_path/Contents/MacOS/EasyVM"
[[ -x "$executable" ]] || fail "application executable not found: $executable"
cli="$app_path/Contents/Helpers/easyvm"
[[ -x "$cli" ]] || fail "CLI executable not found: $cli"
"$cli" doctor | ruby -rjson -e 'JSON.parse(STDIN.read)'

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

if [[ -n "$expected_version" ]]; then
  actual_version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
  [[ "$actual_version" == "$expected_version" ]] || \
    fail "version is $actual_version, expected $expected_version"
fi

launch_log="$(mktemp "${TMPDIR:-/tmp}/easyvm-launch.XXXXXX")"
ready_dir="$(mktemp -d "${TMPDIR:-/tmp}/easyvm-gui-ready.XXXXXX")"
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

EASYVM_GUI_READY_FILE="$ready_file" "$executable" >"$launch_log" 2>&1 &
app_pid=$!

for ((second = 1; second <= launch_timeout; second++)); do
  for _ in {1..10}; do
    if [[ -f "$ready_file" ]]; then break 2; fi
    sleep 0.1
  done
  if ! kill -0 "$app_pid" 2>/dev/null; then
    wait "$app_pid" || exit_code=$?
    cat "$launch_log" >&2
    fail "application exited during launch with status ${exit_code:-0}"
  fi
done

[[ -f "$ready_file" ]] || { cat "$launch_log" >&2; fail "SwiftUI did not report a visible main window"; }
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong readiness schema" unless value["schemaVersion"] == 1
  abort "main event loop did not respond" unless value["eventLoopResponsive"] == true
  abort "window is not visible" unless value["windowVisible"] == true
  abort "window is too small" unless value["windowWidth"] >= 800 && value["windowHeight"] >= 600
  abort "wrong bundle" unless value["bundleIdentifier"] == "com.everettjf.easyvm"
' "$ready_file"

process_command="$(ps -p "$app_pid" -o command=)"
[[ "$process_command" == *"/Contents/MacOS/EasyVM"* ]] || \
  fail "unexpected process after launch: $process_command"

echo "Verified EasyVM release app: signature, Gatekeeper, version, entitlement allowlist, and a visible SwiftUI main window."
