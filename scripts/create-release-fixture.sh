#!/bin/bash

set -euo pipefail

app_path="${1:-}"
os_type="${2:-}"
image_path="${3:-}"
vm_path="${4:-}"
provision_macos="${5:-}"

fail() {
  echo "create-release-fixture: $*" >&2
  exit 1
}

[[ -d "$app_path" && -x "$app_path/Contents/MacOS/EZVM" ]] || fail "application not found: $app_path"
[[ "$os_type" == "linux" || "$os_type" == "macOS" ]] || fail "OS must be linux or macOS"
[[ -z "$provision_macos" || "$provision_macos" == "--provision-macos" ]] || fail "unknown option: $provision_macos"
[[ -z "$provision_macos" || "$os_type" == "macOS" ]] || fail "--provision-macos requires macOS"
if [[ "$os_type" == "linux" ]]; then
  [[ -f "$image_path" ]] || fail "installer image not found: $image_path"
else
  mkdir -p "$(dirname "$image_path")"
fi
[[ "$vm_path" == *.ezvm ]] || fail "destination must use the .ezvm extension"
[[ ! -e "$vm_path" ]] || fail "destination already exists: $vm_path"
mkdir -p "$(dirname "$vm_path")"
provision_value=0
if [[ -n "$provision_macos" ]]; then
  provision_value=1
fi

result_file="$(mktemp "${TMPDIR:-/tmp}/ezvm-fixture-result.XXXXXX")"
launch_log="$(mktemp "${TMPDIR:-/tmp}/ezvm-fixture-launch.XXXXXX")"
rm -f "$result_file"
cleanup() {
  rm -f "$result_file" "$launch_log"
}
trap cleanup EXIT

if ! open -n -g -W --stdout "$launch_log" --stderr "$launch_log" \
  --env "EZVM_RELEASE_CREATE_OS=$os_type" \
  --env "EZVM_RELEASE_CREATE_IMAGE=$image_path" \
  --env "EZVM_RELEASE_CREATE_VM=$vm_path" \
  --env "EZVM_RELEASE_CREATE_RESULT=$result_file" \
  --env "EZVM_RELEASE_PROVISION_MACOS=$provision_value" \
  "$app_path"; then
  cat "$launch_log" >&2
  fail "EZVM exited while creating the fixture"
fi

[[ -f "$result_file" ]] || {
  cat "$launch_log" >&2
  fail "EZVM did not write a fixture result"
}
result="$(tr -d '\r\n' <"$result_file")"
[[ "$result" == "created" ]] || {
  cat "$launch_log" >&2
  fail "$result"
}
[[ -f "$vm_path/config.json" && -f "$vm_path/state.json" ]] || fail "created fixture is incomplete"
echo "Created $os_type release fixture: $vm_path"
