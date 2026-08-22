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
staging="$(mktemp -d "${RUNNER_TEMP:-/tmp}/easyvm-guest-agent.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

(
  cd "$project_root/GuestAgent/linux"
  go test ./...
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
    -trimpath \
    -ldflags "-s -w -X main.version=$version" \
    -o "$staging/easyvm-agent-linux-arm64" .
)

cp "$project_root/GuestAgent/linux/install.sh" "$staging/install.sh"
cp "$project_root/GuestAgent/linux/easyvm-agent.service" "$staging/easyvm-agent.service"
cp "$project_root/GuestAgent/linux/easyvm-agent.openrc" "$staging/easyvm-agent.openrc"
chmod 0755 "$staging/easyvm-agent-linux-arm64" "$staging/install.sh" "$staging/easyvm-agent.openrc"
chmod 0644 "$staging/easyvm-agent.service"

archive="EasyVM-GuestAgent-$version-linux-arm64.tar.gz"
tar -C "$staging" -czf "$output_dir/$archive" \
  easyvm-agent-linux-arm64 install.sh easyvm-agent.service easyvm-agent.openrc
(
  cd "$output_dir"
  shasum -a 256 "$archive" > "$archive.sha256"
  shasum -a 256 -c "$archive.sha256"
)

archive_listing="$(tar -tzf "$output_dir/$archive")"
[[ "$(printf '%s\n' "$archive_listing" | wc -l | tr -d ' ')" == "4" ]]
for expected in easyvm-agent-linux-arm64 install.sh easyvm-agent.service easyvm-agent.openrc; do
  printf '%s\n' "$archive_listing" | grep -Fx "$expected" >/dev/null
done
file "$staging/easyvm-agent-linux-arm64" | grep -q 'ELF 64-bit.*ARM aarch64.*statically linked'

printf '%s\n' '{"schemaVersion":1,"machineID":"package-test","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","port":10240}' > "$staging/config.json"
for init_system in systemd openrc; do
  install_root="$staging/install-test-$init_system"
  EASYVM_AGENT_ROOT="$install_root" EASYVM_AGENT_INIT="$init_system" "$staging/install.sh" >/dev/null
  test -x "$install_root/usr/local/sbin/easyvm-agent"
  test "$(stat -f '%Lp' "$install_root/etc/easyvm-agent/config.json")" = "600"
done

echo "Created $output_dir/$archive"
