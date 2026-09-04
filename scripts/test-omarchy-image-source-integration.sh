#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-image-source.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
profile="$fixture/profiles/aarch64-virt"
agent_ref=$(git -C "$project_root" rev-parse HEAD)
mkdir -p "$fixture/bin" "$profile/overlay/etc/systemd/system" "$profile/overlay/etc/systemd/user" \
  "$profile/overlay/usr/local/libexec"
cp "$project_root/EZVMOmarchy/GuestOverlay/systemd/mnt-ezvm\x2dshared.mount" \
  "$profile/overlay/etc/systemd/system/mnt-ezvm\x2dshared.mount"
cp "$project_root/EZVMOmarchy/GuestOverlay/systemd/ezvm-session-agent.service" \
  "$profile/overlay/etc/systemd/user/ezvm-session-agent.service"
printf '%s\n' wl-clipboard >"$profile/runtime-packages"
printf '%s\n' '#!/bin/bash' >"$profile/overlay/usr/local/libexec/ezvm-owner-provisioning"
printf 'EZVM_GUEST_AGENT_REF=%s\nWL_CLIPBOARD_RS_REF=%s\n' \
  "$agent_ref" 2f6a8852665bd1891a3f3ffa204e62b0f588ef95 >"$fixture/sources.env"
cat >"$fixture/bin/build-image" <<'EOF'
target_chroot systemctl enable 'mnt-ezvm\x2dshared.mount'
install -d -m755 "$MOUNT_DIR/mnt/ezvm-shared"
install -m755 "$EZVM_WL_COPY_BINARY" "$MOUNT_DIR/usr/local/bin/wl-copy"
target_chroot systemctl --global enable ezvm-session-agent.service
install -m755 ezvm-owner-provisioning /usr/local/libexec/ezvm-owner-provisioning
required_paths=(
  'etc/systemd/system/mnt-ezvm\x2dshared.mount'
  etc/systemd/user/ezvm-session-agent.service
  'etc/systemd/system/multi-user.target.wants/mnt-ezvm\x2dshared.mount'
  mnt/ezvm-shared
  usr/local/bin/wl-copy
  usr/local/libexec/ezvm-owner-provisioning
  etc/systemd/user/graphical-session.target.wants/ezvm-session-agent.service
)
EOF
cp "$fixture/bin/build-image" "$fixture/build-image.valid"

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
printf '%s\n' wl-clipboard >"$profile/runtime-packages"
sed -i '' '/EZVM_WL_COPY_BINARY/d' "$fixture/bin/build-image"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted an image without the stdin-safe wl-copy frontend" >&2
  exit 1
fi
cp "$fixture/build-image.valid" "$fixture/bin/build-image"
rm "$profile/overlay/usr/local/libexec/ezvm-owner-provisioning"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted an image without authenticated owner provisioning" >&2
  exit 1
fi
printf '%s\n' '#!/bin/bash' >"$profile/overlay/usr/local/libexec/ezvm-owner-provisioning"
printf 'EZVM_GUEST_AGENT_REF=%040d\nWL_CLIPBOARD_RS_REF=%s\n' \
  0 2f6a8852665bd1891a3f3ffa204e62b0f588ef95 >"$fixture/sources.env"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted a pin without Session Agent implementation" >&2
  exit 1
fi

echo "Verified Omarchy image-source integration contract and rejection gates."
