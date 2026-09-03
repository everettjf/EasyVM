#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ezvm-omarchy-evidence.XXXXXX")
trap 'rm -rf "$work"' EXIT
revision=0123456789abcdef0123456789abcdef01234567
printf app >"$work/app.zip"
printf image >"$work/factory.asif"
image_sha=$(shasum -a 256 "$work/factory.asif" | awk '{print $1}')
printf '{"payload":{"imageSHA256":"%s"}}\n' "$image_sha" >"$work/manifest.json"
app_sha=$(shasum -a 256 "$work/app.zip" | awk '{print $1}')
manifest_sha=$(shasum -a 256 "$work/manifest.json" | awk '{print $1}')
started=$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ')
ended=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

write_evidence() {
  local result=${1:-passed}
  ruby -rjson -e '
    scenarios = %w[
      cleanInstall ownerProvisioning commandSuper clipboardText clipboardImage
      sharedFolder fileImport guestRestart agentRestart hostSleepWake pauseResume
      updateRollback continuousOperation
    ].to_h { |name| [name, true] }
    value = {
      schemaVersion: 1, result: ARGV.fetch(0), sourceRevision: ARGV.fetch(1),
      appArchiveSHA256: ARGV.fetch(2), factoryManifestSHA256: ARGV.fetch(3),
      factoryImageSHA256: ARGV.fetch(4), hostArchitecture: "arm64",
      hostOSBuild: "test-build", startedAt: ARGV.fetch(5), endedAt: ARGV.fetch(6),
      continuousOperationSeconds: 86_400, scenarios: scenarios
    }
    File.write(ARGV.fetch(7), JSON.pretty_generate(value))
  ' "$result" "$revision" "$app_sha" "$manifest_sha" "$image_sha" "$started" "$ended" "$work/evidence.json"
}

verify=("$project_root/scripts/verify-omarchy-release-evidence.sh" "$work/evidence.json" \
  "$work/app.zip" "$work/manifest.json" "$work/factory.asif" "$revision")
write_evidence
"${verify[@]}" >/dev/null

write_evidence failed
if "${verify[@]}" >/dev/null 2>&1; then
  echo "failed acceptance evidence was accepted" >&2
  exit 1
fi

write_evidence
printf tampered >>"$work/app.zip"
if "${verify[@]}" >/dev/null 2>&1; then
  echo "evidence for a different application archive was accepted" >&2
  exit 1
fi

echo "Verified EZVM Omarchy release evidence binding and rejection gates."
