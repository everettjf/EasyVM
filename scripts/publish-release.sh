#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
tap_repo="${EASYVM_HOMEBREW_TAP:-git@github.com:everettjf/homebrew-tap.git}"

if [[ -z "$version" ]]; then
  echo "usage: $0 <version>" >&2
  exit 64
fi

version="${version#v}"
tag="v$version"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 69
  fi
}

require_environment() {
  if [[ -z "${!1:-}" ]]; then
    echo "required environment variable is missing: $1" >&2
    exit 78
  fi
}

for command in codesign gh git ruby security xcrun; do
  require_command "$command"
done

require_environment APPLE_ID
require_environment APPLE_TEAM_ID
require_environment APPLE_SPECIFIC_PASSWORD

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI authentication is invalid. Run: gh auth login -h github.com" >&2
  exit 77
fi

signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [[ -z "$signing_identity" ]]; then
  echo "No Developer ID Application identity is available in the keychain." >&2
  echo "Import the certificate and private key before publishing." >&2
  exit 78
fi

if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
  echo "The worktree must be clean before publishing." >&2
  exit 65
fi

tag_commit="$(git -C "$project_root" rev-list -n 1 "$tag" 2>/dev/null || true)"
head_commit="$(git -C "$project_root" rev-parse HEAD)"
if [[ -z "$tag_commit" || "$tag_commit" != "$head_commit" ]]; then
  echo "$tag must exist and point at HEAD before publishing." >&2
  exit 65
fi

release_dir="$(mktemp -d /tmp/easyvm-publish.XXXXXX)"
tap_dir="$(mktemp -d /tmp/easyvm-tap.XXXXXX)"
derived_data="$release_dir/DerivedData"
cleanup() {
  rm -rf "$release_dir" "$tap_dir"
}
trap cleanup EXIT

EASYVM_SIGNING_IDENTITY="$signing_identity" \
EASYVM_DERIVED_DATA="$derived_data" \
  "$project_root/scripts/build-release.sh" "$version" "$release_dir"

archive="$release_dir/EasyVM-$version.zip"
checksum="$archive.sha256"

xcrun notarytool submit "$archive" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_SPECIFIC_PASSWORD" \
  --wait

# Do not staple the ticket into the app. On macOS 27 beta, a stapled app can
# remain suspended in _dyld_start even though codesign, stapler, and spctl all
# accept it. The notarized ZIP is still recognized by Gatekeeper through
# Apple's online notarization record.
app_path="$derived_data/Build/Products/Release/EasyVM.app"
[[ -d "$app_path" ]] || { echo "Built app not found: $app_path" >&2; exit 66; }
codesign --verify --deep --strict --verbose=2 "$app_path"

install_check_dir="$release_dir/install-check"
mkdir -p "$install_check_dir"
ditto -x -k "$archive" "$install_check_dir"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");EasyVMRelease;" "$install_check_dir/EasyVM.app"
codesign --verify --deep --strict --verbose=2 "$install_check_dir/EasyVM.app"
spctl --assess --type execute --verbose=4 "$install_check_dir/EasyVM.app"

gh release create "$tag" "$archive" "$checksum" \
  --repo everettjf/easyvm \
  --verify-tag \
  --generate-notes \
  --title "EasyVM $version"

git clone "$tap_repo" "$tap_dir/repository"
ruby "$project_root/scripts/update-cask.rb" \
  "$version" \
  "$archive" \
  "$project_root/Casks/easyvm.rb" \
  "$tap_dir/repository/Casks/easyvm.rb"

ruby -c "$tap_dir/repository/Casks/easyvm.rb"
git -C "$tap_dir/repository" add Casks/easyvm.rb
git -C "$tap_dir/repository" diff --cached --quiet || \
  git -C "$tap_dir/repository" commit -m "Update EasyVM to $version"
git -C "$tap_dir/repository" push

echo "Published EasyVM $version to GitHub Releases and Homebrew."
