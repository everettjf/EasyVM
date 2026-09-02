# EZVM macOS 27 productization plan

_Baseline: EZVM 2.0.0 development branch — September 2, 2026_

EZVM is no longer optimizing for the number of Virtualization.framework APIs
it uses. The next release line optimizes five complete user journeys: they must
be reliable, understandable, recoverable, and polished in the signed Homebrew
artifact. A new Apple API is adopted only when it removes a real limitation or
materially improves one of these journeys.

## Product standard

Every core journey must meet the same release bar:

1. **Clear before starting:** prerequisites, permissions, downloads, disk-space
   impact, and restart requirements are visible before a long operation.
2. **Truthful while running:** progress and state come from the underlying
   operation; submitting a request is never presented as completion.
3. **Recoverable after failure:** interruption, cancellation, host sleep,
   process termination, and low disk space lead to either a complete result or
   an explainable recoverable state.
4. **Secure by default:** secrets are short-lived, logs are redacted, external
   interfaces are opt-in, and guest-provided input is bounded and validated.
5. **Diagnosable:** a user-facing error explains the next action while the
   diagnostic bundle records the failing stage, framework error, app version,
   host build, and sanitized configuration.
6. **Verified as shipped:** unit tests and unsigned Xcode builds are necessary,
   but promotion requires the notarized, Homebrew-installed app and a real VM.

## 1. macOS guest provisioning

**Current implementation:** EZVM now retains the ThisDeviceOnly Keychain
credential after `VZVirtualMachine.start` succeeds because the framework does
not expose a guest-provisioning completion callback. The VM window reports
that setup is being applied and asks the user to confirm only after they can
sign in; credential deletion is explicit, fallible, and reflected in runtime
state. Automated policy tests prevent a future regression to deleting on VM
start. The signed macOS 27 first-boot, interruption, and recovery matrix below
is still required before this capability leaves Beta.

### Product outcome

A user can create a macOS 27 VM, choose whether to automate the initial account
setup, understand exactly what EZVM will configure, and recover safely if first
boot is interrupted.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Wizard | Put provisioning behind an explicit choice; preview account name, computer name, auto-login, SSH, and secret lifetime before Create. | A new user can explain the result from the review page; opting out creates an ordinary Setup Assistant flow. |
| Secrets | Keep passwords in a ThisDeviceOnly Keychain item, never in the VM bundle, model JSON, logs, crash metadata, or export. Delete only after provisioning completion is confirmed—not merely after the VM starts. | Log/export scans contain no secret; interrupted first boot can retry; successful provisioning removes the temporary item. |
| State model | Persist `not requested / prepared / applying / verified / failed` with an attempt identifier and idempotent retry rules. | Killing EZVM at every transition cannot silently report success or create duplicate accounts. |
| Feedback | Show first-boot status and an actionable failure card; explain when manual Setup Assistant is the safe fallback. | Permission denial, invalid account data, guest rejection, reboot, and timeout each produce a distinct next action. |
| Validation | Inspect the resulting guest for expected account, login, SSH, hostname, and absence of temporary credentials. | Signed-artifact tests pass for automated and manual provisioning, including cancel and retry. |

### Release blockers

- Treating VM start as proof that provisioning finished.
- Losing the only retry credential after a partially completed first boot.
- Writing any plaintext password to persistent app or guest metadata.

## 2. Accessory Access and USB passthrough

### Product outcome

USB passthrough feels like connecting a device to a physical computer: devices
have recognizable names, connection state is truthful, unplugging is safe, and
permission problems explain how to recover.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Discovery | Prefer manufacturer/product/serial descriptions, with VID:PID only as a fallback; distinguish claimable, claimed elsewhere, attached, and unavailable. | Common storage, phone, security-key, and input devices are recognizable without reading hexadecimal IDs. |
| Lifecycle | Keep `VZUSBController.Delegate` as the authoritative guest-side disconnect signal; reconcile it with Accessory Access connect/disconnect events and clear delegates on teardown. | Sudden physical unplug removes the attached state once, never leaves Save/Stop blocked, and never calls a released coordinator. |
| Interaction | Use one explicit Connect/Disconnect action per device, show progress, and surface unexpected unplug as a non-blocking notice. | Double-clicks, simultaneous events, and detach failure cannot produce contradictory controls. |
| Permissions | Detect missing entitlement, denied selection, revoked access, and device ownership conflicts separately. | Each condition names the exact recovery action without sending users through unrelated settings. |
| Safety | Define stop, force-stop, save-state, sleep/wake, and app-quit behavior while devices are attached. | No attached device or listener survives VM teardown; save-state constraints are explained before the operation. |

