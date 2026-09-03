#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/readonly-fixture-guard.sh
source "$project_root/scripts/lib/readonly-fixture-guard.sh"
app_path="${1:-}"
vm_path="${2:-}"
enrollment_file="${EZVM_RELEASE_SMOKE_ENROLLMENT:-}"

fail() {
  echo "verify-release-asif-portability: $*" >&2
  exit 1
}

[[ -d "$app_path" && -x "$app_path/Contents/MacOS/EZVM" ]] || fail "application not found: $app_path"
[[ -d "$vm_path" && -f "$vm_path/config.json" ]] || fail "ASIF fixture not found: $vm_path"
[[ -f "$enrollment_file" ]] || fail "EZVM_RELEASE_SMOKE_ENROLLMENT must name the fixture enrollment file"

fixture_parent="$(dirname "$vm_path")"
work_root="$(mktemp -d "$fixture_parent/.ezvm-asif-portability.XXXXXX")"
source_vm="$work_root/Source.ezvm"
export_path="$work_root/Portable.ezvmexport"
imported_vm="$work_root/Imported.ezvm"
result_file="$(mktemp "${TMPDIR:-/tmp}/ezvm-portability-result.XXXXXX")"
launch_log="$(mktemp "${TMPDIR:-/tmp}/ezvm-portability-launch.XXXXXX")"

cleanup() {
  rm -rf "$work_root"
  rm -f "$result_file" "$launch_log"
}
trap cleanup EXIT

clone_readonly_fixture "$vm_path" "$source_vm"

run_action() {
  local action="$1"
  local input="$2"
  local output="${3:-}"
  local expected="$4"
  rm -f "$result_file"
  if ! open -n -g -W --stdout "$launch_log" --stderr "$launch_log" \
    --env "EZVM_RELEASE_PORTABILITY_ACTION=$action" \
    --env "EZVM_RELEASE_PORTABILITY_INPUT=$input" \
    --env "EZVM_RELEASE_PORTABILITY_OUTPUT=$output" \
    --env "EZVM_RELEASE_PORTABILITY_RESULT=$result_file" \
    "$app_path"; then
    cat "$launch_log" >&2
    fail "$action process exited unexpectedly"
  fi
  [[ -f "$result_file" ]] || fail "$action process did not report a result"
  local result
  result="$(tr -d '\r\n' <"$result_file")"
  [[ "$result" == "$expected" ]] || {
    cat "$launch_log" >&2
    fail "$action failed: $result"
  }
}

run_action export "$source_vm" "$export_path" exported
run_action validate "$export_path" "" validated
run_action import "$export_path" "$imported_vm" imported

cmp "$source_vm/MachineIdentifier" "$imported_vm/MachineIdentifier" >/dev/null || \
  fail "restore import changed the machine identity"
[[ -f "$imported_vm/config.json" && -f "$imported_vm/Disk.asif" ]] || \
  fail "imported fixture is incomplete"

EZVM_RELEASE_REQUIRE_ASIF_STORAGE=1 \
  "$project_root/scripts/verify-release-vm.sh" "$app_path" "$imported_vm"

echo "Verified ASIF export, cross-process validation, restore import, identity preservation, guest boot, and clean stop."
