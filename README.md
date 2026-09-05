<p align="center">
  <img src="./Assets/EZVM-mark.png" width="160" height="160" alt="EZVM blue and orange interlocking hexagon icon">
</p>

# EZVM

**Virtual machines, made easy — a focused native app for Apple silicon Macs.**

[![macOS 27+](https://img.shields.io/badge/macOS-27%2B-111827?logo=apple)](https://support.apple.com/macos)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-111827)](https://support.apple.com/en-us/116943)
[![License](https://img.shields.io/github/license/everettjf/ezvm)](LICENSE)
[![Pages](https://github.com/everettjf/ezvm/actions/workflows/pages.yml/badge.svg)](https://everettjf.github.io/ezvm/)

![EZVM showing a running Omarchy desktop beside its virtual machine library](./Assets/screenshot1.jpg)

## Install EZVM

On an Apple silicon Mac running **macOS 27 or later**, install the signed
and notarized app with Homebrew:

```bash
brew install --cask everettjf/tap/ezvm
```

### EZVM Omarchy

**EZVM Omarchy** is a separate, single-purpose macOS app: open it and continue
directly into one persistent Omarchy workspace. It uses the same native
Virtualization.framework core as EZVM, but replaces the VM-library workflow
with Omarchy-focused onboarding, recovery, dynamic display, shared folders,
text/PNG clipboard, notifications, and focus-scoped Command-to-Super shortcuts.

[Download EZVM Omarchy 1.0.0 Alpha 44 directly](https://github.com/everettjf/ezvm/releases/download/ezvm-omarchy-v1.0.0-alpha.44/EZVM-Omarchy-1.0.0-alpha.44.zip).
No separate EZVM installation or Homebrew command is required: on first launch,
the app downloads and verifies its pinned Omarchy Factory image and creates the
persistent workspace. Allow approximately **16 GiB of free disk space**.

It is an independent community preview for Apple silicon Macs running macOS 27
or later—not an Omarchy-endorsed stable release. The remaining Daily Driver
endurance work is tracked in the
[EZVM Omarchy follow-up TODO](docs/todo/EZVM_OMARCHY_TODO.md).

EZVM uses Apple's [`Virtualization.framework`](https://developer.apple.com/documentation/virtualization) to create and run macOS and Linux virtual machines with a focused SwiftUI interface. It aims to be dependable, understandable, and useful without becoming a full emulation suite.

> **Project status:** EZVM is Developer ID-signed and Apple-notarized. VM software can affect large disk images, so keep backups of important guests.

## Screenshots

<p align="center">
  <img src="./Assets/screenshot2.png" width="58%" alt="EZVM randomly naming a virtual machine Saturn and saving it under EZVM Virtual Machines">
  <img src="./Assets/screenshot3.png" width="39%" alt="EZVM snapshot history tree with restore and protection controls">
</p>

## What it does

- Creates and runs macOS virtual machines from a local IPSW, a selectable macOS version, or Apple's latest supported restore image
- Creates and runs ARM64 Linux virtual machines from a local ISO or a built-in list of common distributions
- Stores machines in `~/EZVM Virtual Machines` by default; any other location can still be chosen
- Keeps downloaded system images in a shared store and reuses them when creating more machines
- Takes, restores, and deletes snapshots of a stopped machine (APFS copy-on-write clones)
- Clones stopped machines with a new hardware identity and imports/exports checksum-verified `.ezvmexport` packages
- Integrates with an optional authenticated Linux guest agent for readiness, IP reporting, SSH links, safe file transfer, and explicit shutdown/restart commands
- Installs an `ezvm` CLI with versioned JSON inspection, validation, diagnostics, and headless start/status/stop commands
- Configures CPU, memory, display, storage, networking, audio, pointing devices, and shared directories
- Accelerates Linux desktops with a native Custom Virtio GPU backed by
  VirGLRenderer and ANGLE/Metal; macOS guests retain Apple native graphics and
  Linux guests fall back to Apple Virtio if Custom VirGL can't start
- Uses Apple's native virtualization stack—no bundled hypervisor or cross-architecture emulation
- Keeps the app and its VM configuration format intentionally small

## Requirements

- An Apple silicon Mac
- macOS 27 or later
- An ARM64 guest image; EZVM does not emulate x86 guests

## Installation details

### EZVM only

Install the signed and notarized release from the EZVM Homebrew tap:

```sh
brew install --cask everettjf/tap/ezvm
```

Or download the archive from [GitHub Releases](https://github.com/everettjf/ezvm/releases/latest).

### EZVM Omarchy

[Download the dedicated signed and notarized Alpha](https://github.com/everettjf/ezvm/releases/download/ezvm-omarchy-v1.0.0-alpha.44/EZVM-Omarchy-1.0.0-alpha.44.zip),
open `EZVM Omarchy.app`, and complete the native owner setup. The app handles
the verified Omarchy image download and persistent workspace automatically.
The older `scripts/install-omarchy.sh` path remains available for users who
specifically want Omarchy as a VM inside the general-purpose EZVM app, but it
is no longer the recommended Omarchy experience.

![Omarchy reaching its first-run welcome screen inside EZVM](./docs/assets/omarchy-ezvm.png)

### Command line and headless mode

The Homebrew cask links `ezvm` into Homebrew's executable prefix. Every
command writes one schema-versioned JSON object and uses deterministic exit
codes, making it suitable for local scripts:

```sh
ezvm list
ezvm inspect "My Linux VM"
ezvm validate "/path/to/My VM.ezvm"
ezvm doctor
ezvm start "My Linux VM" --timeout 90
ezvm status "My Linux VM"
ezvm stop "My Linux VM" --timeout 30
ezvm install-image preinstalled-image.json --image disk.raw \
  --destination "$HOME/EZVM Virtual Machines/My Linux VM.ezvm" --timeout 300
```

Use `--root /path/to/library` one or more times when machines are stored outside
`~/EZVM Virtual Machines`. Headless mode runs the signed EZVM virtualization
process without presenting a VM window. Stop first requests a guest shutdown
and uses a bounded force-stop fallback.

`install-image` imports a decoded, bootable ARM64 raw disk described by the
versioned [preinstalled-image manifest](docs/PREINSTALLED_IMAGE_MANIFEST.md).
Both the CLI and signed app verify its logical size and SHA-256, and interrupted
installation leaves no partial machine bundle.

## Build from source

1. Clone this repository.
2. Open `EZVM/EZVM.xcodeproj` in Xcode.
3. Select the **EZVM** scheme and your Mac as the run destination.
4. Choose your own development team and bundle identifier if code signing requires it.
5. Build and run with <kbd>⌘R</kbd>.

To build the independent EZVM Omarchy app instead, open
`EZVMOmarchy/EZVMOmarchy.xcodeproj` and select the **EZVM Omarchy** scheme. Its
architecture, product boundaries, image policy, security model, and acceptance
history are documented in the
[EZVM Omarchy product plan](docs/EZVM_OMARCHY_PLAN.md).

### Linux graphics backends

EZVM selects the graphics backend at runtime:

| Host and guest | Graphics path |
| --- | --- |
| macOS 27+ host, Linux guest | Custom Virtio GPU → VirGLRenderer → ANGLE/Metal |
| macOS guest | Apple native Mac graphics path |

The Custom VirGL path supports zero-copy scanout presentation, display-clock
frame pacing, authenticated guest keyboard/wheel input, and guest-acknowledged
dynamic resolution for window and full-screen transitions. It intentionally
does not support Virtualization.framework machine-state save/restore: restoring
guest RAM alone cannot reconstruct VirGL renderer contexts and resources.
Stopped-VM file snapshots remain supported.

Implementation and validation details are in the
[Custom VirGL architecture notes](docs/CUSTOM_VIRGL_ARCHITECTURE.md),
[performance guide](docs/VIRGL_PERFORMANCE.md), and isolated
[prototype record](Experiments/VZVirtioGPUPrototype/README.md).

If a VM opens without a usable window, input appears only after pointer
movement, full screen is stretched, Command-to-Super shortcuts fail, setup
loops, or a release repeatedly asks for Keychain access, start with the
[troubleshooting guide](docs/TROUBLESHOOTING.md). It separates host display
problems, guest Agent/compositor problems, image compatibility, and release
signing problems so that one workaround does not hide a different failure.

The September 2026 clean-image acceptance run rebuilt and imported a 64 GiB
sparse Omarchy image, completed the entire first-run flow, reached Hyprland,
adapted the desktop to full screen, exercised Command-to-Super shortcuts and
continuous typing (including remotely synthesized Shift characters), verified
browser scrolling by hand, and confirmed guest NAT, DNS, TLS 1.3/HTTP/2, and
the real pacman update path. The deployment target is macOS 27; Linux guests
select Custom VirGL while retaining the Apple Virtio startup fallback.

## Guest images

### macOS

Pick a macOS version from the built-in list in the creation flow (or use the latest supported restore image), or select a compatible `.ipsw` restore image from disk. Apple publishes current restore images through `Virtualization.framework`; third-party indexes such as [ipsw.me](https://ipsw.me/product/Mac) can help locate older versions.

### Linux

Pick a distribution from the built-in list in the creation flow (Ubuntu Server/Desktop, Debian, Fedora), or choose any **ARM64 / AArch64** installer ISO, for example [Ubuntu](https://ubuntu.com/download/server/arm) or [Fedora](https://fedoraproject.org/server/download). Intel/AMD (`x86_64`) images are not supported.

## Direction

EZVM is not trying to replace UTM, VirtualBuddy, Tart, or Lima. Its direction is narrower:

1. Make VM creation, launch, stop, recovery, and error handling reliable.
2. Keep local macOS 27 tests, signed releases, Homebrew distribution,
   diagnostics, and configuration migration reproducible. Hosted CI can return
   when a genuine macOS 27 runner can execute the same GUI and VM gates.
3. Expose a small, local automation surface so scripts and AI agents can create, start, inspect, and discard isolated VMs safely.

The automation layer will remain local-first, explicit, and opt-in. EZVM will not embed an AI model or require a cloud account. See the [refresh roadmap](docs/ROADMAP.md), [ecosystem research](docs/RESEARCH.md), and [Homebrew distribution plan](docs/HOMEBREW.md).

## Contributing

Issues and focused pull requests are welcome. During the refresh, reliability fixes, reproducible bug reports, tests, accessibility improvements, and documentation updates have priority over broad new features.

When reporting a VM problem, include the host macOS version, Mac model/chip, guest OS and image source, and the last operation performed. Do not attach VM disks or logs containing secrets.

## Community

- [GitHub Issues](https://github.com/everettjf/ezvm/issues) for bugs and focused feature requests
- [GitHub Issues](https://github.com/everettjf/ezvm/issues) for questions and design ideas
- [Discord](https://discord.gg/eGzEaP6TzR) for informal conversation

## License

EZVM is available under the [MIT License](LICENSE).