### Real-hardware matrix

- USB mass storage with active guest I/O and sudden unplug.
- A non-storage accessory and a device rejected by the framework.
- Two devices attached and detached in both orders.
- Permission denial/revocation, host sleep/wake, guest reboot, VM stop, and app
  force-quit.
- Ubuntu, Omarchy, and macOS guests where the device class is supported.

## 3. VMNet advanced networking

### Product outcome

The default remains simple NAT. Advanced users can deliberately choose bridged,
host-only, or shared topology and understand reachability, security exposure,
and failure recovery without learning VMNet implementation details.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Presets | Present NAT, Bridged, Host-only, and Shared network as outcome-oriented cards; hide subnet, MTU, interface, and forwarding details until requested. | Default creation needs no networking knowledge; advanced review states host/guest/LAN reachability. |
| Preflight | Validate entitlement, external interface, subnet overlap, malformed masks, duplicate logical networks, privileged or occupied ports, and conflicting forwarding rules before VM start. | Known conflicts fail synchronously with the conflicting value and recovery action. |
| Ownership | Centralize logical-network creation and serialization so GUI, CLI, and multiple EZVM processes recreate the intended topology safely. | Two VMs/processes can join the same logical network without duplicate ownership or stale objects. |
| Runtime recovery | Model Wi-Fi/Ethernet changes, VPN routes, sleep/wake, interface removal, and framework disconnect callbacks. | UI distinguishes reconnecting from failed; restart requirements are explicit; no stale “Connected” state remains. |
| Diagnostics | Provide sanitized topology, interface identity, port rules, and failing VMNet stage without exposing unrelated host network data. | A diagnostic bundle can distinguish entitlement, configuration, port, interface, and runtime failures. |

### Verification matrix

Test TCP and UDP forwarding, two-VM communication, host-only isolation,
bridged DHCP, DNS/TLS, interface switching, VPN on/off, sleep/wake, collision,
and app restart using the final signed Homebrew build.

## 4. DiskImageKit, ASIF, and snapshots

### Product outcome

ASIF provides fast, space-efficient storage without making users understand
overlay internals. Snapshot, restore, conversion, clone, export, and cleanup
remain transactional and explain their disk-space consequences.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Capacity | Calculate logical size, allocated size, temporary peak, and safety margin before conversion, snapshot, restore, clone, and export. | Low-space failure occurs before mutation and reports required versus available space. |
| Progress | Expose real byte/phase progress, cancellation boundaries, and “finishing safely” states for long operations. | Closing the UI does not abandon work; cancellation resolves to complete-or-absent output. |
| Integrity | Record base/layer identity, checksums where appropriate, current head, referenced branches, and saved-state compatibility. | Audit accounts for every layer and refuses missing, reordered, foreign, or corrupted chains. |
| Recovery | Use journaled transaction stages and startup recovery for every layer mutation. | Process kills at each commit point preserve the old head or atomically install the new one. |
| Maintenance | Add dry-run orphan cleanup, protected snapshots, chain-depth warnings, compaction/flattening policy, and export behavior. | Cleanup never removes referenced data; long chains have a measured, reversible maintenance path. |

### Stress matrix

Cover large sparse disks, nearly full hosts, long and branched chains, missing
bases, damaged headers, process termination, host restart, saved-state
divergence, legacy RAW migration, cloning, and import/export round trips.

## 5. Custom Virtio GPU and VirGL

### Product outcome

