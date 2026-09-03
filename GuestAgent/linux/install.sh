#!/bin/sh
set -eu

install_root=${EZVM_AGENT_ROOT:-}
init_system=${EZVM_AGENT_INIT:-auto}

if [ -z "$install_root" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root." >&2
  exit 1
fi

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test -x "$bundle_dir/ezvm-agent-linux-arm64"
test -f "$bundle_dir/config.json"

install -d -m 0755 "$install_root/etc/ezvm-agent" "$install_root/usr/local/sbin"
install -m 0600 "$bundle_dir/config.json" "$install_root/etc/ezvm-agent/config.json"
install -m 0755 "$bundle_dir/ezvm-agent-linux-arm64" "$install_root/usr/local/sbin/ezvm-agent"

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
  install -d -m 0755 "$install_root/etc/systemd/system" "$install_root/etc/systemd/user"
  install -m 0644 "$bundle_dir/ezvm-agent.service" "$install_root/etc/systemd/system/ezvm-agent.service"
  install -m 0644 "$bundle_dir/ezvm-session-agent.service" "$install_root/etc/systemd/user/ezvm-session-agent.service"
  install -d -m 0755 "$install_root/etc/systemd/user/graphical-session.target.wants"
  ln -sfn ../ezvm-session-agent.service "$install_root/etc/systemd/user/graphical-session.target.wants/ezvm-session-agent.service"
  if [ -z "$install_root" ]; then
    systemctl daemon-reload
    systemctl enable --now ezvm-agent.service
  fi
elif [ "$init_system" = openrc ]; then
  install -d -m 0755 "$install_root/etc/init.d"
  install -m 0755 "$bundle_dir/ezvm-agent.openrc" "$install_root/etc/init.d/ezvm-agent"
  if [ -z "$install_root" ]; then
    rc-update add ezvm-agent default
    rc-service ezvm-agent restart
  fi
else
  echo "Installed the agent, but this distribution needs a manual service definition." >&2
  exit 2
fi

echo "EZVM guest agent installed."
