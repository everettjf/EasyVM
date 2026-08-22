#!/bin/bash

set -euo pipefail

app_path="${1:-}"
vm_path="${2:-}"
timeout="${EASYVM_VM_SMOKE_TIMEOUT:-90}"

fail() {
  echo "verify-release-nested-virtualization: $*" >&2
  exit 1
}

[[ -d "$app_path" && -d "$vm_path" ]] || fail "usage: $0 <EasyVM.app> <smoke-vm>"
cli="$app_path/Contents/Helpers/easyvm"
[[ -x "$cli" ]] || fail "CLI executable not found: $cli"

smoke_parent="$(dirname "$vm_path")"
smoke_directory="$(mktemp -d "$smoke_parent/.easyvm-nested-smoke.XXXXXX")"
smoke_vm="$smoke_directory/Nested-Virtualization-Smoke.ezvm"
cleanup() {
  "$cli" stop "$smoke_vm" --timeout 25 >/dev/null 2>&1 || true
  rm -rf "$smoke_directory"
}
trap cleanup EXIT

cp -cR "$vm_path" "$smoke_vm"
rm -f "$smoke_vm/MachineState.vzvmsave"

ruby -rjson -e '
  path = ARGV.fetch(0)
  config = JSON.parse(File.read(path))
  features = config["linuxFeatures"] || {}
  features["nestedVirtualizationEnabled"] = true
  config["linuxFeatures"] = features
  File.write(path, JSON.pretty_generate(config) + "\n")
' "$smoke_vm/config.json"

"$cli" validate "$smoke_vm" | ruby -rjson -e 'abort "nested flag missing" unless JSON.parse(File.read(ARGV[0])).dig("linuxFeatures", "nestedVirtualizationEnabled") == true' "$smoke_vm/config.json"
start_json="$("$cli" start "$smoke_vm" --timeout "$timeout")" || fail "nested VM start failed: $start_json"
[[ "$start_json" == *'"phase":"running"'* ]] || fail "nested VM did not reach running: $start_json"
stop_json="$("$cli" stop "$smoke_vm" --timeout 30)" || fail "nested VM stop failed: $stop_json"
[[ "$stop_json" == *'"phase":"stopped"'* ]] || fail "nested VM did not stop: $stop_json"

echo "Verified a real Linux VM start/stop with nested virtualization enabled."
