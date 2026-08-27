#!/bin/bash

set -euo pipefail

app_path="${1:-}"
vm_path="${2:-}"

fail() {
  echo "verify-release-nested-virtualization: $*" >&2
  exit 1
}

[[ -d "$app_path" && -d "$vm_path" ]] || fail "usage: $0 <EZVM.app> <smoke-vm>"

EZVM_RELEASE_ENABLE_NESTED=1 \
EZVM_RELEASE_REQUIRE_KVM=1 \
  "$(dirname "$0")/verify-release-vm.sh" "$app_path" "$vm_path"

echo "Verified nested virtualization with guest /dev/kvm and KVM_GET_API_VERSION=12."
