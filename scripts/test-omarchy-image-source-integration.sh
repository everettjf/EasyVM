#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-image-source.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
profile="$fixture/profiles/aarch64-virt"
mkdir -p "$fixture/bin" "$profile/overlay/etc/systemd/system" "$profile/overlay/etc/systemd/user"
cp "$project_root/EZVMOmarchy/GuestOverlay/systemd/mnt-ezvm-shared.mount" \
  "$profile/overlay/etc/systemd/system/mnt-ezvm-shared.mount"
cp "$project_root/EZVMOmarchy/GuestOverlay/systemd/ezvm-session-agent.service" \
  "$profile/overlay/etc/systemd/user/ezvm-session-agent.service"
printf '%s\n' wl-clipboard >"$profile/runtime-packages"
cat >"$fixture/bin/build-image" <<'EOF'
target_chroot systemctl enable mnt-ezvm-shared.mount
target_chroot systemctl --global enable ezvm-session-agent.service
required_paths=(
  etc/systemd/system/mnt-ezvm-shared.mount
  etc/systemd/user/ezvm-session-agent.service
  etc/systemd/system/multi-user.target.wants/mnt-ezvm-shared.mount
  etc/systemd/user/graphical-session.target.wants/ezvm-session-agent.service
)
EOF

verify="$project_root/scripts/verify-omarchy-image-source-integration.sh"
"$verify" "$fixture" >/dev/null
printf '\nExecStart=/bin/false\n' >>"$profile/overlay/etc/systemd/user/ezvm-session-agent.service"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted a modified Session Agent unit" >&2
  exit 1
fi
cp "$project_root/EZVMOmarchy/GuestOverlay/systemd/ezvm-session-agent.service" \
  "$profile/overlay/etc/systemd/user/ezvm-session-agent.service"
sed -i '' '/wl-clipboard/d' "$profile/runtime-packages"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted an image without wl-clipboard" >&2
  exit 1
fi

echo "Verified Omarchy image-source integration contract and rejection gates."
