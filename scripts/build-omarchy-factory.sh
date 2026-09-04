#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_disk=${1:-}
image_version=${2:-}
omarchy_revision=${3:-}
agent_version=${4:-}
private_key=${5:-}
output_dir=${6:-}

fail() { printf 'build-omarchy-factory: %s\n' "$*" >&2; exit 1; }

[[ -f $source_disk && ! -L $source_disk ]] || fail "source raw disk is missing or unsafe"
[[ -n $image_version && -n $omarchy_revision && -n $agent_version ]] || \
  fail "usage: $0 <raw-disk> <image-version> <omarchy-revision> <agent-version> <private-key> <empty-output-directory>"
[[ -f $private_key && ! -L $private_key ]] || fail "private signing key is missing or unsafe"
[[ -n $output_dir && -d $output_dir && ! -L $output_dir ]] || fail "output directory must already exist"
[[ -z $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail "output directory must be empty"

factory="$output_dir/Omarchy-Factory.asif"
manifest="$output_dir/ezvm-omarchy-factory-manifest.json"

"$project_root/scripts/copy-sparse-raw-to-asif.sh" "$source_disk" "$factory"
"$project_root/scripts/sign-omarchy-factory-parts.sh" \
  "$factory" "$image_version" "$omarchy_revision" "$agent_version" "$private_key"

public_key=${EZVM_OMARCHY_FACTORY_PUBLIC_KEY:-}
if [[ -n $public_key ]]; then
  swift run --package-path "$project_root" -c release omarchy-factory-tool verify \
    "$manifest" "$factory" "$public_key"
fi

printf 'Created signed Omarchy factory in %s\n' "$output_dir"
