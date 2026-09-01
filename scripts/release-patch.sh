#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$project_root/EZVM/EZVM.xcodeproj/project.pbxproj"
release_branch="${EZVM_RELEASE_BRANCH:-main}"

fail() {
  echo "release-patch: $*" >&2
  exit 1
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "usage: $0"
  echo "Increments the latest patch version, tests, signs, notarizes, publishes a GitHub release, and updates Homebrew."
  echo "Required: APPLE_ID, APPLE_SPECIFIC_PASSWORD, APPLE_TEAM_ID"
  exit 0
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_environment() {
  [[ -n "${!1:-}" ]] || fail "required environment variable is missing: $1"
}

for command in gh git go ruby security swift xcodebuild; do
  require_command "$command"
done

for variable in APPLE_ID APPLE_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
  require_environment "$variable"
done
if [[ -z ${EZVM_RELEASE_SMOKE_VM:-} && -z ${EZVM_RELEASE_PREINSTALLED_IMAGE:-} ]]; then
  fail "set EZVM_RELEASE_SMOKE_VM or EZVM_RELEASE_PREINSTALLED_MANIFEST and EZVM_RELEASE_PREINSTALLED_IMAGE"
fi

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

configured_versions="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u)"
configured_version_count="$(printf '%s\n' "$configured_versions" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$configured_version_count" -eq 1 ]] || fail "Xcode targets do not share one marketing version"
current_version="$configured_versions"
if [[ "$current_version" =~ ^$major\.$minor\.([0-9]+)$ ]] && \
   (( BASH_REMATCH[1] > patch + 1 )); then
  version="$current_version"
  tag="v$version"
fi
if git -C "$project_root" rev-parse "$tag" >/dev/null 2>&1 || \
   git -C "$project_root" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  fail "$tag already exists"
fi
configured_builds="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u)"
configured_build_count="$(printf '%s\n' "$configured_builds" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$configured_build_count" -eq 1 && "$configured_builds" =~ ^[0-9]+$ ]] || fail "Xcode targets do not share one numeric build number"
next_build="$configured_builds"

if [[ "$current_version" == "${latest_tag#v}" ]]; then
  next_build="$((configured_builds + 1))"
  ruby -pi -e "gsub(/MARKETING_VERSION = [^;]+;/, 'MARKETING_VERSION = $version;'); gsub(/CURRENT_PROJECT_VERSION = [^;]+;/, 'CURRENT_PROJECT_VERSION = $next_build;')" "$project_file"
  git -C "$project_root" add -- EZVM/EZVM.xcodeproj/project.pbxproj
  git -C "$project_root" commit -m "Prepare EZVM $version (build $next_build)"
elif [[ "$current_version" != "$version" ]]; then
  fail "project version is $current_version, expected ${latest_tag#v} or $version"
fi

echo "Running EZVM $version release checks…"
(cd "$project_root" && swift test)
(cd "$project_root/GuestAgent/linux" && go test ./...)
(cd "$project_root/GuestAgent/linux" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "${TMPDIR:-/tmp}/ezvm-agent-release-check" .)
(cd "$project_root/EZVM" && xcodebuild \
  -quiet \
  -project EZVM.xcodeproj \
  -scheme EZVM \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${TMPDIR:-/tmp}/ezvm-release-check-$version" \
  CODE_SIGNING_ALLOWED=NO \
  build)

git -C "$project_root" tag -a "$tag" -m "EZVM $version"

APPLE_ID="$APPLE_ID" \
APPLE_SPECIFIC_PASSWORD="$APPLE_SPECIFIC_PASSWORD" \
APPLE_TEAM_ID="$APPLE_TEAM_ID" \
EZVM_RELEASE_BRANCH="$release_branch" \
  "$project_root/scripts/publish-release.sh" "$version"

echo "EZVM $version is signed, notarized, published, and available from the Homebrew tap."
