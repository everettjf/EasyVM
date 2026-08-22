#!/bin/bash

set -euo pipefail

app_path="${1:-}"
vm_path="${2:-}"
timeout="${EASYVM_VM_SMOKE_TIMEOUT:-90}"

fail() {
  echo "verify-release-cli: $*" >&2
  exit 1
}

[[ -d "$app_path" && -d "$vm_path" ]] || fail "usage: $0 <EasyVM.app> <smoke-vm>"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive integer"
cli="$app_path/Contents/Helpers/easyvm"
[[ -x "$cli" ]] || fail "CLI executable not found: $cli"

smoke_parent="$(dirname "$vm_path")"
smoke_directory="$(mktemp -d "$smoke_parent/.easyvm-cli-smoke.XXXXXX")"
smoke_vm="$smoke_directory/CLI-Smoke.ezvm"
second_vm="$smoke_directory/CLI-Smoke-Second.ezvm"
cleanup() {
  "$cli" stop "$smoke_vm" --timeout 25 >/dev/null 2>&1 || true
  "$cli" stop "$second_vm" --timeout 25 >/dev/null 2>&1 || true
  rm -rf "$smoke_directory"
}
trap cleanup EXIT

cp -cR "$vm_path" "$smoke_vm"
cp -cR "$vm_path" "$second_vm"
rm -f "$smoke_vm/MachineState.vzvmsave"
rm -f "$second_vm/MachineState.vzvmsave"

"$cli" doctor | ruby -rjson -e 'JSON.parse(STDIN.read)'
"$cli" inspect "$smoke_vm" | ruby -rjson -e 'JSON.parse(STDIN.read)'
"$cli" validate "$smoke_vm" | ruby -rjson -e 'JSON.parse(STDIN.read)'
"$cli" list --root "$smoke_directory" | ruby -rjson -e 'JSON.parse(STDIN.read)'

start_json="$("$cli" start "$smoke_vm" --timeout "$timeout")" || fail "headless start failed: $start_json"
[[ "$start_json" == *'"phase":"running"'* ]] || fail "start did not report running: $start_json"
status_json="$("$cli" status "$smoke_vm")"
[[ "$status_json" == *'"phase":"running"'* ]] || fail "status did not report running: $status_json"

# A second launch of the same bundle must be rejected while a different VM
# can run concurrently. This exercises both single-owner leases and multi-VM
# operation in the signed release artifact.
if duplicate_json="$("$cli" start "$smoke_vm" --timeout 5 2>&1)"; then
  fail "duplicate start unexpectedly succeeded: $duplicate_json"
fi
[[ "$duplicate_json" == *'"code":"already_running"'* ]] || fail "duplicate start returned the wrong error: $duplicate_json"

second_start_json="$("$cli" start "$second_vm" --timeout "$timeout")" || fail "second concurrent start failed: $second_start_json"
[[ "$second_start_json" == *'"phase":"running"'* ]] || fail "second start did not report running: $second_start_json"
second_status_json="$("$cli" status "$second_vm")"
[[ "$second_status_json" == *'"phase":"running"'* ]] || fail "second status did not report running: $second_status_json"

second_stop_json="$("$cli" stop "$second_vm" --timeout 30)" || fail "second headless stop failed: $second_stop_json"
[[ "$second_stop_json" == *'"phase":"stopped"'* ]] || fail "second stop did not report stopped: $second_stop_json"
stop_json="$("$cli" stop "$smoke_vm" --timeout 30)" || fail "headless stop failed: $stop_json"
[[ "$stop_json" == *'"phase":"stopped"'* ]] || fail "stop did not report stopped: $stop_json"

echo "Verified CLI JSON, duplicate-start rejection, and two concurrent real headless VMs."
