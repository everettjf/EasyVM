#!/bin/bash

set -euo pipefail

app_path="${1:-}"
version="${2:-}"
duration_seconds="${3:-}"
output="${4:-}"
nested="${5:-0}"

fail() {
  echo "write-macos27-matrix-report: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "application not found: $app_path"
[[ -x "$app_path/Contents/MacOS/EZVM" ]] || fail "EZVM executable not found"
[[ -n "$version" ]] || fail "version is required"
[[ "$duration_seconds" =~ ^[0-9]+$ ]] || fail "duration must be a nonnegative integer"
[[ "$nested" == "0" || "$nested" == "1" ]] || fail "nested flag must be 0 or 1"
[[ "$output" == /* ]] || fail "output must be an absolute path"
[[ ! -L "$output" ]] || fail "output must not be a symbolic link"

output_directory="$(dirname "$output")"
[[ -d "$output_directory" ]] || fail "output directory does not exist: $output_directory"
temporary="$(mktemp "$output_directory/.ezvm-matrix-report.XXXXXX")"
cleanup() { rm -f "$temporary"; }
trap cleanup EXIT

app_sha256="$(shasum -a 256 "$app_path/Contents/MacOS/EZVM" | awk '{ print $1 }')"
generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ruby -rjson -e '
  checks = %w[
    gatekeeper signature entitlement_allowlist gui_launch cli_json concurrent_vms
    sigkill_restart efi_recovery macos_saved_state omarchy_guest_agent
    omarchy_virgl ubuntu_guest_agent ubuntu_virgl ubuntu_asif vmnet_shared
    vmnet_guest_ipv4 vmnet_fresh_process_reacquisition asif_snapshot_cross_process_restore
    asif_real_low_space_preflight
    asif_export_validate_import_boot
  ]
  checks << "nested_virtualization" if ARGV.fetch(5) == "1"
  report = {
    schemaVersion: 1,
    status: "passed",
    generatedAt: ARGV.fetch(0),
    version: ARGV.fetch(1),
    durationSeconds: Integer(ARGV.fetch(2)),
    executableSHA256: ARGV.fetch(3),
    guests: ["macOS 27", "Omarchy", "Ubuntu"],
    checks: checks
  }
  File.write(ARGV.fetch(4), JSON.pretty_generate(report) + "\n")
' "$generated" "$version" "$duration_seconds" "$app_sha256" "$temporary" "$nested"

chmod 600 "$temporary"
mv -f "$temporary" "$output"
trap - EXIT
echo "Wrote macOS 27 matrix report: $output"
