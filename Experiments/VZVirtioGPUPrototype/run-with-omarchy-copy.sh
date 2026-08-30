#!/bin/zsh
set -euo pipefail

experiment_dir=${0:A:h}
source_vm='/Users/eevv/EZVM Virtual Machines/Omarchy.ezvm'
scratch_dir=$(mktemp -d /tmp/ezvm-vz-gpu.XXXXXX)
disk_copy="$scratch_dir/Disk.img"
nvram_copy="$scratch_dir/NVRAM"
trap 'rm -rf -- "$scratch_dir"' EXIT

if [[ ! -f "$source_vm/Disk.img" || ! -f "$source_vm/NVRAM" ]]; then
    echo "Omarchy source VM was not found at: $source_vm" >&2
    exit 1
fi

echo "Creating disposable APFS clones in: $scratch_dir"
cp -c "$source_vm/Disk.img" "$disk_copy"
cp -c "$source_vm/NVRAM" "$nvram_copy"

SWIFTPM_MODULECACHE_OVERRIDE=/tmp/ezvm-vz-gpu-swiftpm-cache \
CLANG_MODULE_CACHE_PATH=/tmp/ezvm-vz-gpu-clang-cache \
swift build --disable-sandbox --package-path "$experiment_dir"
binary="$experiment_dir/.build/debug/vz-virtio-gpu-prototype"
codesign --force --sign - --entitlements "$experiment_dir/vz-virtio-gpu.entitlements" "$binary"

echo "Starting prototype with disposable files in: $scratch_dir"
"$binary" "$disk_copy" "$nvram_copy"
