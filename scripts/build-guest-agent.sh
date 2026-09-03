#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
output_dir="${2:-$project_root/dist}"

if [[ -z "$version" ]]; then
  echo "usage: $0 <version> [output-directory]" >&2
  exit 64
fi
version="${version#v}"
command -v go >/dev/null 2>&1 || { echo "Go is required to build the guest agent." >&2; exit 69; }

mkdir -p "$output_dir"
staging="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-guest-agent.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

(
  cd "$project_root/GuestAgent/linux"
  go test ./...
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
    -trimpath \
    -ldflags "-s -w -X main.version=$version" \
    -o "$staging/ezvm-agent-linux-arm64" .
)

cp "$project_root/GuestAgent/linux/install.sh" "$staging/install.sh"
cp "$project_root/GuestAgent/linux/ezvm-agent.service" "$staging/ezvm-agent.service"
cp "$project_root/GuestAgent/linux/ezvm-session-agent.service" "$staging/ezvm-session-agent.service"
cp "$project_root/GuestAgent/linux/ezvm-agent.openrc" "$staging/ezvm-agent.openrc"
chmod 0755 "$staging/ezvm-agent-linux-arm64" "$staging/install.sh" "$staging/ezvm-agent.openrc"
chmod 0644 "$staging/ezvm-agent.service" "$staging/ezvm-session-agent.service"

archive="EZVM-GuestAgent-$version-linux-arm64.tar.gz"
tar -C "$staging" -czf "$output_dir/$archive" \
  ezvm-agent-linux-arm64 install.sh ezvm-agent.service ezvm-session-agent.service ezvm-agent.openrc
(
  cd "$output_dir"
  shasum -a 256 "$archive" > "$archive.sha256"
  shasum -a 256 -c "$archive.sha256"
)

archive_listing="$(tar -tzf "$output_dir/$archive")"
[[ "$(printf '%s\n' "$archive_listing" | wc -l | tr -d ' ')" == "5" ]]
for expected in ezvm-agent-linux-arm64 install.sh ezvm-agent.service ezvm-session-agent.service ezvm-agent.openrc; do
  printf '%s\n' "$archive_listing" | grep -Fx "$expected" >/dev/null
done
file "$staging/ezvm-agent-linux-arm64" | grep -q 'ELF 64-bit.*ARM aarch64.*statically linked'

printf '%s\n' '{"schemaVersion":1,"machineID":"package-test","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","port":10240}' > "$staging/config.json"
for init_system in systemd openrc; do
  install_root="$staging/install-test-$init_system"
  EZVM_AGENT_ROOT="$install_root" EZVM_AGENT_INIT="$init_system" "$staging/install.sh" >/dev/null
  test -x "$install_root/usr/local/sbin/ezvm-agent"
  test "$(stat -f '%Lp' "$install_root/etc/ezvm-agent/config.json")" = "600"
  if [[ "$init_system" == systemd ]]; then
    test -f "$install_root/etc/systemd/user/ezvm-session-agent.service"
    test -L "$install_root/etc/systemd/user/graphical-session.target.wants/ezvm-session-agent.service"
    test "$(readlink "$install_root/etc/systemd/user/graphical-session.target.wants/ezvm-session-agent.service")" = "../ezvm-session-agent.service"
  fi
done

echo "Created $output_dir/$archive"
