#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-}
version=${2:-}
evidence=${3:-}
factory_manifest=${4:-}
factory_image=${5:-}
integration_observation=${6:-}
lifecycle_observation=${7:-}
command_super_observation=${8:-}
rollback_observation=${9:-}
full_screen_observation=${10:-}
notification_observation=${11:-}
soak_observation=${12:-}
release_branch=${EZVM_OMARCHY_RELEASE_BRANCH:-main}

fail() { echo "publish-omarchy-release: $*" >&2; exit "${2:-1}"; }
require_environment() { [[ -n ${!1:-} ]] || fail "required environment variable is missing: $1" 78; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1" 69; }

[[ $mode == prepare || $mode == publish ]] || \
  fail "usage: $0 prepare <version> | publish <version> <acceptance-evidence.json> <factory-manifest.json> <factory-image.asif> <integration-readiness.json> <integration-lifecycle.json> <command-super.json> <update-rollback.json> <full-screen.json> <desktop-notification.json> <soak-observation.json>" 64
[[ -n $version ]] || fail "release version is required" 64
version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "invalid version: $version" 64
if [[ $mode == publish ]]; then
  for path in "$evidence" "$factory_manifest" "$factory_image" \
    "$integration_observation" "$lifecycle_observation" "$command_super_observation" \
    "$rollback_observation" "$full_screen_observation" "$notification_observation" \
    "$soak_observation"; do
    [[ -f $path && ! -L $path ]] || fail "required release input is missing or unsafe: ${path:-<empty>}" 66
  done
fi
for command in cmp codesign ditto gh git open ruby security shasum spctl xattr xcrun; do require_command "$command"; done
for variable in APPLE_ID APPLE_TEAM_ID APPLE_SPECIFIC_PASSWORD EZVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64; do
  require_environment "$variable"
done
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication is invalid" 77

[[ -z $(git -C "$project_root" status --porcelain) ]] || fail "worktree must be clean before publishing" 65
source_revision=$(git -C "$project_root" rev-parse HEAD)
tag="ezvm-omarchy-v$version"
tag_revision=$(git -C "$project_root" rev-list -n 1 "$tag" 2>/dev/null || true)
[[ $tag_revision == "$source_revision" ]] || fail "$tag must exist and point at HEAD" 65
signing_identity=$(security find-identity -v -p codesigning | \
  sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
[[ -n $signing_identity ]] || fail "no Developer ID Application identity is available" 78

state_root=${EZVM_OMARCHY_RELEASE_STATE_DIR:-${TMPDIR:-/tmp}/ezvm-omarchy-release-state}
release_dir="$state_root/$version"
derived_data="$release_dir/DerivedData"
archive="$release_dir/EZVM-Omarchy-$version.zip"
checksum="$archive.sha256"
source_file="$release_dir/source-commit"
notarized_file="$release_dir/notarized-archive-sha256"
mkdir -p "$release_dir"

if [[ -f $source_file && $(tr -d '\r\n' <"$source_file") == "$source_revision" && \
      -f $archive && -f $checksum ]] && (cd "$release_dir" && shasum -a 256 -c "$(basename "$checksum")"); then
  echo "Reusing verified EZVM Omarchy $version candidate from $release_dir"
else
  rm -f "$archive" "$checksum" "$source_file" "$notarized_file"
  rm -rf "$derived_data"
  EZVM_SIGNING_IDENTITY="$signing_identity" \
  EZVM_OMARCHY_DERIVED_DATA="$derived_data" \
    "$project_root/scripts/build-omarchy-release.sh" "$version" "$release_dir"
  printf '%s\n' "$source_revision" >"$source_file"
fi

archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ ! -f $notarized_file || $(tr -d '\r\n' <"$notarized_file") != "$archive_sha" ]]; then
  xcrun notarytool submit "$archive" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_SPECIFIC_PASSWORD" --wait
  printf '%s\n' "$archive_sha" >"$notarized_file"
fi

install_check="$release_dir/install-check"
rm -rf "$install_check"
mkdir -p "$install_check"
ditto -x -k "$archive" "$install_check"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");EZVMOmarchyRelease;" \
  "$install_check/EZVM Omarchy.app"
EZVM_OMARCHY_LAUNCH_TIMEOUT=${EZVM_OMARCHY_LAUNCH_TIMEOUT:-10} \
  "$project_root/scripts/verify-omarchy-release-gui.sh" \
    "$install_check/EZVM Omarchy.app" "$version" "$source_revision"

# The GUI verifier terminates its candidate before returning. Re-extract the
# immutable archive and verify it again with no process using the bundle. This
# catches post-launch code-signing/cache failures and also proves the compiled
# AppIcon is present in the exact ZIP that will be published.
if pgrep -x 'EZVM Omarchy' >/dev/null 2>&1; then
  fail "EZVM Omarchy remained running before cold archive verification" 70
fi
rm -rf "$install_check"
mkdir -p "$install_check"
ditto -x -k "$archive" "$install_check"
cold_settle_seconds=${EZVM_OMARCHY_COLD_VERIFY_SETTLE_SECONDS:-30}
[[ $cold_settle_seconds =~ ^[0-9]+$ ]] || \
  fail "EZVM_OMARCHY_COLD_VERIFY_SETTLE_SECONDS must be a non-negative integer" 64
sleep "$cold_settle_seconds"
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$archive_sha" ]] || \
  fail "candidate archive changed before cold verification" 67
"$project_root/scripts/verify-omarchy-release-app.sh" \
  "$install_check/EZVM Omarchy.app" "$version" "$source_revision" clean
spctl --assess --type execute --verbose=4 "$install_check/EZVM Omarchy.app"

if [[ $mode == prepare ]]; then
  echo "Prepared notarized EZVM Omarchy candidate: $archive"
  echo "Archive SHA-256: $archive_sha"
  echo "Run real-guest acceptance against this exact archive, then invoke publish mode."
  exit 0
fi

"$project_root/scripts/verify-omarchy-release-evidence.sh" \
  "$evidence" "$archive" "$factory_manifest" "$factory_image" "$source_revision" \
  "$integration_observation" "$lifecycle_observation" "$command_super_observation" \
  "$rollback_observation" "$full_screen_observation" "$notification_observation" \
  "$soak_observation"

# No public ref or release is mutated before notarization, Gatekeeper, GUI, and
# exact-artifact real-guest evidence all pass.
git -C "$project_root" push origin "HEAD:refs/heads/$release_branch" "refs/tags/$tag"
if gh release view "$tag" --repo everettjf/ezvm >/dev/null 2>&1; then
  download=$(mktemp -d "${TMPDIR:-/tmp}/ezvm-omarchy-published.XXXXXX")
  trap 'rm -rf "$download"' EXIT
  gh release download "$tag" --repo everettjf/ezvm --pattern "$(basename "$archive")*" --dir "$download"
  cmp -s "$checksum" "$download/$(basename "$checksum")" || fail "published checksum differs from candidate" 67
  (cd "$download" && shasum -a 256 -c "$(basename "$checksum")") || fail "published archive differs from checksum" 67
else
  gh release create "$tag" "$archive" "$checksum" "$factory_manifest" \
    --repo everettjf/ezvm --verify-tag --generate-notes --title "EZVM Omarchy $version"
fi

echo "Published EZVM Omarchy $version after notarized real-guest acceptance."
