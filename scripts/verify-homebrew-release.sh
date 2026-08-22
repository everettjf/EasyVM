#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
vm_path="${2:-}"
cask="${EASYVM_HOMEBREW_CASK:-everettjf/tap/easyvm}"

fail() {
  echo "verify-homebrew-release: $*" >&2
  exit 1
}

[[ -n "$version" && -n "$vm_path" ]] || fail "usage: $0 <version> <smoke-vm>"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"
[[ ! -d /Applications/EasyVM.app ]] || ! pgrep -x EasyVM >/dev/null || \
  fail "quit EasyVM before verifying the Homebrew release"

brew update
if brew list --cask --versions easyvm >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask "$cask"
else
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$cask"
fi

installed_version="$(brew list --cask --versions easyvm | awk '{print $2}')"
[[ "$installed_version" == "$version" ]] || \
  fail "Homebrew installed $installed_version, expected $version"

"$project_root/scripts/verify-release-app.sh" /Applications/EasyVM.app "$version"
"$project_root/scripts/verify-release-cli.sh" /Applications/EasyVM.app "$vm_path"
"$project_root/scripts/verify-release-nested-virtualization.sh" /Applications/EasyVM.app "$vm_path"
"$project_root/scripts/verify-release-vm.sh" /Applications/EasyVM.app "$vm_path"

echo "Verified published Homebrew release EasyVM $version."
