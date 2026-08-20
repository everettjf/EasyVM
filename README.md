# EasyVM

**A simple, native virtual machine app for Apple silicon Macs.**

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111827?logo=apple)](https://support.apple.com/macos)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-111827)](https://support.apple.com/en-us/116943)
[![License](https://img.shields.io/github/license/everettjf/easyvm)](LICENSE)
[![Pages](https://github.com/everettjf/easyvm/actions/workflows/pages.yml/badge.svg)](https://everettjf.github.io/easyvm/)

EasyVM uses Apple's [`Virtualization.framework`](https://developer.apple.com/documentation/virtualization) to create and run macOS and Linux virtual machines with a focused SwiftUI interface. It aims to be dependable, understandable, and useful without becoming a full emulation suite.

> **Project status:** EasyVM 3 is the refreshed, Developer ID-signed and Apple-notarized release. VM software can affect large disk images, so keep backups of important guests.

![EasyVM machine library](./Assets/screenshot1.png)

## What it does

- Creates and runs macOS virtual machines from a local IPSW, a selectable macOS version, or Apple's latest supported restore image
- Creates and runs ARM64 Linux virtual machines from a local ISO or a built-in list of common distributions
- Stores machines in `~/Easy Virtual Machines` by default; any other location can still be chosen
- Keeps downloaded system images in a shared store and reuses them when creating more machines
- Takes, restores, and deletes snapshots of a stopped machine (APFS copy-on-write clones)
- Configures CPU, memory, display, storage, networking, audio, pointing devices, and shared directories
- Uses Apple's native virtualization stack—no bundled hypervisor or cross-architecture emulation
- Keeps the app and its VM configuration format intentionally small

## Requirements

- An Apple silicon Mac
- macOS 26 Tahoe or later
- An ARM64 guest image; EasyVM does not emulate x86 guests

## Install

Install the signed and notarized release from the EasyVM Homebrew tap:

```sh
brew install --cask everettjf/tap/easyvm
```

Or download the archive from [GitHub Releases](https://github.com/everettjf/easyvm/releases/latest).

## Build from source

1. Clone this repository.
2. Open `EasyVM/EasyVM.xcodeproj` in Xcode.
3. Select the **EasyVM** scheme and your Mac as the run destination.
4. Choose your own development team and bundle identifier if code signing requires it.
5. Build and run with <kbd>⌘R</kbd>.

## Guest images

### macOS

Pick a macOS version from the built-in list in the creation flow (or use the latest supported restore image), or select a compatible `.ipsw` restore image from disk. Apple publishes current restore images through `Virtualization.framework`; third-party indexes such as [ipsw.me](https://ipsw.me/product/Mac) can help locate older versions.

### Linux

Pick a distribution from the built-in list in the creation flow (Ubuntu Server/Desktop, Debian, Fedora), or choose any **ARM64 / AArch64** installer ISO, for example [Ubuntu](https://ubuntu.com/download/server/arm) or [Fedora](https://fedoraproject.org/server/download). Intel/AMD (`x86_64`) images are not supported.

## Direction

EasyVM is not trying to replace UTM, VirtualBuddy, Tart, or Lima. Its direction is narrower:

1. Make VM creation, launch, stop, recovery, and error handling reliable.
2. Add tests, CI, signed releases, Homebrew distribution, diagnostics, and configuration migration.
3. Expose a small, local automation surface so scripts and AI agents can create, start, inspect, and discard isolated VMs safely.

The automation layer will remain local-first, explicit, and opt-in. EasyVM will not embed an AI model or require a cloud account. See the [refresh roadmap](docs/ROADMAP.md), [ecosystem research](docs/RESEARCH.md), and [Homebrew distribution plan](docs/HOMEBREW.md).

## Contributing

Issues and focused pull requests are welcome. During the refresh, reliability fixes, reproducible bug reports, tests, accessibility improvements, and documentation updates have priority over broad new features.

When reporting a VM problem, include the host macOS version, Mac model/chip, guest OS and image source, and the last operation performed. Do not attach VM disks or logs containing secrets.

## Community

- [GitHub Issues](https://github.com/everettjf/easyvm/issues) for bugs and focused feature requests
- [GitHub Issues](https://github.com/everettjf/easyvm/issues) for questions and design ideas
- [Discord](https://discord.gg/eGzEaP6TzR) for informal conversation

## License

EasyVM is available under the [MIT License](LICENSE).
