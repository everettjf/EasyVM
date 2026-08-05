# Homebrew distribution plan

EasyVM is a macOS application, so it should be distributed as a **Homebrew Cask**, not a source-building Formula.

The intended user experience is:

```sh
brew install everettjf/tap/easyvm
```

## Release prerequisites

The Cask must not be published until all of the following are true:

- A stable semantic version has been tagged, for example `v2.0.0`.
- GitHub Releases contains a versioned `EasyVM-<version>.dmg` or `.zip`.
- The application is signed with a Developer ID Application certificate and notarized by Apple.
- The archive has a published SHA-256 checksum.
- Installation and first launch have been tested on a clean supported Mac.
- The download URL is stable and does not require authentication.

GitHub Releases should remain the source of truth. The Cask is a small installation manifest pointing at the immutable release artifact.

## Proposed Cask

Once a real release exists, the initial manifest should resemble:

```ruby
# typed: strict
# frozen_string_literal: true

cask "easyvm" do
  version "2.0.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/everettjf/easyvm/releases/download/v#{version}/EasyVM-#{version}.dmg"
  name "EasyVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://everettjf.github.io/easyvm/"

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "EasyVM.app"

  zap trash: [
    "~/Library/Preferences/com.everettjf.easyvm.plist",
    "~/Library/Saved Application State/com.everettjf.easyvm.savedState",
  ]
end
```

The final `zap` list must be verified against the refreshed application's actual bundle identifier and storage policy. VM bundles must never be included in `zap` unless users explicitly choose their deletion.

## Publication sequence

1. Build, sign, notarize and staple the application artifact.
2. Create the GitHub Release and upload the immutable archive plus checksum.
3. Test a local Cask against that exact URL and SHA-256.
4. Publish the Cask to `everettjf/homebrew-tap` automatically after the signed release succeeds.
5. Submit it to `Homebrew/homebrew-cask` once EasyVM meets upstream inclusion requirements; the shorter command will then become `brew install --cask easyvm`.
6. Verify install, upgrade and uninstall on a clean supported Mac.
7. Add the working install command to the README and website; remove the “planned” label.

## Automation boundary

Release automation may generate a candidate Cask and checksum, but publishing to Homebrew should remain gated on a successfully signed/notarized release and an installation smoke test. A broken Cask damages trust more than a manual release step costs.
