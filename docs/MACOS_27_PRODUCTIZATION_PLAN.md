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
state. The creation review now previews the account identity, automatic login,
Remote Login, and temporary Keychain lifetime without rendering the password;
opting out explicitly states that macOS Setup Assistant remains manual. Each
Keychain payload now carries a stable attempt identifier and a
persisted `prepared`, `applying`, or `awaitingConfirmation` state. EZVM writes
`applying` before calling the framework, so a process interruption never causes
an ambiguous attempt to be submitted again automatically. On the next launch,
the user can verify the account and remove the credential or explicitly prepare
one retry for the following start. Known framework rejection returns the same
attempt to `prepared`. Legacy Keychain payloads migrate to `prepared` without
losing account fields. Automated policy tests prevent regression to deleting on
VM start or replaying an uncertain attempt. The signed macOS 27 first-boot,
interruption, and recovery matrix below is still required before this capability
leaves Beta.

Framework validation now maps invalid full-name, username, and password codes
to field-specific recovery text in both the wizard and startup path. Diagnostic
logs record only the error domain and numeric code, never the framework's raw
description, so a future beta error cannot accidentally echo credential data.

### Product outcome

A user can create a macOS 27 VM, choose whether to automate the initial account
setup, understand exactly what EZVM will configure, and recover safely if first
boot is interrupted.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Wizard | Keep provisioning behind an explicit choice; preview account identity, auto-login, SSH, and secret lifetime before Create. The macOS 27 API has no computer-name field, so EZVM must not imply that it controls one. | A new user can explain the result from the review page; opting out creates an ordinary Setup Assistant flow. |
| Secrets | Keep passwords in a ThisDeviceOnly Keychain item, never in the VM bundle, model JSON, logs, crash metadata, or export. Delete only after provisioning completion is confirmed—not merely after the VM starts. | Log/export scans contain no secret; interrupted first boot can retry; successful provisioning removes the temporary item. |
| State model | Persist the attempt identifier and `prepared / applying / awaiting confirmation` alongside the ThisDeviceOnly credential; represent unavailable, retry-prepared, completed, and failed states explicitly in runtime UI. | Only `prepared` is submitted. An interrupted or accepted attempt requires verification or an explicit next-start retry, so EZVM cannot silently report success or create duplicate accounts. |
| Feedback | Show first-boot status and an actionable failure card; explain when manual Setup Assistant is the safe fallback. | Permission denial, invalid account data, guest rejection, reboot, and timeout each produce a distinct next action. |
| Validation | Inspect the resulting guest for expected account, login, SSH, hostname, and absence of temporary credentials. | Signed-artifact tests pass for automated and manual provisioning, including cancel and retry. |

### Release blockers

- Treating VM start as proof that provisioning finished.
- Losing the only retry credential after a partially completed first boot.
- Writing any plaintext password to persistent app or guest metadata.

## 2. Accessory Access and USB passthrough

**Current implementation:** USB runtime state now keeps the approved device
list, attached registry IDs, per-device attach/detach operations, and a
non-blocking notice together. An operation failure therefore cannot erase an
attached device or incorrectly re-enable machine-state saving. Operation
tokens reject late callbacks after physical removal or teardown, explicit
detach is distinguished from an unexpected controller disconnect, and the UI
prevents duplicate actions while explaining recovery. Device discovery prefers
sanitized manufacturer and product names from the matching IORegistry entry,
keeps VID:PID visible for disambiguation, and deliberately never reads or logs
USB serial numbers. Physical-device,
permission-revocation, and sleep/wake testing below remains the promotion gate.
Framework failures are classified into inaccessible/accessory-state,
controller, already-attached, initialization, and not-found conditions with a
specific recovery action. A detach `DeviceNotFound` result now reconciles the
device as disconnected instead of leaving machine-state saving blocked by a
stale attachment.

### Product outcome

USB passthrough feels like connecting a device to a physical computer: devices
have recognizable names, connection state is truthful, unplugging is safe, and
permission problems explain how to recover.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Discovery | Keep sanitized manufacturer/product names with visible VID:PID disambiguation; distinguish claimable, claimed elsewhere, attached, and unavailable without collecting serial numbers. | Common storage, phone, security-key, and input devices are recognizable while unique device identifiers remain private. |
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

