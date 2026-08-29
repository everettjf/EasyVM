#!/bin/bash

set -euo pipefail

cask=${EZVM_HOMEBREW_CASK:-everettjf/tap/ezvm}
release_base_url=${EZVM_OMARCHY_RELEASE_BASE_URL:-https://github.com/everettjf/omarchy-aarch64-image/releases/latest/download}
destination=${1:-}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

celebrate() {
  local cyan='' green='' gold='' reset=''
  if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
    cyan=$'\033[1;36m'
    green=$'\033[1;32m'
    gold=$'\033[1;33m'
    reset=$'\033[0m'
    local frame
    for frame in '.          .' '.*        *.' '✦  *  ✦  *  ✦'; do
      printf '\r%s%*s%s' "$gold" 28 "$frame" "$reset"
      sleep 0.18
    done
    printf '\r%*s\r' 40 ''
  fi

  printf '\n%s' "$cyan"
  printf '%s\n' ' _____ _______     ____  __'
  printf '%s\n' '| ____|__  /\ \   / /  \/  |'
  printf '%s\n' '|  _|   / /  \ \ / /| |\/| |'
  printf '%s\n' '| |___ / /_   \ V / | |  | |'
  printf '%s\n' '|_____/____|   \_/  |_|  |_|'
  printf '%s\n' "$reset"
  printf '%s%17s%s\n\n' "$gold" '+' "$reset"
  printf '%s' "$green"
  printf '%s\n' '  ___  __  __    _    ____   ____ _   ___   __'
  printf '%s\n' ' / _ \|  \/  |  / \  |  _ \ / ___| | | \ \ / /'
  printf '%s\n' '| | | | |\/| | / _ \ | |_) | |   | |_| |\ V /'
  printf '%s\n' '| |_| | |  | |/ ___ \|  _ <| |___|  _  | | |'
  printf '%s\n' ' \___/|_|  |_/_/   \_\_| \_\\____|_| |_| |_|'
  printf '%s\n\n' "$reset"
  printf '%s%sEZVM and Omarchy are ready.%s\n' "$gold" "$green" "$reset"
  printf 'Open EZVM and press Run. Enjoy!\n'
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

for command in awk brew curl df dirname mktemp shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    if [[ $command == brew ]]; then
      fail "Homebrew is required. Install it from https://brew.sh and run this command again."
    fi
    fail "required command not found: $command"
  }
done

required_kib=$((15 * 1024 * 1024))
space_target=${destination:-"$HOME/EZVM Virtual Machines/Omarchy.ezvm"}
space_probe=$(dirname "$space_target")
while [[ ! -e $space_probe ]]; do
  parent=$(dirname "$space_probe")
  [[ $parent != "$space_probe" ]] || fail "could not locate the destination volume"
  space_probe=$parent
done
available_kib=$(df -Pk "$space_probe" | awk 'END { print $4 }')
[[ $available_kib =~ ^[0-9]+$ ]] || fail "could not determine available space on the destination volume"
available_gib=$(awk -v kib="$available_kib" 'BEGIN { printf "%.1f", kib / 1024 / 1024 }')
printf 'Available space on the destination volume: %s GiB (15 GiB required).\n' "$available_gib"
((available_kib >= required_kib)) || \
  fail "not enough disk space: at least 15 GiB of available space is required"

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

celebrate
