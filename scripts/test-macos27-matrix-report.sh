#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d /tmp/ezvm-matrix-report-test.XXXXXX)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

app="$fixture/EZVM.app"
mkdir -p "$app/Contents/MacOS"
printf '#!/bin/sh\n' > "$app/Contents/MacOS/EZVM"
chmod +x "$app/Contents/MacOS/EZVM"
report="$fixture/report.json"

"$project_root/scripts/write-macos27-matrix-report.sh" "$app" 2.0.0 123 "$report" 1 >/dev/null

ruby -rjson -e '
  report = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong schema" unless report["schemaVersion"] == 1
  abort "not passed" unless report["status"] == "passed"
  abort "wrong version" unless report["version"] == "2.0.0"
  abort "wrong duration" unless report["durationSeconds"] == 123
  abort "invalid hash" unless report["executableSHA256"].match?(/\A[0-9a-f]{64}\z/)
  abort "missing guests" unless report["guests"] == ["macOS 27", "Omarchy", "Ubuntu"]
  abort "missing VMNet IPv4 check" unless report["checks"].include?("vmnet_guest_ipv4")
  abort "missing ASIF portability check" unless report["checks"].include?("asif_export_validate_import_boot")
  abort "missing real low-space check" unless report["checks"].include?("asif_real_low_space_preflight")
  abort "missing nested check" unless report["checks"].include?("nested_virtualization")
' "$report"

permissions="$(stat -f %Lp "$report")"
[[ "$permissions" == "600" ]] || { echo "report permissions are $permissions, expected 600" >&2; exit 1; }

echo "Verified macOS 27 matrix report schema and permissions."
