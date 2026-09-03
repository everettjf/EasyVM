#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
vm_path="${2:-}"
expected_revision="${3:-${EZVM_EXPECTED_SOURCE_REVISION:-}}"
cask="${EZVM_HOMEBREW_CASK:-everettjf/tap/ezvm}"

fail() {
  echo "verify-homebrew-release: $*" >&2
  exit 1
}

[[ -n "$version" ]] || fail "usage: $0 <version> [smoke-vm] [source-revision]"
[[ -n "$expected_revision" ]] || \
  fail "expected source revision is required as argument 3 or EZVM_EXPECTED_SOURCE_REVISION"
[[ -n "$vm_path" || -n ${EZVM_RELEASE_PREINSTALLED_IMAGE:-} ]] ||
  fail "a standard smoke VM or preinstalled-image fixture is required"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"
[[ ! -d /Applications/EZVM.app ]] || ! pgrep -x EZVM >/dev/null || \
  fail "quit EZVM before verifying the Homebrew release"

brew update
if brew list --cask --versions ezvm >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask "$cask"
  installed_version="$(brew list --cask --versions ezvm | awk '{print $2}')"
  if [[ $installed_version != "$version" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew reinstall --cask "$cask"
  fi
else
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$cask"
fi

installed_version="$(brew list --cask --versions ezvm | awk '{print $2}')"
[[ "$installed_version" == "$version" ]] || \
  fail "Homebrew installed $installed_version, expected $version"

"$project_root/scripts/verify-release-app.sh" \
  /Applications/EZVM.app "$version" "$expected_revision"
if [[ -n $vm_path ]]; then
  "$project_root/scripts/verify-release-cli.sh" /Applications/EZVM.app "$vm_path"
  "$project_root/scripts/verify-release-nested-virtualization.sh" /Applications/EZVM.app "$vm_path"
  "$project_root/scripts/verify-release-vm.sh" /Applications/EZVM.app "$vm_path"
fi

if [[ -n ${EZVM_RELEASE_PREINSTALLED_MANIFEST:-} || -n ${EZVM_RELEASE_PREINSTALLED_IMAGE:-} ]]; then
  [[ -n ${EZVM_RELEASE_PREINSTALLED_MANIFEST:-} && -n ${EZVM_RELEASE_PREINSTALLED_IMAGE:-} ]] ||
    fail "EZVM_RELEASE_PREINSTALLED_MANIFEST and EZVM_RELEASE_PREINSTALLED_IMAGE must be set together"
  "$project_root/scripts/verify-homebrew-preinstalled-image.sh" \
    "$EZVM_RELEASE_PREINSTALLED_MANIFEST" "$EZVM_RELEASE_PREINSTALLED_IMAGE"
fi

echo "Verified published Homebrew release EZVM $version."
