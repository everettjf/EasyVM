#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
tap_repo="${EASYVM_HOMEBREW_TAP:-git@github.com:everettjf/homebrew-tap.git}"
release_branch="${EASYVM_RELEASE_BRANCH:-main}"

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

for command in brew codesign gh git go ruby security xcrun; do
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

state_base="${EASYVM_RELEASE_STATE_DIR:-${TMPDIR:-/tmp}/easyvm-release-state}"
release_dir="$state_base/$version"
tap_dir="$(mktemp -d /tmp/easyvm-tap.XXXXXX)"
derived_data="$release_dir/DerivedData"
cleanup() {
  rm -rf "$tap_dir"
}
trap cleanup EXIT
mkdir -p "$release_dir"

archive="$release_dir/EasyVM-$version.zip"
checksum="$archive.sha256"
guest_archive="$release_dir/EasyVM-GuestAgent-$version-linux-arm64.tar.gz"
guest_checksum="$guest_archive.sha256"
source_commit_file="$release_dir/source-commit"
source_commit="$(git -C "$project_root" rev-parse HEAD)"

if [[ -f "$source_commit_file" && "$(tr -d '\r\n' <"$source_commit_file")" == "$source_commit" && \
      -f "$archive" && -f "$checksum" && -f "$guest_archive" && -f "$guest_checksum" ]] && \
   (cd "$release_dir" && shasum -a 256 -c "$(basename "$checksum")" "$(basename "$guest_checksum")"); then
  echo "Reusing verified EasyVM $version release artifacts from $release_dir"
else
  rm -f "$archive" "$checksum" "$guest_archive" "$guest_checksum" "$release_dir/notarized" "$source_commit_file"
  rm -rf "$derived_data"
  EASYVM_SIGNING_IDENTITY="$signing_identity" \
  EASYVM_DERIVED_DATA="$derived_data" \
    "$project_root/scripts/build-release.sh" "$version" "$release_dir"
  "$project_root/scripts/build-guest-agent.sh" "$version" "$release_dir"
  printf '%s\n' "$source_commit" >"$source_commit_file"
fi

if [[ ! -f "$release_dir/notarized" ]]; then
  xcrun notarytool submit "$archive" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_SPECIFIC_PASSWORD" \
    --wait
  touch "$release_dir/notarized"
fi

# Do not staple the ticket into the app. On macOS 27 beta, a stapled app can
# remain suspended in _dyld_start even though codesign, stapler, and spctl all
# accept it. The notarized ZIP is still recognized by Gatekeeper through
# Apple's online notarization record.
install_check_dir="$release_dir/install-check"
rm -rf "$install_check_dir"
mkdir -p "$install_check_dir"
ditto -x -k "$archive" "$install_check_dir"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");EasyVMRelease;" "$install_check_dir/EasyVM.app"
codesign --verify --deep --strict --verbose=2 "$install_check_dir/EasyVM.app"
spctl --assess --type execute --verbose=4 "$install_check_dir/EasyVM.app"
EASYVM_LAUNCH_TIMEOUT="${EASYVM_LAUNCH_TIMEOUT:-10}" \
  "$project_root/scripts/verify-release-app.sh" "$install_check_dir/EasyVM.app" "$version"
if [[ -n "${EASYVM_RELEASE_SMOKE_VM:-}" ]]; then
  EASYVM_VM_SMOKE_TIMEOUT="${EASYVM_VM_SMOKE_TIMEOUT:-90}" \
  EASYVM_RELEASE_SMOKE_ENROLLMENT="${EASYVM_RELEASE_SMOKE_ENROLLMENT:-}" \
    "$project_root/scripts/verify-release-cli.sh" "$install_check_dir/EasyVM.app" "$EASYVM_RELEASE_SMOKE_VM"
  EASYVM_VM_SMOKE_TIMEOUT="${EASYVM_VM_SMOKE_TIMEOUT:-90}" \
  EASYVM_RELEASE_SMOKE_ENROLLMENT="${EASYVM_RELEASE_SMOKE_ENROLLMENT:-}" \
    "$project_root/scripts/verify-release-nested-virtualization.sh" "$install_check_dir/EasyVM.app" "$EASYVM_RELEASE_SMOKE_VM"
  EASYVM_VM_SMOKE_TIMEOUT="${EASYVM_VM_SMOKE_TIMEOUT:-90}" \
  EASYVM_RELEASE_SMOKE_ENROLLMENT="${EASYVM_RELEASE_SMOKE_ENROLLMENT:-}" \
    "$project_root/scripts/verify-release-vm.sh" "$install_check_dir/EasyVM.app" "$EASYVM_RELEASE_SMOKE_VM"
else
  echo "EASYVM_RELEASE_SMOKE_VM is required for a release VM boot test." >&2
  exit 78
fi

# Publish refs only after the exact candidate has passed notarization,
# Gatekeeper, GUI readiness, and all real-VM tests.
git -C "$project_root" push origin "HEAD:refs/heads/$release_branch" "refs/tags/$tag"

if gh release view "$tag" --repo everettjf/easyvm >/dev/null 2>&1; then
  published_checksums="$release_dir/published-checksums"
  rm -rf "$published_checksums"
  mkdir -p "$published_checksums"
  gh release download "$tag" --repo everettjf/easyvm --pattern '*.sha256' --dir "$published_checksums"
  cmp -s "$checksum" "$published_checksums/$(basename "$checksum")" || {
    echo "Existing GitHub release has a different EasyVM checksum." >&2; exit 67;
  }
  cmp -s "$guest_checksum" "$published_checksums/$(basename "$guest_checksum")" || {
    echo "Existing GitHub release has a different Guest Agent checksum." >&2; exit 67;
  }
  echo "GitHub release $tag already contains the verified artifacts; continuing."
else
  gh release create "$tag" "$archive" "$checksum" "$guest_archive" "$guest_checksum" \
    --repo everettjf/easyvm \
    --verify-tag \
    --generate-notes \
    --title "EasyVM $version"
fi

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

"$project_root/scripts/verify-homebrew-release.sh" "$version" "$EASYVM_RELEASE_SMOKE_VM"

echo "Published EasyVM $version to GitHub Releases and Homebrew."
