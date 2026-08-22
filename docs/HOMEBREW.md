# Homebrew distribution

EasyVM is a macOS application, so it should be distributed as a **Homebrew Cask**, not a source-building Formula.

EasyVM is published through the project's Homebrew tap:

```sh
brew install --cask everettjf/tap/easyvm
```

## Current release

The `v3.3.0` release meets the distribution requirements:

- The release is tagged and hosted by GitHub Releases.
- The app is signed with Developer ID Application team `YPV49M8592`.
- Apple notarization and Gatekeeper assessment pass.
- The immutable ZIP SHA-256 is `2c4c95a2f88d7b98fbdc0c1e3a079337918898b2f02734d878b624f8019ad194`.
- `brew install --cask everettjf/tap/easyvm` has been tested successfully.

GitHub Releases should remain the source of truth. The Cask is a small installation manifest pointing at the immutable release artifact.

## Cask

```ruby
# typed: strict
# frozen_string_literal: true

cask "easyvm" do
  version "3.3.0"
  sha256 "2c4c95a2f88d7b98fbdc0c1e3a079337918898b2f02734d878b624f8019ad194"

  url "https://github.com/everettjf/easyvm/releases/download/v#{version}/EasyVM-#{version}.zip?notarized=1"
  name "EasyVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://xnu.app/easyvm"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "EasyVM.app"

  zap trash: [
    "~/Library/Application Support/EasyVM",
    "~/Library/Preferences/com.everettjf.easyvm.plist",
    "~/Library/Saved Application State/com.everettjf.easyvm.savedState",
  ]
end
```

The `zap` list covers application state only. VM bundles are never removed by uninstall or zap.

## Publication process

For a normal patch release, export the Apple notarization credentials and run the one-command publisher:

```sh
export APPLE_ID="developer@example.com"
export APPLE_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_TEAM_ID="YPV49M8592"
scripts/release-patch.sh
```

Set `EASYVM_RELEASE_SMOKE_VM` to a prepared ARM64 Linux VM bundle and
`EASYVM_RELEASE_SMOKE_ENROLLMENT` to its mode-`0600` Agent enrollment file.
Release automation uses isolated APFS clones, tests GUI readiness, two
concurrent headless VMs, Agent authentication and byte-exact file transfer,
guest KVM API availability, and clean stop. The source VM is not modified. The
same gates run against the notarized archive and the published Homebrew Cask.

The script requires a clean checkout whose `HEAD` matches `origin/main`. It calculates the next patch version, updates every Xcode target, runs tests and a Release build, commits the version bump when needed, pushes `main` and the tag, signs and notarizes the app locally, creates the GitHub Release, then updates `everettjf/homebrew-tap`. Set `EASYVM_HOMEBREW_TAP` only when publishing to a different tap checkout URL.

1. Build and sign the application with its virtualization entitlement and hardened runtime.
2. Create the GitHub Release and upload the immutable archive plus checksum.
3. Test a local Cask against that exact URL and SHA-256.
4. Publish the Cask to `everettjf/homebrew-tap` automatically after the signed release succeeds.
5. Submit it to `Homebrew/homebrew-cask` once EasyVM meets upstream inclusion requirements; the shorter command will then become `brew install --cask easyvm`.
6. Verify install, upgrade and uninstall on a clean supported Mac.
7. Publish the working install command in the README and website.

## Automation boundary

Release automation generates a candidate archive when credentials are unavailable. GitHub Release and Homebrew publication remain gated on a Developer ID certificate, Apple notarization credentials, and tap access.
