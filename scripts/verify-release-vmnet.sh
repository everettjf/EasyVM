#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-}"
vm_path="${2:-}"
enrollment_file="${EZVM_RELEASE_SMOKE_ENROLLMENT:-}"

fail() {
  echo "verify-release-vmnet: $*" >&2
  exit 1
}

[[ -d "$app_path" && -d "$vm_path" ]] || fail "usage: $0 <EZVM.app> <linux-vm>"
[[ -f "$vm_path/config.json" ]] || fail "fixture has no config.json: $vm_path"
[[ -f "$enrollment_file" ]] || fail "EZVM_RELEASE_SMOKE_ENROLLMENT must name the fixture enrollment file"

fixture_parent="$(dirname "$vm_path")"
fixture_root="$(mktemp -d "$fixture_parent/.ezvm-vmnet-fixture.XXXXXX")"
fixture="$fixture_root/VMNet-Shared.ezvm"
cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

cp -cR "$vm_path" "$fixture"
ruby -rjson -e '
  path = File.join(ARGV.fetch(0), "config.json")
  config = JSON.parse(File.read(path))
  abort "VMNet release fixture must be Linux" unless config["type"] == "linux"
  config["name"] = "#{config["name"]} · VMNet Shared"
  config["networkDevices"] = [{
    "type" => "VMNetShared",
    "networkIdentifier" => "ezvm-release-shared",
    "portForwardingRules" => []
  }]
  File.write(path, JSON.pretty_generate(config) + "\n")
' "$fixture"

run_vmnet_guest_gate() {
  EZVM_RELEASE_REQUIRE_VMNET=1 \
  EZVM_RELEASE_REQUIRE_GUEST_IPV4=1 \
    "$project_root/scripts/verify-release-vm.sh" "$app_path" "$fixture"
}

# The first fresh process proves that the signed artifact can reserve and use
# the configured network. The second proves that process teardown releases the
# reservation and that an independent process can recreate the same topology;
# a process-local registry alone cannot make this pass.
run_vmnet_guest_gate
run_vmnet_guest_gate

echo "Verified VMNet Shared attachment, guest IPv4 assignment, Agent transfer, clean stop, and fresh-process reacquisition."
