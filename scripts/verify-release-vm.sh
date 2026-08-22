#!/bin/bash

set -euo pipefail

app_path="${1:-}"
vm_path="${2:-}"
timeout="${EASYVM_VM_SMOKE_TIMEOUT:-90}"

fail() {
  echo "verify-release-vm: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "application not found: $app_path"
[[ -d "$vm_path" ]] || fail "virtual machine not found: $vm_path"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "EASYVM_VM_SMOKE_TIMEOUT must be a positive integer"

executable="$app_path/Contents/MacOS/EasyVM"
[[ -x "$executable" ]] || fail "application executable not found: $executable"

smoke_parent="$(dirname "$vm_path")"
smoke_directory="$(mktemp -d "$smoke_parent/.easyvm-release-smoke.XXXXXX")"
smoke_vm="$smoke_directory/Smoke.ezvm"
result_file="$smoke_directory/result.txt"
launch_log="$(mktemp "${TMPDIR:-/tmp}/easyvm-vm-smoke-launch.XXXXXX")"
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -rf "$smoke_directory"
  rm -f "$launch_log"
}
trap cleanup EXIT

cp -cR "$vm_path" "$smoke_vm"
rm -f "$smoke_vm/NVRAM" "$smoke_vm/MachineState.vzvmsave"

if [[ "${EASYVM_RELEASE_ENABLE_NESTED:-0}" == "1" ]]; then
  ruby -rjson -e '
    path = ARGV.fetch(0)
    config = JSON.parse(File.read(path))
    features = config["linuxFeatures"] || {}
    features["nestedVirtualizationEnabled"] = true
    config["linuxFeatures"] = features
    File.write(path, JSON.pretty_generate(config) + "\n")
  ' "$smoke_vm/config.json"
fi

EASYVM_RELEASE_SMOKE_VM="$smoke_vm" \
EASYVM_RELEASE_SMOKE_RESULT="$result_file" \
EASYVM_RELEASE_REQUIRE_GUEST_AGENT=1 \
EASYVM_RELEASE_REQUIRE_KVM="${EASYVM_RELEASE_REQUIRE_KVM:-0}" \
  "$executable" >"$launch_log" 2>&1 &
app_pid=$!

for ((second = 1; second <= timeout; second++)); do
  sleep 1
  if [[ -f "$result_file" ]]; then
    result="$(tr -d '\r\n' <"$result_file")"
    if [[ "$result" == "started-and-stopped" ]]; then
      wait "$app_pid" || true
      app_pid=""
      echo "Verified VM boot, Guest Agent authentication, upload/download byte round-trip, and clean stop: $vm_path"
      exit 0
    fi
    cat "$launch_log" >&2
    fail "$result"
  fi
  if ! kill -0 "$app_pid" 2>/dev/null; then
    wait "$app_pid" || exit_code=$?
    cat "$launch_log" >&2
    fail "application exited before the VM result with status ${exit_code:-0}"
  fi
done

cat "$launch_log" >&2
fail "timed out after ${timeout}s waiting for the VM to start and stop"
