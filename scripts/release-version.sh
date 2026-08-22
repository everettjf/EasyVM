#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$project_root/EasyVM/EasyVM.xcodeproj/project.pbxproj"
version="${1#v}"
release_branch="${EASYVM_RELEASE_BRANCH:-main}"
tag="v$version"

fail() { echo "release-version: $*" >&2; exit 1; }
[[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "usage: $0 <major.minor.patch>"

for command in gh git go ruby security swift xcodebuild; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done
for variable in APPLE_ID APPLE_SPECIFIC_PASSWORD APPLE_TEAM_ID EASYVM_RELEASE_SMOKE_VM; do
  [[ -n "${!variable:-}" ]] || fail "required environment variable is missing: $variable"
done
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication is invalid"
[[ -f "$project_file" ]] || fail "Xcode project not found: $project_file"

git -C "$project_root" fetch origin "$release_branch" --tags
head_commit="$(git -C "$project_root" rev-parse HEAD)"
tag_commit="$(git -C "$project_root" rev-list -n 1 "$tag" 2>/dev/null || true)"

if [[ -n "$tag_commit" ]]; then
  [[ "$tag_commit" == "$head_commit" ]] || fail "$tag exists but does not point at HEAD"
  [[ -z "$(git -C "$project_root" status --porcelain)" ]] || fail "resume requires a clean worktree"
  echo "Resuming EasyVM $version from existing local tag $tag."
else
  [[ -z "$(git -C "$project_root" status --porcelain)" ]] || fail "commit or stash all changes before releasing"
  remote_commit="$(git -C "$project_root" rev-parse "origin/$release_branch")"
  [[ "$head_commit" == "$remote_commit" ]] || fail "HEAD must match origin/$release_branch before preparing a release"
  latest_tag="$(git -C "$project_root" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -1)"
  [[ "$latest_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "could not determine latest semantic version"
  latest_major="${BASH_REMATCH[1]}"; latest_minor="${BASH_REMATCH[2]}"; latest_patch="${BASH_REMATCH[3]}"
  target_major="${version%%.*}"; remainder="${version#*.}"; target_minor="${remainder%%.*}"; target_patch="${version##*.}"
  if [[ "$target_patch" == 0 ]]; then
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
  next_build="$((current_build + 1))"
  ruby -pi -e "gsub(/MARKETING_VERSION = [^;]+;/, 'MARKETING_VERSION = $version;'); gsub(/CURRENT_PROJECT_VERSION = [^;]+;/, 'CURRENT_PROJECT_VERSION = $next_build;')" "$project_file"
  git -C "$project_root" add -- EasyVM/EasyVM.xcodeproj/project.pbxproj
  git -C "$project_root" commit -m "Prepare EasyVM $version (build $next_build)"
fi

configured_version="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u)"
[[ "$configured_version" == "$version" ]] || fail "project version is $configured_version, expected $version"

(cd "$project_root" && swift test)
(cd "$project_root/GuestAgent/linux" && go test ./...)
(cd "$project_root/GuestAgent/linux" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "${TMPDIR:-/tmp}/easyvm-agent-release-check" .)
(cd "$project_root/EasyVM" && xcodebuild -quiet -project EasyVM.xcodeproj -scheme EasyVM -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "${TMPDIR:-/tmp}/easyvm-release-check-$version" \
  CODE_SIGNING_ALLOWED=NO clean build)

if [[ -z "$tag_commit" ]]; then
  git -C "$project_root" tag -a "$tag" -m "EasyVM $version"
fi

APPLE_ID="$APPLE_ID" APPLE_SPECIFIC_PASSWORD="$APPLE_SPECIFIC_PASSWORD" APPLE_TEAM_ID="$APPLE_TEAM_ID" \
EASYVM_RELEASE_BRANCH="$release_branch" "$project_root/scripts/publish-release.sh" "$version"

echo "EasyVM $version is signed, notarized, published, and verified through Homebrew."
