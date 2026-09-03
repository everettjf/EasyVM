#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-}"
vm_path="${2:-}"
enrollment_file="${EZVM_RELEASE_SMOKE_ENROLLMENT:-}"

fail() {
  echo "verify-release-asif-snapshot: $*" >&2
  exit 1
}

[[ -d "$app_path" && -d "$vm_path" ]] || fail "usage: $0 <EZVM.app> <asif-linux-vm>"
[[ -f "$vm_path/config.json" ]] || fail "fixture has no config.json: $vm_path"
[[ -f "$enrollment_file" ]] || fail "EZVM_RELEASE_SMOKE_ENROLLMENT must name the fixture enrollment file"

fixture_parent="$(dirname "$vm_path")"
fixture_root="$(mktemp -d "$fixture_parent/.ezvm-asif-snapshot-fixture.XXXXXX")"
fixture="$fixture_root/ASIF-Snapshot.ezvm"
result_file="$(mktemp "${TMPDIR:-/tmp}/ezvm-asif-snapshot-result.XXXXXX")"
launch_log="$(mktemp "${TMPDIR:-/tmp}/ezvm-asif-snapshot-launch.XXXXXX")"
cleanup() {
  rm -rf "$fixture_root"
  rm -f "$result_file" "$launch_log"
}
trap cleanup EXIT

cp -cR "$vm_path" "$fixture"

run_action() {
  local action="$1"
  local snapshot_id="${2:-}"
  rm -f "$result_file"
  if ! open -n -g -W --stdout "$launch_log" --stderr "$launch_log" \
    --env "EZVM_RELEASE_SNAPSHOT_ACTION=$action" \
    --env "EZVM_RELEASE_SNAPSHOT_VM=$fixture" \
    --env "EZVM_RELEASE_SNAPSHOT_RESULT=$result_file" \
    --env "EZVM_RELEASE_SNAPSHOT_ID=$snapshot_id" \
    "$app_path"; then
    cat "$launch_log" >&2
    fail "$action process exited unexpectedly"
  fi
  [[ -f "$result_file" ]] || {
    cat "$launch_log" >&2
    fail "$action process did not report a result"
  }
  local result
  result="$(tr -d '\r\n' <"$result_file")"
  [[ "$result" != failed:* ]] || {
    cat "$launch_log" >&2
    fail "$result"
  }
  printf '%s\n' "$result"
}

create_result="$(run_action create)"
[[ "$create_result" == created:* ]] || fail "unexpected create result: $create_result"
snapshot_id="${create_result#created:}"
[[ "$snapshot_id" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "invalid snapshot identifier: $snapshot_id"
[[ "$(run_action audit "$snapshot_id")" == "audited" ]] || fail "cross-process audit failed"
[[ "$(run_action restore "$snapshot_id")" == "restored" ]] || fail "cross-process restore failed"

EZVM_RELEASE_REQUIRE_ASIF_STORAGE=1 \
  "$project_root/scripts/verify-release-vm.sh" "$app_path" "$fixture"

echo "Verified ASIF snapshot creation, cross-process audit and restore, guest boot, and clean stop."
