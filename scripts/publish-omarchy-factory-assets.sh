#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
mode=${1:-}
tag=${2:-}
asset_dir=${3:-}
public_key=${4:-}
repository=${EZVM_OMARCHY_IMAGE_REPOSITORY:-everettjf/omarchy-aarch64-image}

fail() { printf 'publish-omarchy-factory-assets: %s\n' "$*" >&2; exit "${2:-1}"; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1" 69; }

[[ $mode == verify || $mode == publish ]] || \
  fail "usage: $0 verify|publish <release-tag> <asset-directory> <public-key>" 64
[[ $tag =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid release tag" 64
[[ $repository =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "invalid GitHub repository" 64
[[ -d $asset_dir && ! -L $asset_dir ]] || fail "asset directory is missing or unsafe" 66
[[ -f $public_key && ! -L $public_key ]] || fail "public key is missing or unsafe" 66
for command in ruby shasum stat; do require_command "$command"; done

asset_dir=$(cd "$asset_dir" && pwd)
manifest="$asset_dir/ezvm-omarchy-factory-manifest.json"
factory="$asset_dir/Omarchy-Factory.asif"
checksum="$asset_dir/EZVM_FACTORY_SHA256SUMS"
for path in "$manifest" "$factory" "$checksum"; do
  [[ -f $path && ! -L $path ]] || fail "required Factory input is missing or unsafe: $path" 66
done

parts=("$asset_dir"/Omarchy-Factory.asif.part-*)
[[ ${#parts[@]} -ge 2 && ${#parts[@]} -le 32 ]] || fail "expected between 2 and 32 Factory parts" 66
for part in "${parts[@]}"; do
  [[ -f $part && ! -L $part ]] || fail "Factory part is missing or unsafe: $part" 66
done

swift run --package-path "$project_root" -c release omarchy-factory-tool verify \
  "$manifest" "$factory" "$public_key"
ruby -e '
  lines = File.readlines(ARGV.fetch(0), chomp: true)
  names = lines.map do |line|
    match = /\A[0-9a-f]{64}  ([A-Za-z0-9._-]+)\z/.match(line)
    abort "unsafe Factory checksum entry" unless match
    match[1]
  end
  abort "Factory checksum entries differ from publishable assets" unless names == ARGV.drop(1)
' "$checksum" "${parts[@]##*/}" "$(basename "$manifest")"
(cd "$asset_dir" && shasum -a 256 -c "$(basename "$checksum")")

expected_base="https://github.com/$repository/releases/download/$tag"
ruby -rjson -ruri -e '
  manifest = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong Factory schema" unless manifest.dig("payload", "schemaVersion") == 2
  parts = manifest.dig("payload", "imageParts")
  abort "missing Factory parts" unless parts.is_a?(Array)
  expected = ARGV.drop(2)
  actual = parts.map { |part| File.basename(URI.parse(part.fetch("url")).path) }
  abort "manifest part order or names differ from assets" unless actual == expected
  base = ARGV.fetch(1)
  abort "manifest points outside the requested immutable release" unless parts.each_with_index.all? { |part, index|
    part.fetch("url") == "#{base}/#{expected.fetch(index)}"
  }
' "$manifest" "$expected_base" "${parts[@]##*/}"

if [[ $mode == verify ]]; then
  printf 'Verified multipart Factory assets for %s at %s\n' "$tag" "$asset_dir"
  exit 0
fi

require_command gh
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication is invalid" 77
release_json=$(gh release view "$tag" --repo "$repository" --json isDraft,tagName)
ruby -rjson -e '
  value = JSON.parse(ARGV.fetch(0))
  abort "release tag mismatch" unless value["tagName"] == ARGV.fetch(1)
  abort "Factory assets may only be added to a draft release" unless value["isDraft"] == true
' "$release_json" "$tag"

upload_assets=("$manifest" "$checksum" "${parts[@]}")
release_id=$(gh api "repos/$repository/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$tag\") | .id")
[[ $release_id =~ ^[0-9]+$ ]] || fail "could not resolve draft release" 67
release_json=$(gh api "repos/$repository/releases/$release_id")
missing_assets=()
for asset in "${upload_assets[@]}"; do
  name=$(basename "$asset")
  expected="sha256:$(shasum -a 256 "$asset" | awk '{print $1}')"
  actual=$(ruby -rjson -e '
    value = JSON.parse(File.read(ARGV.fetch(0)))
    asset = value.fetch("assets").find { |candidate| candidate["name"] == ARGV.fetch(1) }
    puts asset && asset["digest"]
  ' <(printf '%s' "$release_json") "$name")
  if [[ -z $actual ]]; then
    missing_assets+=("$asset")
  elif [[ $actual != "$expected" ]]; then
    fail "refusing to overwrite mismatched release asset: $name" 65
  else
    printf 'Reusing matching draft asset: %s\n' "$name"
  fi
done
if [[ ${#missing_assets[@]} -gt 0 ]]; then
  gh release upload "$tag" --repo "$repository" "${missing_assets[@]}"
fi

release_json=$(gh api "repos/$repository/releases/$release_id")
for asset in "${upload_assets[@]}"; do
  name=$(basename "$asset")
  expected="sha256:$(shasum -a 256 "$asset" | awk '{print $1}')"
  actual=$(ruby -rjson -e '
    value = JSON.parse(File.read(ARGV.fetch(0)))
    asset = value.fetch("assets").find { |candidate| candidate["name"] == ARGV.fetch(1) }
    puts asset && asset["digest"]
  ' <(printf '%s' "$release_json") "$name")
  [[ $actual == "$expected" ]] || fail "uploaded asset digest mismatch: $name" 67
done

printf 'Uploaded and verified multipart Factory assets on draft %s\n' "$tag"
