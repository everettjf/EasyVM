#!/bin/bash

set -euo pipefail

cask=${EZVM_HOMEBREW_CASK:-everettjf/tap/ezvm}
release_base_url=${EZVM_OMARCHY_RELEASE_BASE_URL:-https://github.com/everettjf/omarchy-aarch64-image/releases/latest/download}
destination=${1:-}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  cat <<'EOF'
Install EZVM and the latest verified Omarchy AArch64 image.

Usage:
  install-omarchy.sh [destination.ezvm]

The default destination is:
  ~/EZVM Virtual Machines/Omarchy.ezvm
EOF
  exit 0
fi

[[ $(uname -s) == Darwin ]] || fail "this installer requires macOS"
[[ $(uname -m) == arm64 ]] || fail "this installer requires an Apple Silicon Mac"
[[ -z $destination || $destination == *.ezvm ]] || fail "destination must end in .ezvm"

for command in awk brew curl mktemp shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    if [[ $command == brew ]]; then
      fail "Homebrew is required. Install it from https://brew.sh and run this command again."
    fi
    fail "required command not found: $command"
  }
done

printf 'Installing or updating EZVM with Homebrew…\n'
brew update
if brew list --cask --versions ezvm >/dev/null 2>&1; then
  if [[ -n $(brew outdated --cask ezvm) ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask "$cask"
  else
    printf 'EZVM is already up to date.\n'
  fi
else
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$cask"
fi

installed_version=$(brew list --cask --versions ezvm | awk 'NR == 1 { print $2 }')
[[ -n $installed_version ]] || fail "Homebrew did not report the installed EZVM version"
printf 'Using EZVM %s.\n' "$installed_version"

work=$(mktemp -d "${TMPDIR:-/tmp}/ezvm-omarchy-bootstrap.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

installer=$work/install-Omarchy-ezvm.command
checksums=$work/SHA256SUMS
printf 'Downloading the verified Omarchy installer…\n'
curl --fail --location --retry 3 --output "$installer" "$release_base_url/install-Omarchy-ezvm.command"
curl --fail --location --retry 3 --output "$checksums" "$release_base_url/SHA256SUMS"

expected=$(awk '$2 == "install-Omarchy-ezvm.command" { print $1 }' "$checksums")
[[ $expected =~ ^[0-9a-f]{64}$ ]] || fail "Omarchy release checksums do not describe the installer"
actual=$(shasum -a 256 "$installer" | awk '{ print $1 }')
[[ $actual == "$expected" ]] || fail "Omarchy installer checksum mismatch"
/bin/bash -n "$installer"

printf 'Installing the latest Omarchy AArch64 image…\n'
if [[ -n $destination ]]; then
  /bin/bash "$installer" "$destination"
else
  /bin/bash "$installer"
fi

printf '\nEZVM and Omarchy are ready.\n'
