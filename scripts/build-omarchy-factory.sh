#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_disk=${1:-}
image_version=${2:-}
omarchy_revision=${3:-}
agent_version=${4:-}
private_key=${5:-}
output_dir=${6:-}
image_url=${EZVM_OMARCHY_FACTORY_IMAGE_URL:-}
key_id=${EZVM_OMARCHY_FACTORY_KEY_ID:-ezvm-omarchy-factory-2026}

fail() { printf 'build-omarchy-factory: %s\n' "$*" >&2; exit 1; }

[[ -f $source_disk && ! -L $source_disk ]] || fail "source raw disk is missing or unsafe"
[[ -n $image_version && -n $omarchy_revision && -n $agent_version ]] || \
  fail "usage: $0 <raw-disk> <image-version> <omarchy-revision> <agent-version> <private-key> <empty-output-directory>"
[[ -f $private_key && ! -L $private_key ]] || fail "private signing key is missing or unsafe"
[[ -n $output_dir && -d $output_dir && ! -L $output_dir ]] || fail "output directory must already exist"
[[ -z $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail "output directory must be empty"
[[ $image_url == https://* ]] || fail "EZVM_OMARCHY_FACTORY_IMAGE_URL must be an HTTPS URL"
[[ $key_id =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid signing key id"

factory="$output_dir/Omarchy-Factory.asif"
manifest="$output_dir/ezvm-omarchy-factory-manifest.json"

/usr/sbin/diskutil image create from --format ASIF "$source_disk" "$factory"
swift run --package-path "$project_root" -c release omarchy-factory-tool sign \
  "$factory" "$image_url" "$image_version" "$omarchy_revision" "$agent_version" \
  "$key_id" "$private_key" "$manifest"

public_key=${EZVM_OMARCHY_FACTORY_PUBLIC_KEY:-}
if [[ -n $public_key ]]; then
  swift run --package-path "$project_root" -c release omarchy-factory-tool verify \
    "$manifest" "$factory" "$public_key"
fi

(cd "$output_dir" && shasum -a 256 Omarchy-Factory.asif ezvm-omarchy-factory-manifest.json > SHA256SUMS)
printf 'Created signed Omarchy factory in %s\n' "$output_dir"
