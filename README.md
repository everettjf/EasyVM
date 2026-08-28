# EZVM

**A simple, native virtual machine app for Apple silicon Macs.**

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111827?logo=apple)](https://support.apple.com/macos)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-111827)](https://support.apple.com/en-us/116943)
[![License](https://img.shields.io/github/license/everettjf/ezvm)](LICENSE)
[![Pages](https://github.com/everettjf/ezvm/actions/workflows/pages.yml/badge.svg)](https://everettjf.github.io/ezvm/)

EZVM uses Apple's [`Virtualization.framework`](https://developer.apple.com/documentation/virtualization) to create and run macOS and Linux virtual machines with a focused SwiftUI interface. It aims to be dependable, understandable, and useful without becoming a full emulation suite.

> **Project status:** EZVM is Developer ID-signed and Apple-notarized. VM software can affect large disk images, so keep backups of important guests.

## Screenshots

![EZVM running Alpine Linux and macOS at the same time, with both machines shown as running in the library](./Assets/screenshot1.png)

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
- Uses Apple's native virtualization stack—no bundled hypervisor or cross-architecture emulation
- Keeps the app and its VM configuration format intentionally small

## Requirements

- An Apple silicon Mac
- macOS 26 Tahoe or later
- An ARM64 guest image; EZVM does not emulate x86 guests

## Install

### EZVM + Omarchy in one command

On an Apple Silicon Mac with Homebrew, install or update EZVM and install the
latest verified Omarchy AArch64 image with one command:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/everettjf/ezvm/main/scripts/install-omarchy.sh)"
```

The script verifies the published Omarchy installer against its Release
checksum and installs the preinstalled image at
`~/EZVM Virtual Machines/Omarchy.ezvm`. Before downloading, it displays the
available space on the destination volume and stops unless at least 15 GiB is
available.

![Omarchy reaching its first-run welcome screen inside EZVM](./docs/assets/omarchy-ezvm.png)

### EZVM only

Install the signed and notarized release from the EZVM Homebrew tap:

```sh
brew install --cask everettjf/tap/ezvm
```

Or download the archive from [GitHub Releases](https://github.com/everettjf/ezvm/releases/latest).

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

## Guest images

### macOS

Pick a macOS version from the built-in list in the creation flow (or use the latest supported restore image), or select a compatible `.ipsw` restore image from disk. Apple publishes current restore images through `Virtualization.framework`; third-party indexes such as [ipsw.me](https://ipsw.me/product/Mac) can help locate older versions.

### Linux

Pick a distribution from the built-in list in the creation flow (Ubuntu Server/Desktop, Debian, Fedora), or choose any **ARM64 / AArch64** installer ISO, for example [Ubuntu](https://ubuntu.com/download/server/arm) or [Fedora](https://fedoraproject.org/server/download). Intel/AMD (`x86_64`) images are not supported.

## Direction

EZVM is not trying to replace UTM, VirtualBuddy, Tart, or Lima. Its direction is narrower:

1. Make VM creation, launch, stop, recovery, and error handling reliable.
2. Add tests, CI, signed releases, Homebrew distribution, diagnostics, and configuration migration.
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
