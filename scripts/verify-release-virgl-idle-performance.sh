#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-}"
vm_path="${2:-}"
enrollment="${3:-}"
output_directory="${4:-}"
duration="${EZVM_VIRGL_IDLE_DURATION:-30}"

fail() {
  echo "verify-release-virgl-idle-performance: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "application not found: $app_path"
[[ -d "$vm_path" ]] || fail "virtual machine not found: $vm_path"
[[ -f "$enrollment" ]] || fail "Guest Agent enrollment not found: $enrollment"
[[ "$output_directory" == /* && -d "$output_directory" && ! -L "$output_directory" ]] || \
  fail "output directory must be an existing, absolute, non-symbolic-link directory"
if ! [[ "$duration" =~ ^[0-9]+$ ]] || (( duration < 25 || duration > 300 )); then
  fail "EZVM_VIRGL_IDLE_DURATION must be between 25 and 300 seconds"
fi

working_directory="$(mktemp -d /tmp/ezvm-virgl-idle-gate.XXXXXX)"
gate_pid=""
cleanup() {
  if [[ -n "$gate_pid" ]] && kill -0 "$gate_pid" 2>/dev/null; then
    kill "$gate_pid" 2>/dev/null || true
    wait "$gate_pid" 2>/dev/null || true
  fi
  rm -rf "$working_directory"
}
trap cleanup EXIT

run_sample() {
  local backend="$1"
  local force_apple="$2"
  local require_virgl="$3"
  local report="$output_directory/$backend-idle.txt"
  local ready="$working_directory/$backend.ready"
  local pid_file="$working_directory/$backend.pid"
  local gate_log="$working_directory/$backend-gate.log"
  local app_pid=""

  EZVM_VM_SMOKE_TIMEOUT="$((duration + 150))" \
  EZVM_RELEASE_SMOKE_ENROLLMENT="$enrollment" \
  EZVM_RELEASE_SMOKE_PID_OUTPUT="$pid_file" \
  EZVM_RELEASE_HOLD_SECONDS="$((duration + 5))" \
  EZVM_RELEASE_HOLD_READY="$ready" \
  EZVM_RELEASE_FORCE_APPLE_GRAPHICS="$force_apple" \
  EZVM_RELEASE_REQUIRE_VIRGL="$require_virgl" \
  EZVM_RELEASE_REQUIRE_MEMORY_BALLOON=1 \
  EZVM_RELEASE_REQUIRE_ENTROPY=1 \
  EZVM_RELEASE_REQUIRE_VIRTIO_SOCKET=1 \
    "$project_root/scripts/verify-release-vm.sh" "$app_path" "$vm_path" >"$gate_log" 2>&1 &
  gate_pid=$!

  for _ in {1..150}; do
    [[ -f "$ready" && -f "$pid_file" ]] && break
    if ! kill -0 "$gate_pid" 2>/dev/null; then
      cat "$gate_log" >&2
      fail "$backend VM exited before the performance hold"
    fi
    sleep 1
  done
  [[ -f "$ready" && -f "$pid_file" ]] || {
    cat "$gate_log" >&2
    fail "$backend VM did not become ready"
  }
  app_pid="$(tr -d '\r\n' < "$pid_file")"
  [[ "$app_pid" =~ ^[1-9][0-9]*$ ]] || fail "$backend VM reported an invalid PID"

  EZVM_VIRGL_PID="$app_pid" \
  EZVM_VIRGL_BACKEND="$backend" \
  EZVM_VIRGL_WORKLOAD="hyprland-idle" \
    "$project_root/scripts/capture-virgl-performance.sh" "$duration" "$report" >/dev/null

  wait "$gate_pid" || {
    cat "$gate_log" >&2
    fail "$backend VM gate failed after capture"
  }
  gate_pid=""
}

run_sample custom-virgl 0 1
run_sample apple-virtio 1 0
"$project_root/scripts/verify-virgl-performance.sh" \
  "$output_directory/custom-virgl-idle.txt" \
  "$output_directory/apple-virtio-idle.txt"

echo "Verified repeatable Custom VirGL versus Apple Virtio idle performance."
