#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/readonly-fixture-guard.sh
source "$project_root/scripts/lib/readonly-fixture-guard.sh"
app_path="${1:-}"
expected_version="${2:-}"
macos_vm="${EZVM_MATRIX_MACOS_VM:-}"
omarchy_vm="${EZVM_MATRIX_OMARCHY_VM:-}"
ubuntu_vm="${EZVM_MATRIX_UBUNTU_VM:-}"
omarchy_enrollment="${EZVM_MATRIX_OMARCHY_ENROLLMENT:-}"
ubuntu_enrollment="${EZVM_MATRIX_UBUNTU_ENROLLMENT:-}"
matrix_report="${EZVM_MATRIX_REPORT:-}"
matrix_started_at="$(date +%s)"

fail() {
  echo "verify-macos27-guest-matrix: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "usage: $0 <EZVM.app> [expected-version]"
[[ -d "$macos_vm" ]] || fail "EZVM_MATRIX_MACOS_VM must name a macOS fixture"
[[ -d "$omarchy_vm" ]] || fail "EZVM_MATRIX_OMARCHY_VM must name an Omarchy fixture"
[[ -d "$ubuntu_vm" ]] || fail "EZVM_MATRIX_UBUNTU_VM must name an Ubuntu fixture"

declare -A fixture_fingerprints
for fixture in "$macos_vm" "$omarchy_vm" "$ubuntu_vm"; do
  fixture_fingerprints["$fixture"]="$(fixture_metadata_fingerprint "$fixture")" \
    || fail "could not fingerprint read-only fixture: $fixture"
done

verify_fixtures_unchanged() {
  local fixture
  local result=0
  for fixture in "$macos_vm" "$omarchy_vm" "$ubuntu_vm"; do
    assert_fixture_unchanged "$fixture" "${fixture_fingerprints[$fixture]}" || result=1
  done
  return "$result"
}

finish_matrix() {
  local matrix_status=$?
  trap - EXIT
  if ! verify_fixtures_unchanged; then
    exit 1
  fi
  exit "$matrix_status"
}
trap finish_matrix EXIT

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
"$project_root/scripts/verify-real-low-space-snapshot.sh"
"$project_root/scripts/verify-large-asif-snapshot.sh"

for fixture in "$macos_vm" "$omarchy_vm" "$ubuntu_vm"; do
  "$project_root/scripts/verify-release-cli.sh" "$app_path" "$fixture"
done

"$project_root/scripts/verify-release-machine-state-support.sh" "$app_path" "$macos_vm"

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

EZVM_RELEASE_SMOKE_ENROLLMENT="$ubuntu_enrollment" \
  "$project_root/scripts/verify-release-vmnet.sh" "$app_path" "$ubuntu_vm"

EZVM_RELEASE_SMOKE_ENROLLMENT="$ubuntu_enrollment" \
  "$project_root/scripts/verify-release-asif-snapshot.sh" "$app_path" "$ubuntu_vm"

EZVM_RELEASE_SMOKE_ENROLLMENT="$ubuntu_enrollment" \
  "$project_root/scripts/verify-release-asif-portability.sh" "$app_path" "$ubuntu_vm"

if [[ "${EZVM_MATRIX_REQUIRE_NESTED:-0}" == "1" ]]; then
  EZVM_RELEASE_SMOKE_ENROLLMENT="$omarchy_enrollment" \
    "$project_root/scripts/verify-release-nested-virtualization.sh" "$app_path" "$omarchy_vm"
fi

if [[ -n "$matrix_report" ]]; then
  "$project_root/scripts/write-macos27-matrix-report.sh" \
    "$app_path" \
    "${expected_version:-unknown}" \
    "$(($(date +%s) - matrix_started_at))" \
    "$matrix_report" \
    "${EZVM_MATRIX_REQUIRE_NESTED:-0}"
fi

echo "Verified the signed macOS 27 guest matrix: macOS, Omarchy, and Ubuntu."