Supported Linux guests receive visibly better graphics with deterministic
fallback. Experimental acceleration must never make an otherwise bootable VM
unusable or weaken EZVM's input/security boundary.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Compatibility | Maintain tested distro/compositor/driver profiles and select Custom GPU only when host, guest, renderer, and saved-state constraints agree. | Unsupported combinations automatically use Apple Virtio and explain why in diagnostics, not in alarming UI. |
| Protocol safety | Bound feature negotiation, resource sizes, command counts, mappings, fences, and malformed guest requests; fuzz parsers and state transitions. | Hostile sequences cannot crash the app, overflow allocations, or retain unbounded resources. |
| Renderer lifecycle | Isolate and classify VirGL/ANGLE/Metal initialization and device-loss failures; make fallback deterministic before guest boot. | Renderer failure produces one clean fallback or one actionable stop—never a partially initialized VM. |
| Display UX | Polish dynamic resize, Retina scaling, full screen, multi-space transitions, cursor ownership, keyboard layout, and input reconnect. | Repeated resize/full-screen/sleep cycles have no stuck mode, missing input, or unbounded frame queue. |
| Performance | Define cold-start, frame-time, resize latency, host CPU, memory, and GPU budgets against Apple Virtio. | Promotion requires measurable gain on representative desktop and GL workloads without unacceptable idle cost. |
| Observability | Record negotiated features, renderer/backend versions, fallback reason, device-loss stage, and bounded performance counters. | Support can identify guest incompatibility without collecting guest screen or input content. |

### Verification matrix

Run Ubuntu and Omarchy across Wayland/X11 where supported, desktop idle,
video, browser/WebGL, `glmark2`, 4K resize, full screen, host sleep/wake, guest
reboot, long soak, memory pressure, malformed-command fuzzing, renderer failure,
and Apple Virtio fallback.

## Shared UX work

The five journeys should feel like one product rather than five framework
demos:

- Use the same `Ready / Needs attention / Working / Restart required /
  Unavailable` vocabulary and visual treatment.
- Put permission and compatibility explanations at the action that needs them.
- Keep safe defaults visible and advanced framework terms behind disclosure.
- Provide one review screen before expensive or externally visible mutation.
- Preserve progress across window navigation and make cancellation semantics
  explicit.
- Meet keyboard navigation, VoiceOver, contrast, reduced-motion, localization,
  and Dynamic Type expectations.
- Use user-facing language for recovery and retain technical details only in a
  copyable diagnostic view.

## Execution order

### Gate 0 — Establish release evidence

- Freeze three primary guest fixtures: macOS 27, Ubuntu, and Omarchy.
- Define signed Homebrew scenario scripts, hardware inventory, performance
  budgets, diagnostic schema, and failure-injection points.
- Record the current success rate, duration, disk usage, memory, and known
  failure signatures for all five journeys.

### Gate 1 — Lifecycle correctness

- Finish provisioning completion/retry semantics and secret deletion timing.
- Finish USB disconnect/teardown reconciliation and hardware tests.
- Add VMNet ownership, preflight, and host-network transition recovery.
- Add ASIF transaction fault injection and integrity audit coverage.
- Complete Custom GPU protocol bounds, renderer failure, and fallback tests.

No visual-polish-only work promotes a feature past this gate.

### Gate 2 — Understandable workflows

- Apply common readiness states and recovery messages.
- Add preflight/review screens, durable progress, and contextual permissions.
- Remove contradictory controls and implementation jargon.
- Complete keyboard, VoiceOver, localization, and reduced-motion review.

### Gate 3 — Real-world soak

- Run clean create/start/use/stop and upgrade/migration scenarios.
- Run sleep/wake, guest reboot, app restart, force-quit, network transition,
  low-space, and multi-VM scenarios.
- Run physical USB and representative GPU workloads on the hardware matrix.
- Require repeated notarized Homebrew runs with no manual state repair.

### Gate 4 — Release candidate

- Every feature has an owner, support statement, recovery documentation,
  diagnostic coverage, and a passing signed-artifact matrix.
- Beta/experimental labels reflect evidence, not schedule pressure.
- Any failing path falls back safely or is visibly unavailable before mutation.

## API adoption rule

After the `VZVirtualMachineConfiguration.label` and
`VZUSBController.Delegate` work, a new API enters the roadmap only when all of
the following are documented:

1. the user problem it solves;
2. why existing behavior is insufficient;
3. measurable expected benefit;
4. security, privacy, compatibility, and migration impact;
5. fallback and recovery behavior;
6. automated coverage and a signed-artifact real-world test.

If those answers are weak, the API is not backlog. Time goes to reliability,
clarity, performance, and refinement of the five journeys above.
