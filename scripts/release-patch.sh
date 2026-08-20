#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$project_root/EasyVM/EasyVM.xcodeproj/project.pbxproj"
release_branch="${EASYVM_RELEASE_BRANCH:-main}"

fail() {
  echo "release-patch: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_environment() {
  [[ -n "${!1:-}" ]] || fail "required environment variable is missing: $1"
}

for command in gh git ruby security swift xcodebuild; do
  require_command "$command"
done

for variable in APPLE_ID APPLE_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
  require_environment "$variable"
done

[[ -f "$project_file" ]] || fail "Xcode project not found: $project_file"
[[ -z "$(git -C "$project_root" status --porcelain)" ]] || fail "commit or stash all changes before releasing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication is invalid; run: gh auth login -h github.com"

signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
[[ -n "$signing_identity" ]] || fail "no Developer ID Application identity is available in the keychain"

git -C "$project_root" fetch origin "$release_branch" --tags
head_commit="$(git -C "$project_root" rev-parse HEAD)"
remote_commit="$(git -C "$project_root" rev-parse "origin/$release_branch")"
[[ "$head_commit" == "$remote_commit" ]] || fail "HEAD must match origin/$release_branch before a release"

latest_tag="$(git -C "$project_root" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -1)"
[[ "$latest_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "could not determine the latest semantic version tag"

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
version="$major.$minor.$((patch + 1))"
tag="v$version"

if git -C "$project_root" rev-parse "$tag" >/dev/null 2>&1 || \
   git -C "$project_root" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  fail "$tag already exists"
fi

configured_versions="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u)"
configured_version_count="$(printf '%s\n' "$configured_versions" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$configured_version_count" -eq 1 ]] || fail "Xcode targets do not share one marketing version"
current_version="$configured_versions"

if [[ "$current_version" != "$version" ]]; then
  [[ "$current_version" == "${latest_tag#v}" ]] || \
    fail "project version is $current_version, expected ${latest_tag#v} or $version"
  ruby -pi -e "gsub(/MARKETING_VERSION = [^;]+;/, 'MARKETING_VERSION = $version;')" "$project_file"
  git -C "$project_root" add -- EasyVM/EasyVM.xcodeproj/project.pbxproj
  git -C "$project_root" commit -m "Prepare EasyVM $version"
fi

echo "Running EasyVM $version release checks…"
(cd "$project_root" && swift test)
(cd "$project_root/EasyVM" && xcodebuild \
  -quiet \
  -project EasyVM.xcodeproj \
  -scheme EasyVM \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${TMPDIR:-/tmp}/easyvm-release-check-$version" \
  CODE_SIGNING_ALLOWED=NO \
  build)

git -C "$project_root" tag -a "$tag" -m "EasyVM $version"
git -C "$project_root" push origin "HEAD:refs/heads/$release_branch" "refs/tags/$tag"

APPLE_ID="$APPLE_ID" \
APPLE_SPECIFIC_PASSWORD="$APPLE_SPECIFIC_PASSWORD" \
APPLE_TEAM_ID="$APPLE_TEAM_ID" \
  "$project_root/scripts/publish-release.sh" "$version"

echo "EasyVM $version is signed, notarized, published, and available from the Homebrew tap."
