#!/bin/bash

set -euo pipefail

app_path="${1:-}"
vm_path="${2:-}"
timeout="${EZVM_VM_SMOKE_TIMEOUT:-90}"

fail() {
  echo "verify-release-cli: $*" >&2
  exit 1
}

[[ -d "$app_path" && -d "$vm_path" ]] || fail "usage: $0 <EZVM.app> <smoke-vm>"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive integer"
cli="$app_path/Contents/Helpers/ezvm"
[[ -x "$cli" ]] || fail "CLI executable not found: $cli"
guest_type="$(ruby -rjson -e 'puts JSON.parse(File.read(File.join(ARGV.fetch(0), "config.json"))).fetch("type")' "$vm_path")" \
  || fail "could not read the guest type from $vm_path/config.json"
[[ "$guest_type" == "linux" || "$guest_type" == "macOS" ]] \
  || fail "unsupported guest type in fixture: $guest_type"

smoke_parent="$(dirname "$vm_path")"
smoke_directory="$(mktemp -d "$smoke_parent/.ezvm-cli-smoke.XXXXXX")"
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

# Abrupt host termination must never strand a lease or make the next boot
# depend on process cleanup that did not run.
crash_start_json="$("$cli" start "$smoke_vm" --timeout "$timeout")" || fail "pre-crash start failed: $crash_start_json"
crash_pid="$(ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("result", "pid")' <<<"$crash_start_json")"
[[ "$crash_pid" =~ ^[1-9][0-9]*$ ]] || fail "start did not return a runtime PID: $crash_start_json"
kill -KILL "$crash_pid"
for _ in {1..100}; do
  kill -0 "$crash_pid" >/dev/null 2>&1 || break
  sleep 0.1
done
kill -0 "$crash_pid" >/dev/null 2>&1 && fail "SIGKILL did not terminate runtime PID $crash_pid"
restart_json="$("$cli" start "$smoke_vm" --timeout "$timeout")" || fail "restart after SIGKILL failed: $restart_json"
[[ "$restart_json" == *'"phase":"running"'* ]] || fail "restart after SIGKILL did not report running: $restart_json"
"$cli" stop "$smoke_vm" --timeout 30 >/dev/null || fail "stop after SIGKILL restart failed"

# A corrupt saved state is disposable. EZVM must rebuild its VZVirtualMachine
# instance and cold boot rather than present a persistent restore error.
cp "$smoke_vm/config.json" "$smoke_vm/MachineState.vzvmsave"
saved_state_json="$("$cli" start "$smoke_vm" --timeout "$timeout")" || fail "cold boot after corrupt saved state failed: $saved_state_json"
[[ "$saved_state_json" == *'"phase":"running"'* ]] || fail "saved-state fallback did not report running: $saved_state_json"
[[ ! -e "$smoke_vm/MachineState.vzvmsave" ]] || fail "corrupt saved state was not discarded"
"$cli" stop "$smoke_vm" --timeout 30 >/dev/null || fail "stop after saved-state fallback failed"

# Reproduce the exact Virtualization.framework EFI failure seen in Linux
# guests. macOS guests use VZMacAuxiliaryStorage rather than an EFI variable
# store, so creating a synthetic NVRAM file there would test nothing and make
# the three-guest matrix fail for the wrong reason.
if [[ "$guest_type" == "linux" ]]; then
  truncate -s 0 "$second_vm/NVRAM"
  efi_recovery_json="$("$cli" start "$second_vm" --timeout "$timeout")" || fail "EFI recovery start failed: $efi_recovery_json"
  [[ "$efi_recovery_json" == *'"phase":"running"'* ]] || fail "EFI recovery did not report running: $efi_recovery_json"
  [[ -s "$second_vm/NVRAM" && -e "$second_vm/NVRAM.invalid-backup" ]] || fail "EFI recovery did not replace and back up NVRAM"
  "$cli" stop "$second_vm" --timeout 30 >/dev/null || fail "stop after EFI recovery failed"
fi

if [[ "$guest_type" == "linux" ]]; then
  echo "Verified CLI JSON, concurrent VMs, SIGKILL restart, saved-state fallback, and EFI boot recovery."
else
  echo "Verified CLI JSON, concurrent VMs, SIGKILL restart, and saved-state fallback."
fi
