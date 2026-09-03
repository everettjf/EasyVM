#!/bin/bash

set -euo pipefail

app_path=${1:-}
expected_version=${2:-}
expected_revision=${3:-}
launch_timeout=${EZVM_OMARCHY_LAUNCH_TIMEOUT:-10}

fail() {
  echo "verify-omarchy-release-gui: $*" >&2
  exit 1
}

[[ -d $app_path && ! -L $app_path ]] || fail "usage: $0 <EZVM Omarchy.app> [version] [revision]"
[[ $launch_timeout =~ ^[1-9][0-9]*$ ]] || fail "EZVM_OMARCHY_LAUNCH_TIMEOUT must be a positive integer"
executable="$app_path/Contents/MacOS/EZVM Omarchy"
[[ -x $executable ]] || fail "application executable is missing"

"$(dirname -- "$0")/verify-omarchy-release-app.sh" \
  "$app_path" "$expected_version" "$expected_revision" clean
spctl --assess --type execute --verbose=4 "$app_path"

existing_pids=$(pgrep -x 'EZVM Omarchy' 2>/dev/null | tr '\n' ' ' || true)
[[ -z ${existing_pids// /} ]] || fail "another EZVM Omarchy instance is running"
launch_log=$(mktemp "${TMPDIR:-/tmp}/ezvm-omarchy-launch.XXXXXX")
ready_dir=$(mktemp -d "${TMPDIR:-/tmp}/ezvm-omarchy-ready.XXXXXX")
ready_file="$ready_dir/ready.json"
app_pid=
cleanup() {
  if [[ -n $app_pid ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -f "$launch_log" "$ready_file"
  rmdir "$ready_dir" 2>/dev/null || true
}
trap cleanup EXIT

open -n --stdout "$launch_log" --stderr "$launch_log" \
  --env "EZVM_OMARCHY_GUI_READY_FILE=$ready_file" "$app_path"
for ((tick = 0; tick < launch_timeout * 10; tick++)); do
  if [[ -z $app_pid ]]; then
    for pid in $(pgrep -x 'EZVM Omarchy' 2>/dev/null || true); do
      [[ " $existing_pids " == *" $pid "* ]] || { app_pid=$pid; break; }
    done
  fi
  [[ -f $ready_file ]] && break
  sleep 0.1
done
[[ -f $ready_file ]] || { cat "$launch_log" >&2; fail "SwiftUI did not report a visible main window"; }

ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong readiness schema" unless value["schemaVersion"] == 1
  abort "wrong bundle" unless value["bundleIdentifier"] == "com.everettjf.ezvm.omarchy"
  abort "main event loop did not respond" unless value["eventLoopResponsive"] == true
  abort "window is not visible" unless value["windowVisible"] == true
  abort "window is too small" unless value["windowWidth"] >= 820 && value["windowHeight"] >= 600
' "$ready_file"
reported_pid=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("pid")' "$ready_file")
[[ $reported_pid == "$app_pid" ]] || fail "readiness came from an unexpected process"
kill -0 "$app_pid" 2>/dev/null || { cat "$launch_log" >&2; fail "application exited after readiness"; }

echo "Verified EZVM Omarchy signature, Gatekeeper acceptance, and visible SwiftUI window."
