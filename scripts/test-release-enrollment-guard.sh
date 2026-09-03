#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/release-enrollment-guard.sh
source "$project_root/scripts/lib/release-enrollment-guard.sh"

test_root="$(mktemp -d /tmp/ezvm-enrollment-guard-test.XXXXXX)"
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

first_vm="$test_root/First.ezvm"
second_vm="$test_root/Second.ezvm"
enrollment="$test_root/enrollment.json"
mkdir "$first_vm" "$second_vm"
printf 'first-machine-identifier' >"$first_vm/MachineIdentifier"
printf 'second-machine-identifier' >"$second_vm/MachineIdentifier"

ruby -rbase64 -rdigest -rjson -e '
  identifier_path, output_path = ARGV
  enrollment = {
    "schemaVersion" => 1,
    "machineID" => Digest::SHA256.file(identifier_path).hexdigest,
    "token" => Base64.strict_encode64("t" * 32),
    "port" => 10_240,
  }
  File.write(output_path, JSON.generate(enrollment))
' "$first_vm/MachineIdentifier" "$enrollment"
chmod 600 "$enrollment"

validate_release_enrollment "$first_vm" "$enrollment"

if validate_release_enrollment "$second_vm" "$enrollment" >/dev/null 2>&1; then
  echo "enrollment guard accepted a token for another VM" >&2
  exit 1
fi

chmod 644 "$enrollment"
if validate_release_enrollment "$first_vm" "$enrollment" >/dev/null 2>&1; then
  echo "enrollment guard accepted unsafe permissions" >&2
  exit 1
fi
chmod 600 "$enrollment"

ln -s "$enrollment" "$test_root/enrollment-link.json"
if validate_release_enrollment "$first_vm" "$test_root/enrollment-link.json" >/dev/null 2>&1; then
  echo "enrollment guard accepted a symbolic link" >&2
  exit 1
fi

ruby -rjson -e '
  path = ARGV.fetch(0)
  enrollment = JSON.parse(File.read(path))
  enrollment["port"] = 1
  File.write(path, JSON.generate(enrollment))
' "$enrollment"
if validate_release_enrollment "$first_vm" "$enrollment" >/dev/null 2>&1; then
  echo "enrollment guard accepted an invalid service port" >&2
  exit 1
fi

echo "Verified release enrollment identity and permission checks."
