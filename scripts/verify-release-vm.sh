#!/bin/bash

set -euo pipefail

app_path="${1:-}"
vm_path="${2:-}"
timeout="${EZVM_VM_SMOKE_TIMEOUT:-90}"

fail() {
  echo "verify-release-vm: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "application not found: $app_path"
[[ -d "$vm_path" ]] || fail "virtual machine not found: $vm_path"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "EZVM_VM_SMOKE_TIMEOUT must be a positive integer"
enrollment_file="${EZVM_RELEASE_SMOKE_ENROLLMENT:-}"
[[ -n "$enrollment_file" && -f "$enrollment_file" ]] || fail "EZVM_RELEASE_SMOKE_ENROLLMENT must name the fixture enrollment file"
permissions="$(stat -f '%Lp' "$enrollment_file")"
[[ "$permissions" == "600" ]] || fail "fixture enrollment must have mode 600 (found $permissions)"

executable="$app_path/Contents/MacOS/EZVM"
[[ -x "$executable" ]] || fail "application executable not found: $executable"

smoke_parent="$(dirname "$vm_path")"
smoke_directory="$(mktemp -d "$smoke_parent/.ezvm-release-smoke.XXXXXX")"
smoke_vm="$smoke_directory/Smoke.ezvm"
result_file="$smoke_directory/result.txt"
pid_file="$smoke_directory/pid.txt"
launch_log="$(mktemp "${TMPDIR:-/tmp}/ezvm-vm-smoke-launch.XXXXXX")"
app_pid=""
open_pid=""
cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -n "$open_pid" ]] && kill -0 "$open_pid" 2>/dev/null; then
    kill "$open_pid" 2>/dev/null || true
    wait "$open_pid" 2>/dev/null || true
  fi
  if [[ "${EZVM_KEEP_SMOKE_ARTIFACTS:-0}" == "1" ]]; then
    echo "verify-release-vm: retained VM clone at $smoke_vm" >&2
    echo "verify-release-vm: retained launch log at $launch_log" >&2
  else
    rm -rf "$smoke_directory"
    rm -f "$launch_log"
  fi
}
trap cleanup EXIT

cp -cR "$vm_path" "$smoke_vm"
rm -f "$smoke_vm/NVRAM" "$smoke_vm/MachineState.vzvmsave"

if [[ "${EZVM_RELEASE_ENABLE_NESTED:-0}" == "1" ]]; then
  ruby -rjson -e '
    path = ARGV.fetch(0)
    config = JSON.parse(File.read(path))
    features = config["linuxFeatures"] || {}
    features["nestedVirtualizationEnabled"] = true
    config["linuxFeatures"] = features
    File.write(path, JSON.pretty_generate(config) + "\n")
  ' "$smoke_vm/config.json"
fi

open -n -g -W --stdout "$launch_log" --stderr "$launch_log" \
  --env "EZVM_RELEASE_SMOKE_VM=$smoke_vm" \
  --env "EZVM_RELEASE_SMOKE_RESULT=$result_file" \
  --env "EZVM_RELEASE_SMOKE_PID=$pid_file" \
  --env "EZVM_RELEASE_REQUIRE_GUEST_AGENT=1" \
  --env "EZVM_RELEASE_REQUIRE_KVM=${EZVM_RELEASE_REQUIRE_KVM:-0}" \
  --env "EZVM_RELEASE_REQUIRE_VIRGL=${EZVM_RELEASE_REQUIRE_VIRGL:-0}" \
  --env "EZVM_RELEASE_REQUIRE_MEMORY_BALLOON=${EZVM_RELEASE_REQUIRE_MEMORY_BALLOON:-0}" \
  --env "EZVM_RELEASE_REQUIRE_ENTROPY=${EZVM_RELEASE_REQUIRE_ENTROPY:-0}" \
  --env "EZVM_RELEASE_REQUIRE_VIRTIO_SOCKET=${EZVM_RELEASE_REQUIRE_VIRTIO_SOCKET:-0}" \
  --env "EZVM_RELEASE_REQUIRE_ASIF_STORAGE=${EZVM_RELEASE_REQUIRE_ASIF_STORAGE:-0}" \
  --env "EZVM_RELEASE_AGENT_ENROLLMENT_FILE=$enrollment_file" \
  "$app_path" &
open_pid=$!

for ((second = 1; second <= timeout; second++)); do
  sleep 1
  if [[ -z "$app_pid" && -f "$pid_file" ]]; then
    app_pid="$(tr -d '\r\n' <"$pid_file")"
    [[ "$app_pid" =~ ^[1-9][0-9]*$ ]] || fail "application reported an invalid process ID"
  fi
  if [[ -f "$result_file" ]]; then
    result="$(tr -d '\r\n' <"$result_file")"
    if [[ "$result" == "started-and-stopped" ]]; then
      wait "$open_pid" || true
      open_pid=""
      echo "Verified VM boot, Guest Agent authentication, upload/download byte round-trip, and clean stop: $vm_path"
      exit 0
    fi
    cat "$launch_log" >&2
    fail "$result"
  fi
  if [[ -n "$app_pid" ]] && ! kill -0 "$app_pid" 2>/dev/null; then
    cat "$launch_log" >&2
    fail "application exited before writing the VM result"
  fi
  if ! kill -0 "$open_pid" 2>/dev/null; then
    wait "$open_pid" || exit_code=$?
    cat "$launch_log" >&2
    fail "application exited before the VM result with status ${exit_code:-0}"
  fi
done

cat "$launch_log" >&2
fail "timed out after ${timeout}s waiting for the VM to start and stop"
