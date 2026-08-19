# Homebrew distribution

EasyVM is a macOS application, so it should be distributed as a **Homebrew Cask**, not a source-building Formula.

EasyVM 3 is published through the project's Homebrew tap:

```sh
brew install --cask everettjf/tap/easyvm
```

## Current release

The `v3.1.0` release meets the distribution requirements:

- The release is tagged and hosted by GitHub Releases.
- The app is signed with Developer ID Application team `YPV49M8592`.
- Apple notarization and Gatekeeper assessment pass.
- The immutable ZIP SHA-256 is `1d01d142009d15abdab87d00c5bc85d5bd41d387092c5009f1d2a9e4a5f0dccc`.
- `brew install --cask everettjf/tap/easyvm` has been tested successfully.

GitHub Releases should remain the source of truth. The Cask is a small installation manifest pointing at the immutable release artifact.

## Cask

```ruby
# typed: strict
# frozen_string_literal: true

cask "easyvm" do
  version "3.1.0"
  sha256 "1d01d142009d15abdab87d00c5bc85d5bd41d387092c5009f1d2a9e4a5f0dccc"

  url "https://github.com/everettjf/easyvm/releases/download/v#{version}/EasyVM-#{version}.zip"
  name "EasyVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://everettjf.github.io/easyvm/"

  depends_on arch: :arm64
  depends_on macos: :ventura

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

1. Build and sign the application with its virtualization entitlement and hardened runtime.
2. Create the GitHub Release and upload the immutable archive plus checksum.
3. Test a local Cask against that exact URL and SHA-256.
4. Publish the Cask to `everettjf/homebrew-tap` automatically after the signed release succeeds.
5. Submit it to `Homebrew/homebrew-cask` once EasyVM meets upstream inclusion requirements; the shorter command will then become `brew install --cask easyvm`.
6. Verify install, upgrade and uninstall on a clean supported Mac.
7. Publish the working install command in the README and website.

## Automation boundary

Release automation generates a candidate archive when credentials are unavailable. GitHub Release and Homebrew publication remain gated on a Developer ID certificate, Apple notarization credentials, and tap access.
