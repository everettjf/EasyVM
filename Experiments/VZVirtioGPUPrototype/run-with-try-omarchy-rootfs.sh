#!/bin/zsh
set -euo pipefail

experiment_dir=${0:A:h}
app_resources='/Applications/Try Omarchy.app/Contents/Resources'
source_disk='/Users/eevv/Library/Application Support/Try Omarchy/VM/v1/disks/current/rootfs.ext4'
scratch_dir=$(mktemp -d /tmp/ezvm-vz-gpu-try.XXXXXX)
disk_copy="$scratch_dir/rootfs.ext4"
unused_nvram="$scratch_dir/NVRAM"
trap 'rm -rf -- "$scratch_dir"' EXIT

if [[ ! -f "$source_disk" ]]; then
    echo "Try Omarchy working disk was not found at: $source_disk" >&2
    exit 1
fi

echo "Creating disposable Try Omarchy APFS clone in: $scratch_dir"
cp -c "$source_disk" "$disk_copy"
touch "$unused_nvram"

SWIFTPM_MODULECACHE_OVERRIDE=/tmp/ezvm-vz-gpu-swiftpm-cache \
CLANG_MODULE_CACHE_PATH=/tmp/ezvm-vz-gpu-clang-cache \
swift build --disable-sandbox --package-path "$experiment_dir"
binary="$experiment_dir/.build/debug/vz-virtio-gpu-prototype"
codesign --force --sign - --entitlements "$experiment_dir/vz-virtio-gpu.entitlements" "$binary"

echo "Starting direct-kernel VirGL test with disposable disk: $scratch_dir"
VZ_LINUX_KERNEL="$app_resources/guest/vmlinuz-linux" \
VZ_LINUX_INITRD="$app_resources/guest/initramfs-linux.img" \
VZ_LINUX_COMMAND_LINE='root=/dev/vda rw rootwait console=tty0 loglevel=4 systemd.show_status=false rd.systemd.show_status=false mitigations=off nowatchdog omarchy.qemu_virgl=1' \
"$binary" "$disk_copy" "$unused_nvram"