**Current implementation:** EZVM now preflights the complete network-device
collection before creating any VMNet object. Validation rejects unavailable
external interfaces, non-contiguous masks, host addresses used as subnets,
overlapping explicitly configured logical-network subnets, zero ports,
forwarding destinations outside the configured subnet, conflicting
definitions of one logical-network name, and duplicate external endpoints
across distinct networks. Identical reuse of a named logical network remains
valid. After structural validation succeeds, EZVM bind-probes each unique TCP
or UDP external endpoint on all host interfaces before creating any VMNet
object. It reports occupied and indeterminate endpoints separately, releases
every probe immediately, and skips matching named networks already owned by
this process. This removes partial network creation on predictable failures.
The probe is intentionally a preflight rather than a reservation, so VMNet
creation remains authoritative if another process claims the port afterward;
cross-process ownership and runtime interface/VPN transitions remain in the
real-system verification backlog below.

At runtime, every configured adapter now has an explicit preparing, connected,
reconnecting, or disconnected state. The framework disconnect callback is no
longer log-only: EZVM keeps failures independent for multi-adapter VMs, shows
the affected adapter and framework reason in the VM window, and offers a
bounded reattach of the original configuration. Reconnect attempts use
per-adapter operation identities so an old callback cannot clear a newer
failure, and VM teardown invalidates every pending attempt. The core tracker
also rejects a second reconnect for an adapter already in progress, so repeated
UI, automation, or future CLI events cannot replace the authoritative operation
identity; a failed attempt returns to a retryable disconnected state.

Disconnect UI no longer displays an unbounded framework string by itself. EZVM
adds a stable recovery action covering interface changes, VPNs, and host access,
then appends at most 160 sanitized characters of framework detail. Full raw
errors remain in the network log for support without allowing control characters
or oversized text to dominate the VM window.

### Product outcome

The default remains simple NAT. Advanced users can deliberately choose bridged,
host-only, or shared topology and understand reachability, security exposure,
and failure recovery without learning VMNet implementation details.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Presets | Present NAT, Bridged, Host-only, and Shared network as outcome-oriented cards; hide subnet, MTU, interface, and forwarding details until requested. | Default creation needs no networking knowledge; advanced review states host/guest/LAN reachability. |
| Preflight | Validate entitlement, external interface, subnet overlap, malformed masks, duplicate logical networks, occupied TCP/UDP host endpoints, and conflicting forwarding rules before VM start. | Structural failures perform no host-port probe; each unique valid endpoint is probed once before any VMNet object exists, and known conflicts fail synchronously with the conflicting value and recovery action. |
| Ownership | Centralize logical-network creation and serialization so GUI, CLI, and multiple EZVM processes recreate the intended topology safely. | Two VMs/processes can join the same logical network without duplicate ownership or stale objects. |
| Runtime recovery | Continue hardening Wi-Fi/Ethernet changes, VPN routes, sleep/wake, and interface removal around the implemented per-adapter disconnect/reconnect state. | UI already distinguishes preparing, connected, reconnecting, and failed without stale “Connected” state; signed-fixture runs must now prove recovery and clearly identify cases that require settings changes or restart. |
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

Layered ASIF restore now uses a typed transaction journal that records the
previous snapshot state and every newly created overlay. It audits the complete
snapshot and checks staging capacity before replacing machine files, then moves
through explicit `preparing`, `installing`, and `committed` phases. Startup
recovery preserves the VM's ASIF base images, restores only the non-disk files
and previous snapshot head that were part of the transaction, and removes only
the overlays created by the interrupted operation. Recovery also recognizes
older unjournaled layered-restore backups so upgrading does not expose an
existing VM to the generic whole-directory rollback path.

The restore path has deterministic injection coverage at eight durable
boundaries: journal creation, overlay recording, staging completion, backup
completion, install-journal persistence, file installation, state persistence,
and commit persistence. The matrix proves that every pre-commit interruption
restores the exact prior configuration, snapshot head, base image, and layer
set, while an interruption after the durable commit preserves the complete new
state and overlay. It also prevents post-commit cleanup failures from deleting
an overlay that the committed state already references.

The same eight-boundary matrix also runs the restore in a separate XCTest
process and terminates it immediately with `_exit`, then starts recovery in the
parent process. This proves the journal is sufficient without relying on stack
unwinding, in-memory cleanup, or the original process surviving. The production
module exposes only an internal checkpoint observer; process termination lives
entirely in the test target.

Capacity preflight now uses allocated bytes rather than a sparse image's logical
size and runs before the first mutation in RAW-to-ASIF conversion, snapshot
creation, and APFS or layered restore. Deterministic zero-capacity tests prove
that the source disk, active configuration, snapshot head, layer set, and
transaction directory remain unchanged. Aggregate allocation arithmetic also
saturates instead of trapping on pathological image collections.

