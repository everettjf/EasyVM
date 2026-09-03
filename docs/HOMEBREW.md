# Homebrew distribution

EZVM is a macOS application, so it should be distributed as a **Homebrew Cask**, not a source-building Formula.

EZVM is published through the project's Homebrew tap:

```sh
brew install --cask everettjf/tap/ezvm
```

## Current release

The `v1.0.4` release meets the distribution requirements:

- The release is tagged and hosted by GitHub Releases.
- The app is signed with Developer ID Application team `YPV49M8592`.
- Apple notarization and Gatekeeper assessment pass.
- The immutable ZIP SHA-256 is `77bff3203756aab11aa512715a53839036360f40c420f328d7b435857a749925`.
- Both a `1.0.3 -> 1.0.4` Homebrew upgrade and the installed `1.0.4` app were
  tested successfully.

GitHub Releases should remain the source of truth. The Cask is a small installation manifest pointing at the immutable release artifact.

## Cask

```ruby
# typed: strict
# frozen_string_literal: true

cask "ezvm" do
  version "1.0.4"
  sha256 "77bff3203756aab11aa512715a53839036360f40c420f328d7b435857a749925"

  url "https://github.com/everettjf/ezvm/releases/download/v#{version}/EZVM-#{version}.zip?notarized=1"
  name "EZVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://xnu.app/ezvm"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "EZVM.app"
  binary "#{appdir}/EZVM.app/Contents/Helpers/ezvm"

  zap trash: [
    "~/Library/Application Support/EZVM",
    "~/Library/Preferences/com.everettjf.ezvm.plist",
    "~/Library/Saved Application State/com.everettjf.ezvm.savedState",
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

Set `EZVM_RELEASE_SMOKE_VM` to a prepared ARM64 Linux VM bundle and
`EZVM_RELEASE_SMOKE_ENROLLMENT` to its mode-`0600` Agent enrollment file.
Release automation uses isolated APFS clones, tests GUI readiness, two
concurrent headless VMs, Agent authentication and byte-exact file transfer,
guest KVM API availability, and clean stop. The source VM is not modified. The
same gates run against the notarized archive and the published Homebrew Cask.

### macOS 27 three-guest release matrix

Before publishing a macOS 27 candidate, keep stopped, disposable fixtures for
the three creation choices and run the exact signed app through the matrix:

```bash
EZVM_MATRIX_MACOS_VM="$HOME/EZVM Test Fixtures/macOS.ezvm" \
EZVM_MATRIX_OMARCHY_VM="$HOME/EZVM Test Fixtures/Omarchy.ezvm" \
EZVM_MATRIX_UBUNTU_VM="$HOME/EZVM Test Fixtures/Ubuntu.ezvm" \
EZVM_MATRIX_OMARCHY_ENROLLMENT="$HOME/EZVM Test Fixtures/omarchy-enrollment.json" \
EZVM_MATRIX_UBUNTU_ENROLLMENT="$HOME/EZVM Test Fixtures/ubuntu-enrollment.json" \
scripts/verify-macos27-guest-matrix.sh /path/to/EZVM.app 2.0.0
```

The script rejects mislabeled fixtures, verifies the app signature,
Gatekeeper, entitlements, GUI readiness, and then exercises CLI lifecycle,
concurrent ownership, forced-exit recovery, saved-state recovery, Linux EFI
recovery, Guest Agent authentication, byte-exact transfer, ASIF attachment,
VMNet Shared guest connectivity, and clean shutdown. The VMNet gate creates and
removes its own clone of the Ubuntu fixture; it never changes the source VM. Set
`EZVM_MATRIX_REQUIRE_NESTED=1` only on a supported host to add the guest KVM
gate. Fixtures are cloned before destructive recovery checks; the originals
remain unchanged.

The script requires a clean checkout whose `HEAD` matches `origin/main`. It
calculates the next patch version, updates every Xcode target, runs tests and a
Release build, commits the version bump when needed, then builds the pinned
VirGL runtime, signs and notarizes the app locally, and exercises the exact
candidate before pushing `main` and the tag. Only after those gates pass does
it create the GitHub Release and update `everettjf/homebrew-tap`. Set
`EZVM_HOMEBREW_TAP` only when publishing to a different tap checkout URL.

1. Build and sign the application with its virtualization entitlement and hardened runtime.
2. Notarize the archive, quarantine-extract it, and pass GUI plus real-VM gates.
3. Push the exact tested commit/tag and upload the immutable archive plus checksums.
4. Update `everettjf/homebrew-tap` to that exact URL and SHA-256.
5. Upgrade/install from Homebrew and repeat the GUI plus real-VM gates.
6. Submit it to `Homebrew/homebrew-cask` once EZVM meets upstream inclusion requirements; the shorter command will then become `brew install --cask ezvm`.
7. Publish the working install command in the README and website.

## Automation boundary

EZVM deliberately performs product compilation and release verification on a
local macOS 27 development machine. The repository currently keeps only the
GitHub Pages workflow; CI and Release workflows should return when a genuine
macOS 27 runner can execute the same app, GUI, Virtualization.framework, and
real-VM gates. GitHub Release and Homebrew publication remain gated on a
Developer ID certificate, Apple notarization credentials, tap access, a mode
`0600` Agent enrollment, and a disposable clone of a real ARM64 Linux VM.

## Release traps to keep fixed

- Do not publish a tag before the exact candidate has passed signing,
  notarization, quarantine extraction, GUI readiness, and real-VM gates. A tag
  must identify tested bytes, not merely compilable source.
- Do not reuse an already-running local EZVM during GUI verification. It can
  hide launch, persisted-window-state, or bundled-runtime failures in the new
  candidate.
- Do not treat `codesign`, notarization, Gatekeeper, PID existence, or Homebrew
  installation as interchangeable checks. Each proves a different boundary.
- Keep the checked-in Cask, GitHub Release asset, tap Cask, version, URL, and
  SHA-256 synchronized. Test a real previous-version upgrade as well as a clean
  install.
- Build VirGL/ANGLE from pinned sources. A successful build against whichever
  Homebrew libraries happen to be installed is not a reproducible release.
- Run VM tests against a disposable clone. Destructive recovery and SIGKILL
  scenarios must never mutate the user's only working machine or source image.

The symptom-oriented checklist is in [troubleshooting](TROUBLESHOOTING.md).
