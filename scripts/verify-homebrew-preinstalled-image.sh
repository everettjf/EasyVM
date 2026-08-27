#!/bin/bash

set -euo pipefail

manifest=${1:-}
image=${2:-}
timeout=${EZVM_PREINSTALLED_SMOKE_TIMEOUT:-180}
app_path=${EZVM_APP_PATH:-/Applications/EZVM.app}

fail() { echo "verify-homebrew-preinstalled-image: $*" >&2; exit 1; }

[[ -f $manifest && -f $image ]] || fail "usage: $0 <preinstalled-image-manifest.json> <decoded-disk.raw>"
[[ $timeout =~ ^[1-9][0-9]*$ ]] || fail "EZVM_PREINSTALLED_SMOKE_TIMEOUT must be a positive integer"
[[ -d $app_path ]] || fail "EZVM app was not found: $app_path"
cli="$app_path/Contents/Helpers/ezvm"
[[ -x $cli ]] || fail "the EZVM CLI is missing from $app_path"

work=$(mktemp -d /tmp/ezvm-preinstalled-e2e.XXXXXX)
destination="$work/Preinstalled Smoke.ezvm"
started=0
cleanup() {
  if ((started)); then "$cli" stop "$destination" --timeout 30 >/dev/null 2>&1 || true; fi
  if [[ ${EZVM_KEEP_SMOKE_ARTIFACTS:-0} == 1 ]]; then
    echo "verify-homebrew-preinstalled-image: retained $work" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT INT TERM

install_result=$(
  "$cli" install-image "$manifest" --image "$image" --destination "$destination" \
    --name "Preinstalled Image Smoke" --timeout "$timeout"
)
jq -e '.success == true and .command == "install-image"' <<<"$install_result" >/dev/null ||
  fail "install-image did not report success"

validate_result=$("$cli" validate "$destination")
jq -e '.success == true and .result.valid == true and .result.osType == "linux"' \
  <<<"$validate_result" >/dev/null || fail "installed machine did not validate"
[[ -f $destination/Disk.img && -f $destination/config.json && -f $destination/NVRAM && \
   -f $destination/MachineIdentifier ]] || fail "installed bundle is incomplete"

start_result=$("$cli" start "$destination" --timeout "$timeout")
jq -e '.success == true and (.result.phase == "running" or .result.phase == "paused")' \
  <<<"$start_result" >/dev/null || fail "installed machine did not start"
started=1
status_result=$("$cli" status "$destination")
jq -e '.success == true and (.result.phase == "running" or .result.phase == "paused")' \
  <<<"$status_result" >/dev/null || fail "installed machine did not remain active"
stop_result=$("$cli" stop "$destination" --timeout "$timeout")
jq -e '.success == true and .result.phase == "stopped"' <<<"$stop_result" >/dev/null ||
  fail "installed machine did not stop cleanly"
started=0

echo "Verified preinstalled-image manifest, import, validation, boot, status, and clean stop with $app_path."
