#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
vm_path="${2:-}"
cask="${EZVM_HOMEBREW_CASK:-everettjf/tap/ezvm}"

fail() {
  echo "verify-homebrew-release: $*" >&2
  exit 1
}

[[ -n "$version" && -n "$vm_path" ]] || fail "usage: $0 <version> <smoke-vm>"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"
[[ ! -d /Applications/EZVM.app ]] || ! pgrep -x EZVM >/dev/null || \
  fail "quit EZVM before verifying the Homebrew release"

brew update
if brew list --cask --versions ezvm >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask "$cask"
else
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$cask"
fi

installed_version="$(brew list --cask --versions ezvm | awk '{print $2}')"
[[ "$installed_version" == "$version" ]] || \
  fail "Homebrew installed $installed_version, expected $version"

"$project_root/scripts/verify-release-app.sh" /Applications/EZVM.app "$version"
"$project_root/scripts/verify-release-cli.sh" /Applications/EZVM.app "$vm_path"
"$project_root/scripts/verify-release-nested-virtualization.sh" /Applications/EZVM.app "$vm_path"
"$project_root/scripts/verify-release-vm.sh" /Applications/EZVM.app "$vm_path"

if [[ -n ${EZVM_RELEASE_PREINSTALLED_MANIFEST:-} || -n ${EZVM_RELEASE_PREINSTALLED_IMAGE:-} ]]; then
  [[ -n ${EZVM_RELEASE_PREINSTALLED_MANIFEST:-} && -n ${EZVM_RELEASE_PREINSTALLED_IMAGE:-} ]] ||
    fail "EZVM_RELEASE_PREINSTALLED_MANIFEST and EZVM_RELEASE_PREINSTALLED_IMAGE must be set together"
  "$project_root/scripts/verify-homebrew-preinstalled-image.sh" \
    "$EZVM_RELEASE_PREINSTALLED_MANIFEST" "$EZVM_RELEASE_PREINSTALLED_IMAGE"
fi

echo "Verified published Homebrew release EZVM $version."
