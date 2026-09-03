#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-}"
expected_version="${2:-}"
macos_vm="${EZVM_MATRIX_MACOS_VM:-}"
omarchy_vm="${EZVM_MATRIX_OMARCHY_VM:-}"
ubuntu_vm="${EZVM_MATRIX_UBUNTU_VM:-}"
omarchy_enrollment="${EZVM_MATRIX_OMARCHY_ENROLLMENT:-}"
ubuntu_enrollment="${EZVM_MATRIX_UBUNTU_ENROLLMENT:-}"

fail() {
  echo "verify-macos27-guest-matrix: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "usage: $0 <EZVM.app> [expected-version]"
[[ -d "$macos_vm" ]] || fail "EZVM_MATRIX_MACOS_VM must name a macOS fixture"
[[ -d "$omarchy_vm" ]] || fail "EZVM_MATRIX_OMARCHY_VM must name an Omarchy fixture"
[[ -d "$ubuntu_vm" ]] || fail "EZVM_MATRIX_UBUNTU_VM must name an Ubuntu fixture"

validate_fixture() {
  local path="$1"
  local expected_type="$2"
  local expected_name="$3"
  [[ -f "$path/config.json" ]] || fail "fixture has no config.json: $path"
  ruby -rjson -e '
    config = JSON.parse(File.read(File.join(ARGV.fetch(0), "config.json")))
    abort "wrong guest type: #{config["type"].inspect}" unless config["type"] == ARGV.fetch(1)
    name = config["name"].to_s.downcase
    expected = ARGV.fetch(2).downcase
    abort "fixture name does not identify #{expected}: #{name.inspect}" unless expected.empty? || name.include?(expected)
  ' "$path" "$expected_type" "$expected_name"
}

validate_fixture "$macos_vm" macOS ""
validate_fixture "$omarchy_vm" linux omarchy
validate_fixture "$ubuntu_vm" linux ubuntu

"$project_root/scripts/verify-release-app.sh" "$app_path" "$expected_version"

for fixture in "$macos_vm" "$omarchy_vm" "$ubuntu_vm"; do
  "$project_root/scripts/verify-release-cli.sh" "$app_path" "$fixture"
done

run_linux_guest_gate() {
  local fixture="$1"
  local enrollment="$2"
  local require_asif="$3"
  [[ -f "$enrollment" ]] || fail "missing Guest Agent enrollment for $fixture"
  EZVM_RELEASE_SMOKE_ENROLLMENT="$enrollment" \
  EZVM_RELEASE_REQUIRE_VIRGL=1 \
  EZVM_RELEASE_REQUIRE_MEMORY_BALLOON=1 \
  EZVM_RELEASE_REQUIRE_ENTROPY=1 \
  EZVM_RELEASE_REQUIRE_VIRTIO_SOCKET=1 \
  EZVM_RELEASE_REQUIRE_ASIF_STORAGE="$require_asif" \
    "$project_root/scripts/verify-release-vm.sh" "$app_path" "$fixture"
}

run_linux_guest_gate "$omarchy_vm" "$omarchy_enrollment" 0
run_linux_guest_gate "$ubuntu_vm" "$ubuntu_enrollment" 1

if [[ "${EZVM_MATRIX_REQUIRE_NESTED:-0}" == "1" ]]; then
  EZVM_RELEASE_SMOKE_ENROLLMENT="$omarchy_enrollment" \
    "$project_root/scripts/verify-release-nested-virtualization.sh" "$app_path" "$omarchy_vm"
fi

echo "Verified the signed macOS 27 guest matrix: macOS, Omarchy, and Ubuntu."
