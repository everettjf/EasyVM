# EasyVM ecosystem research

_Reviewed: August 5, 2026_

This is a lightweight product and engineering survey, not an exhaustive benchmark. Star counts are deliberately omitted because they change quickly; activity, product focus, and transferable ideas matter more.

## Comparable projects

| Project | Positioning | What it does well | Lesson for EasyVM |
| --- | --- | --- | --- |
| [UTM](https://github.com/utmapp/UTM) | Full-featured virtualization and emulation for macOS and iOS | Broad guest/architecture support, mature distribution, strong user-facing catalog | Do not compete on breadth. Native Apple-silicon-only scope is a useful constraint. |
| [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) | Native macOS VM GUI for Apple silicon, especially developer testing | Excellent macOS installation flow, guest integration, recovery and saved-state features | Treat the macOS developer workflow and guest experience as the closest quality bar. |
| [Tart](https://github.com/cirruslabs/tart) | macOS/Linux VMs for CI and automation | CLI-first lifecycle, OCI image distribution, reproducible automation | A small CLI and machine-readable output are more useful to agents than an in-app chatbot. |
| [Lima](https://github.com/lima-vm/lima) | Linux VMs for containers and developer environments | Declarative templates, mounts, networking, provisioning, mature operations | Adopt explicit configuration and diagnostics, but avoid becoming a container platform. |
| [vfkit](https://github.com/crc-org/vfkit) | Minimal command-line Virtualization.framework wrapper | Small surface area and composability | Keep the VM engine separable from SwiftUI so it can serve both GUI and automation. |
| [macosvm](https://github.com/s-u/macosvm) | Focused CLI for macOS guests | Clear, scriptable access to networking, sharing, installation and launch | Stable primitives are valuable even without a large orchestration layer. |
| [c/ua](https://github.com/trycua/cua) | Isolated computer environments for computer-use agents | Connects VM lifecycle, remote control and agent frameworks | Agent value comes from safe disposable environments, not from adding AI to every screen. |

## Market shape

The mature projects divide into three groups:

1. **General desktop virtualization:** broad compatibility and many device options.
2. **Developer and CI automation:** repeatable images, CLI/API control, headless execution and distribution.
3. **Agent sandboxes:** isolated desktops with programmatic lifecycle and computer-control interfaces.

EasyVM already has the basis of a fourth, intentionally modest position: a native GUI that exposes understandable VM primitives and can later be automated without turning into infrastructure software.

## Recommended product position

> EasyVM is the small, native VM workbench for Apple silicon: create a macOS or ARM64 Linux machine, understand its configuration, run it reliably, and automate the same safe operations when needed.

### Principles

- **Stability before features.** A failed install or corrupted configuration costs hours.
- **Native before universal.** Use Virtualization.framework well; do not add QEMU or x86 emulation.
- **Local before cloud.** No account, hosted control plane, telemetry, or model key is required.
- **GUI and automation share one engine.** Avoid two subtly different implementations.
- **Agent-ready, not AI-decorated.** Provide bounded commands, structured results and disposable VMs; do not embed a chat panel without a concrete workflow.
- **Safe defaults.** Read-only sharing where possible, explicit destructive actions, secrets-aware diagnostics and predictable storage ownership.
- **Conventional distribution.** Signed GitHub Releases remain the source of truth; Homebrew Cask provides the simplest supported installation path.

## Deliberate non-goals

- Competing with UTM on architectures, emulated hardware or iOS support
- Competing with Lima on containers, Kubernetes, SSH provisioning or networking stacks
- Building an image registry or CI service like Tart
- Hosting an LLM, selecting models, or sending VM content to an AI provider
- Adding plugin systems before the core lifecycle is tested and stable

## Agent-era opportunity

The smallest useful automation contract would support:

```text
easyvm list --json
easyvm inspect <name> --json
easyvm start <name> [--headless]
easyvm stop <name> [--timeout 30]
easyvm clone <source> <name>
easyvm delete <name> --confirm <name>
```

Later, the same service could expose a local socket or MCP server. Mutating actions should require explicit policy or confirmation, commands should return stable JSON and exit codes, and an agent should be able to operate on disposable clones without receiving unrestricted host access.

## Decision summary

The refresh should not begin with agent integration. It should begin by extracting a testable VM core, versioning the configuration schema, and making lifecycle behavior observable. Once those foundations exist, a thin CLI provides immediate value to humans, scripts, Shortcuts, CI experiments, and agents at the same time.
