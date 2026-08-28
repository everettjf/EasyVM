#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$project_root/EZVM/EZVM.xcodeproj/project.pbxproj"
version="${1#v}"
release_branch="${EZVM_RELEASE_BRANCH:-main}"
tag="v$version"
version_reset="${EZVM_RELEASE_VERSION_RESET:-0}"

fail() { echo "release-version: $*" >&2; exit 1; }
[[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "usage: $0 <major.minor.patch>"

for command in gh git go ruby security swift xcodebuild; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done
for variable in APPLE_ID APPLE_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
  [[ -n "${!variable:-}" ]] || fail "required environment variable is missing: $variable"
done
if [[ -z ${EZVM_RELEASE_SMOKE_VM:-} && -z ${EZVM_RELEASE_PREINSTALLED_IMAGE:-} ]]; then
  fail "set EZVM_RELEASE_SMOKE_VM or EZVM_RELEASE_PREINSTALLED_MANIFEST and EZVM_RELEASE_PREINSTALLED_IMAGE"
fi
if [[ -n ${EZVM_RELEASE_SMOKE_VM:-} && -z ${EZVM_RELEASE_SMOKE_ENROLLMENT:-} ]]; then
  fail "EZVM_RELEASE_SMOKE_ENROLLMENT is required with EZVM_RELEASE_SMOKE_VM"
fi
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication is invalid"
[[ -f "$project_file" ]] || fail "Xcode project not found: $project_file"

git -C "$project_root" fetch origin "$release_branch" --tags
head_commit="$(git -C "$project_root" rev-parse HEAD)"
tag_commit="$(git -C "$project_root" rev-list -n 1 "$tag" 2>/dev/null || true)"

if [[ -n "$tag_commit" ]]; then
  [[ "$tag_commit" == "$head_commit" ]] || fail "$tag exists but does not point at HEAD"
  [[ -z "$(git -C "$project_root" status --porcelain)" ]] || fail "resume requires a clean worktree"
  echo "Resuming EZVM $version from existing local tag $tag."
else
  [[ -z "$(git -C "$project_root" status --porcelain)" ]] || fail "commit or stash all changes before releasing"
  remote_commit="$(git -C "$project_root" rev-parse "origin/$release_branch")"
  [[ "$head_commit" == "$remote_commit" ]] || fail "HEAD must match origin/$release_branch before preparing a release"
  latest_tag="$(git -C "$project_root" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -1)"
  [[ "$latest_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "could not determine latest semantic version"
  latest_major="${BASH_REMATCH[1]}"; latest_minor="${BASH_REMATCH[2]}"; latest_patch="${BASH_REMATCH[3]}"
  target_major="${version%%.*}"; remainder="${version#*.}"; target_minor="${remainder%%.*}"; target_patch="${version##*.}"
  if [[ $version_reset == 1 ]]; then
    [[ $version == 1.0.0 ]] || fail "EZVM_RELEASE_VERSION_RESET only supports the explicit 1.0.0 product reset"
  elif [[ "$target_minor" == 0 && "$target_patch" == 0 && "$target_major" -gt "$latest_major" ]]; then
    : # An explicitly requested new product generation may advance the major version.
  elif [[ "$target_patch" == 0 ]]; then
    [[ "$target_major" == "$latest_major" && "$target_minor" -eq $((latest_minor + 1)) ]] || \
      fail "minor release must follow $latest_tag"
  else
    [[ "$target_major" == "$latest_major" && "$target_minor" == "$latest_minor" && "$target_patch" -eq $((latest_patch + 1)) ]] || \
      fail "patch release must follow $latest_tag"
  fi

  current_version="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u)"
  current_build="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u)"
  [[ "$current_build" =~ ^[0-9]+$ ]] || fail "Xcode targets do not share one numeric build number"
  [[ "$current_version" == "${latest_tag#v}" || "$current_version" == "$version" ]] || \
    fail "project version is $current_version, expected ${latest_tag#v} or $version"
  if [[ $version_reset == 1 ]]; then next_build=1; else next_build="$((current_build + 1))"; fi
  ruby -pi -e "gsub(/MARKETING_VERSION = [^;]+;/, 'MARKETING_VERSION = $version;'); gsub(/CURRENT_PROJECT_VERSION = [^;]+;/, 'CURRENT_PROJECT_VERSION = $next_build;')" "$project_file"
  git -C "$project_root" add -- EZVM/EZVM.xcodeproj/project.pbxproj
  git -C "$project_root" commit -m "Prepare EZVM $version (build $next_build)"
fi

configured_version="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u)"
[[ "$configured_version" == "$version" ]] || fail "project version is $configured_version, expected $version"

(cd "$project_root" && swift test)
(cd "$project_root/GuestAgent/linux" && go test ./...)
(cd "$project_root/GuestAgent/linux" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "${TMPDIR:-/tmp}/ezvm-agent-release-check" .)
(cd "$project_root/EZVM" && xcodebuild -quiet -project EZVM.xcodeproj -scheme EZVM -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "${TMPDIR:-/tmp}/ezvm-release-check-$version" \
  CODE_SIGNING_ALLOWED=NO clean build)

if [[ -z "$tag_commit" ]]; then
  git -C "$project_root" tag -a "$tag" -m "EZVM $version"
fi

APPLE_ID="${APPLE_ID:-}" APPLE_SPECIFIC_PASSWORD="${APPLE_SPECIFIC_PASSWORD:-}" APPLE_TEAM_ID="${APPLE_TEAM_ID:-}" \
EZVM_RELEASE_BRANCH="$release_branch" EZVM_RELEASE_SMOKE_ENROLLMENT="${EZVM_RELEASE_SMOKE_ENROLLMENT:-}" \
  "$project_root/scripts/publish-release.sh" "$version"

echo "EZVM $version is signed, notarized, published, and verified through Homebrew."