Low-space runs on larger real ASIF images and a genuinely nearly-full volume, a
full host-restart exercise, and representative long-running performance
measurements remain promotion gates for moving the feature out of Beta.

The snapshot sheet now distinguishes working, successful, warning, and failed
outcomes with accessible system symbols and semantic colors. Diagnostic text
is no longer truncated and remains selectable. Rename and protection changes
now participate in the same mutation lock as create, restore, audit, and
delete. Protection metadata is written away from the main actor and reports a
clear completion result, preventing both UI stalls and concurrent snapshot-tree
changes.

Long-chain validation now creates and opens a real 32-layer ASIF history. Audit
does not stop at file signatures: it asks DiskImageKit to assemble each complete
stack read-only, which rejects reordered layers and broken parent relationships.
Branch restore and leaf deletion tests also prove that cleanup removes an
abandoned active head while retaining every layer referenced by another branch.
The snapshot UI reports the maximum active/saved depth and turns the depth
advisory orange at 32 layers. This is an EZVM maintenance threshold, not an
Apple framework limit.

VM startup now checks an existing layered chain before the normal idempotent disk
creation path. If the ASIF base is missing or damaged, EZVM refuses to create a
blank file at the same path and tells the user to restore the original base. A
valid ASIF from another chain is also rejected by DiskImageKit parent validation,
as is a missing active overlay. Tests prove all three failures preserve the base
path, remaining layers, and snapshot metadata for diagnosis and recovery.

The macOS 27 DiskImageKit SDK exposes image creation, opening, stacking, and
truncation, but no public merge, flatten, or compaction operation. EZVM therefore
does not present an unsafe in-place Compact action. A future consolidation
workflow must create a replacement image transactionally, verify it, preserve
the source until commit, and explicitly define how snapshot branches are
exported or retired.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Capacity | Keep allocated-byte plus safety-margin preflight before conversion, snapshot, and restore; extend the same temporary-peak model across clone and export. Do not reserve a sparse ASIF disk's entire logical size at creation. | Deterministic low-space tests prove failure before mutation and report required versus available space; a nearly-full real volume validates filesystem behavior. |
| Progress | Expose real byte/phase progress, cancellation boundaries, and “finishing safely” states for long operations. | Closing the UI does not abandon work; cancellation resolves to complete-or-absent output. |
| Integrity | Record base/layer identity, checksums where appropriate, current head, referenced branches, and saved-state compatibility. Validate the active chain before disk creation or VM startup. | Audit accounts for every layer and refuses missing, reordered, foreign, or corrupted chains; a missing base is never silently replaced. |
| Recovery | Use journaled transaction stages and startup recovery for every layer mutation. | Process kills at each commit point preserve the old head or atomically install the new one. |
| Maintenance | Add dry-run orphan cleanup and a transactional replacement-image consolidation workflow; retain protected snapshots, chain-depth warnings, and explicit export behavior. | Cleanup never removes referenced data; long chains have a measured, reversible maintenance path without claiming unsupported in-place compaction. |

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

Renderer and Custom Virtio device creation now share one recoverable factory
boundary. Failure to create a `VZCustomVirtioDeviceConfiguration` falls back to
Apple Virtio before constructing the virtual machine, rather than failing an
otherwise bootable Linux guest during configuration assembly.

Runtime presentation health is also surfaced without overreacting to transient
failures. Three consecutive renderer failures mark Custom VirGL as degraded in
the Graphics menu with recovery guidance; the next successful frame clears the
condition automatically while the VM continues running.

The legacy prototype scanout-evidence writer has been removed from the linked
runtime. VirGL diagnostics retain only bounded counters, dimensions, timings,
errors, and content-change signatures; they never persist guest pixels. The
normal user-visible thumbnail workflow remains separate and explicit.

Custom GPU reset now clears all guest-visible display state, including the
scanout rectangle, cursor position, and pending display event. Terminal stop
also releases the framework device reference, preventing late resize work from
crossing the device ownership boundary while preserving failed completion of
outstanding fenced queue elements.

## Shared UX work

The five journeys should feel like one product rather than five framework
demos:

- Shared folders use one stable runtime VirtioFS device per VM. A folder dropped
  on a running VM is persisted and published immediately through
  `VZVirtioFileSystemDevice.share`; macOS uses the system automount tag and Linux
  uses `ezvm_shared`. Removing a folder or changing read-only access in the
  running VM's Settings sheet updates the same live share.

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
