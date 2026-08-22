#!/bin/sh
set -eu

install_root=${EASYVM_AGENT_ROOT:-}
init_system=${EASYVM_AGENT_INIT:-auto}

if [ -z "$install_root" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root." >&2
  exit 1
fi

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test -x "$bundle_dir/easyvm-agent-linux-arm64"
test -f "$bundle_dir/config.json"

install -d -m 0755 "$install_root/etc/easyvm-agent" "$install_root/usr/local/sbin"
install -m 0600 "$bundle_dir/config.json" "$install_root/etc/easyvm-agent/config.json"
install -m 0755 "$bundle_dir/easyvm-agent-linux-arm64" "$install_root/usr/local/sbin/easyvm-agent"

if [ "$init_system" = auto ]; then
  if command -v systemctl >/dev/null 2>&1; then
    init_system=systemd
  elif command -v rc-update >/dev/null 2>&1; then
    init_system=openrc
  else
    init_system=unknown
  fi
fi

if [ "$init_system" = systemd ]; then
  install -d -m 0755 "$install_root/etc/systemd/system"
  install -m 0644 "$bundle_dir/easyvm-agent.service" "$install_root/etc/systemd/system/easyvm-agent.service"
  if [ -z "$install_root" ]; then
    systemctl daemon-reload
    systemctl enable --now easyvm-agent.service
  fi
elif [ "$init_system" = openrc ]; then
  install -d -m 0755 "$install_root/etc/init.d"
  install -m 0755 "$bundle_dir/easyvm-agent.openrc" "$install_root/etc/init.d/easyvm-agent"
  if [ -z "$install_root" ]; then
    rc-update add easyvm-agent default
    rc-service easyvm-agent restart
  fi
else
  echo "Installed the agent, but this distribution needs a manual service definition." >&2
  exit 2
fi

echo "EasyVM guest agent installed."
