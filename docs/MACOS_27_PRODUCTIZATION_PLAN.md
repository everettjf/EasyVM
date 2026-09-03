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
state. The final action presents a destructive confirmation that names the
account, explains that the Keychain deletion is permanent, and defaults to
keeping the password so an accidental click cannot destroy the only recovery
credential. The creation review now previews the account identity, automatic login,
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

Provisioning verification and failure cards also provide a confirmed exit to
macOS Setup Assistant. Choosing it permanently removes the pending
ThisDeviceOnly Keychain credential and prevents another automatic submission;
the UI explains whether to continue in the running guest or reopen the VM. This
avoids trapping an invalid credential in a repeat-failure loop and does not
mislabel abandoning automation as successful account creation.

Provisioning credentials are now keyed by the SHA-256 identity of the VM's
`MachineIdentifier`, rather than by its absolute bundle path. Moving or
renaming a VM before first boot therefore retains its pending credential, while
a proper clone with a new machine identity cannot inherit the source password.
Existing path-keyed Keychain items are read, migrated opportunistically, and
removed by the normal confirmation cleanup path.

Framework validation now maps invalid full-name, username, and password codes
to field-specific recovery text in both the wizard and startup path. Diagnostic
logs record only the error domain and numeric code, never the framework's raw
description, so a future beta error cannot accidentally echo credential data.
The signed release-fixture path generates a unique password directly inside the
app, retains it only in the ThisDeviceOnly Keychain item, and enables auto-login
for that disposable fixture. A tester can therefore verify that the requested
account reached its desktop without putting the password in process arguments,
environment variables, terminal output, or test reports.
The host and guest requirements are checked independently. Provisioning needs a
macOS 27 host *and* a macOS 27-or-later restore image; older guests silently
ignore Apple's options. EZVM rejects a known older catalog entry immediately
and inspects latest, local, and direct-URL IPSWs before beginning installation.
The signed-artifact fixture exposed this requirement in practice: the cached
`macos-latest.ipsw` was macOS 26.6.2 (25G83), accepted the start options, and
still presented the manual account page exactly as Apple's SDK says an older
guest will. After the guard was added, the signed EZVM 2.0.0 build rejected that
same image before creating a destination bundle. A macOS 27 IPSW is still
required to complete the positive first-boot and interruption matrix.

The installation destination is now claimed atomically by the creation
transaction. A normal macOS or Linux creation refuses every pre-existing
destination, including an empty directory created between review and install;
rollback removes only a directory whose successful `mkdir` belongs to that
exact attempt. This closes the prior time-of-check/time-of-use window where a
failed installer could delete another process's newly created folder. It also
removes a legacy bug that treated `mkdir`'s success status as a file descriptor
and closed standard input. The separate preinstalled-image pipeline can reuse
its own staging directory only when its contents exactly match the declared
`Disk.img` whitelist, so the stricter user-destination rule does not weaken the
verified image workflow.

Automatic-provisioning credentials now join that same creation transaction at
the correct ownership boundary. EZVM first claims the new bundle and writes its
stable `MachineIdentifier`, then stores the ThisDeviceOnly Keychain item before
starting `VZMacOSInstaller`. A Keychain failure therefore aborts before the long
installation and rolls back only the newly owned bundle. If installation fails,
the credential is removed before filesystem rollback. If Keychain cleanup itself
fails, EZVM retains the identifier-bearing incomplete bundle and reports both
failures, rather than leaving an unreachable secret or presenting an installed
VM as a failed, unregistered result.

The creation guide exposes installation cancellation only after
`VZMacOSInstaller.install` has started, matching the framework's documented
boundary. Cancelling keeps the guide visible while the installer finishes its
callback, then rolls back the owned VM bundle and temporary Keychain credential;
the UI never claims cancellation is complete merely because it was requested.

Both failures that can occur after the attempt is durably marked `applying`
now use one checked recovery transition back to `prepared`: a framework start
failure and local `VZMacGuestProvisioningOptions` validation failure. A
Keychain write failure is no longer ignored. The runtime reports whether the
next start is a safe retry or whether the user must reopen the VM and inspect
the retained uncertain state, while diagnostic logs contain only error
identifiers and the recovery outcome.

### Product outcome

A user can create a macOS 27 VM, choose whether to automate the initial account
setup, understand exactly what EZVM will configure, and recover safely if first
boot is interrupted.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Wizard | Keep provisioning behind an explicit choice; preview account identity, auto-login, SSH, and secret lifetime before Create. The macOS 27 API has no computer-name field, so EZVM must not imply that it controls one. | A new user can explain the result from the review page; opting out creates an ordinary Setup Assistant flow. |
| Secrets | Keep passwords in a ThisDeviceOnly Keychain item, never in the VM bundle, model JSON, logs, crash metadata, or export. Delete only after provisioning completion is confirmed—not merely after the VM starts. | Log/export scans contain no secret; interrupted first boot can retry; successful provisioning removes the temporary item. |
| State model | Persist the attempt identifier and `prepared / applying / awaiting confirmation` alongside the ThisDeviceOnly credential; represent unavailable, retry-prepared, completed, and failed states explicitly in runtime UI. Claim the installation destination atomically and roll back only files owned by that attempt. | Only `prepared` is submitted. An interrupted or accepted attempt requires verification or an explicit next-start retry, so EZVM cannot silently report success or create duplicate accounts. Concurrent destination creation is rejected without deleting the other owner's files. |
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

The USB menu distinguishes permanent unavailability from a retryable discovery
failure. A build without the Accessory Access entitlement or a VM without a USB
controller explains the missing prerequisite without presenting a no-op “Try
Again” action; listener-registration failures retain an explicit retry.
Its toolbar label shows the number of attached accessories, and its icon/help
reflect discovery, connected, unavailable, and retryable-failure states, so the
user does not have to open the menu to learn whether USB needs attention.
VoiceOver receives the same state as an explicit value, including approved
accessory availability and connected count, without relying on the icon.
A Developer ID-signed GUI smoke run started the Omarchy fixture, reached an
authenticated Agent-ready state, exposed the USB control to VoiceOver, and
successfully invoked Accessory Access without an entitlement or listener-
registration error. The state moved from `Not configured` to `No approved
accessories connected`, then the guest shut down normally and the app exited.
The host returned no claimable accessory, so this proves the signed discovery
and empty-result path only; it does not satisfy attach, detach, or physical-
disconnect coverage.

Machine-state saving is now unavailable for the entire USB transition, not
only after an attachment has completed. This closes the interval in which an
asynchronous controller attach could finish while a save was starting. The USB
menu is also disabled once the VM enters pausing, saving, or stopping, and the
unavailability reason tells the user to wait for the current connection or
disconnection rather than incorrectly claiming a device is already attached.

After the initial system selection, users can reopen Accessory Access to choose
additional devices. Because Apple rejects registering the same listener twice,
EZVM unregisters and registers it again only when no device is attached and no
attach/detach operation is active. A generation token prevents an asynchronous
re-registration from reviving a coordinator after VM teardown; the menu asks
the user to disconnect attached devices before changing the approved set.

Accessory Access and `VZUSBController.Delegate` disconnect notifications now
pass through one idempotent reconciliation state machine. Whichever framework
reports first owns cleanup and any unexpected-disconnect notice; duplicate or
late callbacks clear stale operation tokens without producing a second notice.
Automated coverage includes explicit detach, physical-removal ordering, and a
device disappearing while attach is still pending.

The coordinator now retains a separate identity map for passthrough devices
whose asynchronous controller attach has not completed. A delegate disconnect
in that narrow window can therefore cancel the exact operation before its
success continuation runs; the device is never promoted into the attached set,
machine-state saving is unblocked, and the user sees that connection was
interrupted rather than a false Attached state. The later Accessory Access
signal or attach continuation is idempotent and cannot overwrite that result.

VM shutdown, force-stop, and saved-state entry now install a USB stop fence
before starting their framework operation. The fence rejects new user actions
and invalidates every in-flight operation token. If an asynchronous attach
still completes after that boundary, its continuation immediately detaches the
device instead of publishing a late Attached state into a stopping VM.

That fence is also reversible when the framework rejects pause, stop, force
stop, or saved-state work while the VM remains alive. EZVM no longer releases
its last `VZVirtualMachine` reference on a recoverable lifecycle error. It maps
the framework's authoritative state back to Running or Paused, retains the VM
window and run lease, shows a dismissible failure notice, and reconciles both
attached and pending devices against `VZUSBController.usbDevices` before
re-enabling USB actions. A late completion from the cancelled stop boundary is
therefore either reflected from controller truth or detached, never promoted
from stale UI state.

Saved-state completion follows Apple's actual lifecycle contract: a successful
`saveMachineStateTo` leaves the VM paused. EZVM commits the pending state file
atomically, then explicitly calls `VZVirtualMachine.stop`, and releases the VM
and run lease only after that stop succeeds. If it fails, the committed state
is rolled back because it would become stale as soon as the still-live guest
resumes or changes a runtime device. The paused VM remains controllable and the
user is asked to retry Save & Stop. A race that removes `canPause` before the
save begins also returns to framework truth instead of leaving a permanent
Saving/Stopping overlay.

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
- Fast user switching or console logout with two attached devices, followed by
  returning to the console session and explicitly reconnecting them.
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

The settings UI now starts with three outcome-oriented choices: ordinary NAT,
VMNet Shared, and VMNet Host-only. It explains host, guest, VM-to-VM, and
internet reachability before showing implementation details. Logical-network
name, subnet, MTU, external interface, and port forwarding remain in an
advanced disclosure; the saved adapter list shows both its outcome and the
effective configuration. NAT deliberately discards hidden VMNet-only fields,
and Host-only discards Shared-only interface and forwarding fields. Bridged
networking is not presented as a fourth choice. Apple documents it under the
same restricted `com.apple.vm.networking` entitlement, but EZVM has not built
or validated that distinct attachment path and does not claim it as part of
the current Homebrew product surface.

The signed release gate now runs the same VMNet Shared Ubuntu fixture through
two successive, independent EZVM processes. Both runs must authenticate the
Guest Agent, round-trip file bytes, and stop cleanly. This proves that app
teardown releases the reservation and a fresh process can recreate the same
topology without manual cleanup. Simultaneous sharing between independent app
processes is deliberately not claimed: the SDK serialization APIs transfer a
live XPC object, so that behavior would require a dedicated owner process and
an explicit lifecycle protocol.

Named logical networks now also have a kernel-backed cross-process ownership
lease. Lookup, ownership acquisition, and VMNet creation are serialized inside
each process; a second GUI or headless EZVM process therefore cannot silently
reserve a separate network with the same product-level name. Matching and
conflicting configurations receive distinct recovery guidance. The lease is
released normally with its process and automatically by the kernel after a
crash; a separate-process termination test proves that stale metadata cannot
strand the name. This is a safety boundary, not a claim of simultaneous
cross-process topology sharing: that remains dependent on an XPC coordinator
that transports Apple's live serialized network object.

The VMNet-only fixture must also report a syntactically valid guest IPv4
address. This proves that the configured adapter reached guest address
assignment instead of incorrectly treating VirtioSocket Agent traffic as
network-success evidence. DNS, TLS, VPN, and physical-interface transitions
remain separate real-environment gates.

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

Runtime reconnection no longer treats a non-`nil` replacement attachment as
immediate proof of restored connectivity. EZVM keeps the adapter in a recovering
state after Virtualization.framework accepts the request, observes a
stabilization window, and lets any late framework disconnect callback win. The
automatic retry budget resets only after that window succeeds, preventing a
flapping interface or VPN transition from creating an unbounded retry loop.

Disconnects while the host is awake now receive two bounded automatic recovery
attempts after one and three seconds. A stabilized reconnection, a manual retry,
or a new wake cycle renews that budget; sleep, teardown, and reconfiguration
cancel queued work so stale callbacks cannot overwrite the current state. Once
the bounded attempts are exhausted, the adapter remains visibly disconnected
with its sanitized error and explicit retry action instead of looping.
Sleep/wake recovery is generation-fenced: a second sleep, teardown, or newer
wake invalidates the previous delayed recovery pass. Sleep that begins while a
VM is still starting is retained by the tracker, and both manual and automatic
reconnect entry points refuse work until the host is awake.
The runtime enters its reconnecting state as soon as a retry is scheduled, so
the banner never claims the adapter is merely idle during the backoff window.

The long-running signed release hold treats sleep and host-network changes as
recoverable interruptions rather than immediate failures. It cannot pass at
the end of the hold until the authenticated Guest Agent is ready again; VMNet
gates additionally require the guest to report a valid IPv4 address after the
transition. The existing 15-second post-hold deadline bounds recovery instead
of allowing an indefinitely reconnecting release candidate to pass.

Disconnect UI no longer displays an unbounded framework string by itself. EZVM
adds a stable recovery action covering interface changes, VPNs, and host access,
then appends at most 160 sanitized characters of framework detail. Full raw
errors remain in the network log for support without allowing control characters
or oversized text to dominate the VM window.

Diagnostic export now transforms each machine configuration into a sanitized
summary instead of copying `config.json`. It removes machine and shared-folder
names, remarks, UUIDs, image and host paths, secret-like future fields, and
logical-network names while retaining VMNet mode, interface, subnet, MTU, and
port rules. Recent logs replace the home directory and registered VM bundle
paths before export, so a support file remains useful without disclosing the
user's filesystem layout.

### Product outcome

The default remains simple NAT. Advanced users can deliberately choose
host-only or shared topology and understand reachability, security exposure,
and failure recovery without learning VMNet implementation details.

### Work plan

| Area | Required refinement | Acceptance evidence |
| --- | --- | --- |
| Presets | Present NAT, Host-only, and Shared network as outcome-oriented cards; hide subnet, MTU, interface, and forwarding details until requested. Keep unimplemented Bridged networking out of the supported surface even though Apple documents it under the same restricted networking entitlement. | Default creation needs no networking knowledge; advanced review states host/guest/internet reachability, and hidden fields never leak into another mode. |
| Preflight | Validate entitlement, external interface, subnet overlap, malformed masks, duplicate logical networks, occupied TCP/UDP host endpoints, and conflicting forwarding rules before VM start. | Structural failures perform no host-port probe; each unique valid endpoint is probed once before any VMNet object exists, and known conflicts fail synchronously with the conflicting value and recovery action. |
| Ownership | Reuse one reserved logical network for matching adapters inside the app. A kernel-backed name lease prevents a simultaneous independent process from creating an accidental second topology, distinguishes matching from conflicting settings, and recovers automatically after process termination. Treat true simultaneous sharing as a separate XPC-broker feature: VMNet serialization transfers a live XPC object and is not a persistent network identifier. | Multiple VMs in one app reuse a matching network; an independent-process test proves the second owner fails clearly and can acquire immediately after the first process is terminated. A future broker must explicitly transport the live network object before simultaneous cross-process sharing can be claimed. |
| Runtime recovery | Continue hardening Wi-Fi/Ethernet changes, VPN routes, sleep/wake, and interface removal around the implemented per-adapter disconnect/reconnect state. Host sleep now cancels stale reconnect completions and moves the runtime out of “Connected”; wake retries only adapters with authoritative disconnect callbacks, including callbacks that arrive just after wake. | UI distinguishes preparing, connected, host sleeping, reconnecting, and failed without stale “Connected” state; signed-fixture runs must now prove recovery and clearly identify cases that require settings changes or restart. |
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

Startup recovery also fails closed when a restore journal exists but cannot be
decoded. It preserves the current machine, backup, staging directory, and the
damaged journal without moving any file. In particular, EZVM never infers an
ASIF branch from the backup configuration when the journal's previous
`activeDiskLayers` state is unavailable; guessing there could pair a restored
configuration with the wrong writable overlay while reporting success.

Capacity preflight now uses allocated bytes rather than a sparse image's logical
size and runs before the first mutation in RAW-to-ASIF conversion, snapshot
creation, and APFS or layered restore. Deterministic zero-capacity tests prove
that the source disk, active configuration, snapshot head, layer set, and
transaction directory remain unchanged. Aggregate allocation arithmetic also
saturates instead of trapping on pathological image collections.

Clone, export, and import now use the same allocated-byte plus safety-margin
model. Deterministic zero-capacity tests prove that all three fail before a
destination or partial staging directory is created, while their user-facing
errors report required and available space. Aggregate logical and allocated
byte totals saturate rather than overflowing on pathological bundles.

The signed-artifact matrix now treats portability as a real product journey,
not only a unit-test round trip. It exports an APFS-cloned ASIF fixture, starts
a separate application process to validate the exported manifest and payload,
restores the machine into a new bundle while preserving its identity, and then
boots and cleanly stops that imported guest. Temporary source, export, and
import bundles are removed after the gate, including on failure.

An isolated APFS disk-image gate now fills a disposable 1.1 GB volume with 800
MB of real data, then invokes the production snapshot path without a capacity
override. It proves the filesystem-reported capacity is honored before any
snapshot directory is created and that the source disk remains byte-identical.
Low-space runs on larger real ASIF images, a full host-restart exercise, and
representative long-running performance measurements remain promotion gates
for moving the feature out of Beta.

The snapshot sheet now distinguishes working, successful, warning, and failed
outcomes with accessible system symbols and semantic colors. Diagnostic text
is no longer truncated and remains selectable. Rename and protection changes
now participate in the same mutation lock as create, restore, audit, and
delete. Protection metadata is written away from the main actor and reports a
clear completion result, preventing both UI stalls and concurrent snapshot-tree
changes.

Long operations now keep their transaction context visible instead of allowing
the snapshot sheet to disappear while disk work continues. Creation, safety-
snapshot, restore-installation, audit, delete, rename, and protection phases use
truthful primary and secondary status text; restoring advances from preserving
the current state to installing the verified transaction. The Close action and
interactive dismissal remain disabled until the operation reaches a safe
terminal result. Creation and restore now expose real allocated-byte milestones
after each top-level machine item, while an integrity audit reports completed
snapshot count. They can be cancelled during preparation, verification, and
staging: partial output and restore journals are removed, and the running
machine bundle remains unchanged. Once the verified file swap begins, the UI
removes Cancel and explicitly reports “Finishing safely”; cancellation is not
accepted across that atomic commit boundary. Foundation does not expose
sub-file copy progress here, so a single very large disk can still advance in
one truthful jump rather than showing a synthetic percentage.

Restore now begins with a read-only storage review instead of a blind
destructive confirmation. EZVM audits the selected snapshot and calculates the
conservative allocated-byte peak for restore staging, the optional safety
snapshot, and the existing 1 GiB reserve. The review shows each component,
current available capacity, and whether Restore is allowed; it also explains
that APFS copy-on-write may consume less than the conservative safety-snapshot
estimate. Capacity and integrity are checked again in detached work immediately
before any safety snapshot or restore mutation, so a stale review cannot bypass
the transactional preflight. Insufficient space stops the journey before a
recovery snapshot is created.

Snapshot storage maintenance now starts with a read-only reference-map preview.
Cleanup is offered only when both the complete snapshot metadata index and the
active ASIF state decode successfully, no restore is pending, and an
unreferenced file belongs to EZVM's UUID-named layer namespace. Unknown files,
directories, symbolic links, referenced layers, and all candidates encountered
while metadata is damaged remain untouched. Confirmed cleanup atomically moves
candidates into a private quarantine and journals the commit: startup restores
them after a pre-commit interruption or finishes reclamation after a committed
interruption. The sheet shows candidate count, allocated bytes to reclaim, and
retained-item count before the destructive action.

Machine-state resume is now tied to the disk history it was saved against. A
successful save writes a companion compatibility manifest containing canonical
configuration and active-snapshot-state digests, hardware identity digests, and
the size and modification identity of every attached base image and active ASIF
layer. Startup validates that manifest before asking Virtualization.framework
to restore. A known mismatch or damaged manifest is discarded before restore,
the VM cold-boots, and an in-window notice explains whether configuration,
hardware identity, snapshot branch, or disk state diverged. States created
before manifests existed retain one guarded restore attempt and still fall back
to a cold boot if the framework rejects them. Clone and portable-export paths
remove both the state and its companion manifest together.

Long-chain validation now creates and opens a real 32-layer ASIF history. Audit
does not stop at file signatures: it asks DiskImageKit to assemble each complete
stack read-only, which rejects reordered layers and broken parent relationships.
Branch restore and leaf deletion tests also prove that cleanup removes an
abandoned active head while retaining every layer referenced by another branch.
The snapshot UI reports the maximum active/saved depth and turns the depth
advisory orange at 32 layers. This is an EZVM maintenance threshold, not an
Apple framework limit.

A separate 64 GiB sparse-ASIF gate opens the production writable stack, creates
and audits a layered snapshot, restores changed non-disk state, reopens the
restored stack, and verifies DiskImageKit still reports the exact 64 GiB logical
capacity. This exercises large-capacity arithmetic and stack metadata without
allocating 64 GiB of host storage; guest-written data pressure remains part of
the signed Ubuntu fixture rather than being inferred from sparse metadata.

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
| Capacity | Keep allocated-byte plus safety-margin preflight before conversion, snapshot, and restore; present a component-level restore estimate including an optional safety snapshot; extend the same temporary-peak model across clone and export. Do not reserve a sparse ASIF disk's entire logical size at creation. | Deterministic low-space tests prove failure before mutation and report staging, preservation, reserve, required, and available space; a nearly-full real volume validates filesystem behavior. |
| Progress | Expose real byte/phase progress, cancellation boundaries, and “finishing safely” states for long operations. | Closing the UI does not abandon work; cancellation resolves to complete-or-absent output. |
| Integrity | Record base/layer identity, checksums where appropriate, current head, referenced branches, and saved-state compatibility. Validate the active chain before disk creation or VM startup. | Audit accounts for every layer and refuses missing, reordered, foreign, or corrupted chains; a missing base is never silently replaced. |
| Recovery | Use journaled transaction stages and startup recovery for every layer mutation. | Process kills at each commit point preserve the old head or atomically install the new one. |
| Maintenance | Keep the implemented dry-run orphan preview and journaled quarantine cleanup; add a transactional replacement-image consolidation workflow while retaining protected snapshots, chain-depth warnings, and explicit export behavior. | Cleanup never removes referenced or unmanaged data and recovers across interruption; long chains have a measured, reversible maintenance path without claiming unsupported in-place compaction. |

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

The command dispatcher now verifies the fixed ABI size of all 21 supported
virtio-gpu commands before any handler reads guest bytes. Renderer contexts are
capped at 256 per device and host cursor materialization is capped at 256×256,
with explicit diagnostics for rejected counts and dimensions. Protocol tests
cover the full command-size table and both resource ceilings; physical guest
workload and long-soak validation remain release gates.

Renderer allocations now have a 2 GiB aggregate per-device safety budget in
addition to per-resource dimensions and counts. Buffers are charged by declared
bytes; textures are conservatively estimated using dimensions, array/depth,
mipmap, multisample, and worst-case texel size before virglrenderer is called.
Reservations roll back on renderer rejection and are released by resource
unreference, reset, and stop. This prevents a guest from exhausting the host by
creating many resources that are each individually legal.

Guest memory mappings used as resource backing have a separate 4 GiB aggregate
per-device budget in addition to the 1 GiB per-resource limit. Reservations are
made before attaching mappings to virglrenderer and are released on detach,
resource unreference, reset, and stop. Runtime shutdown installs a terminal
device fence, drains the custom-device delegate queue, and only then releases
the process-global renderer lease, so a late framework callback cannot enter a
renderer already reused by another VM. Pause invalidates the current scanout
and stops the display clock; monotonically sequenced presentation events prevent
a delayed invalidation from blanking a newer frame. Presentation coordinates
are converted exactly and rejected before an invalid signed value can trap or
wrap at the C boundary.

Three-dimensional transfers now retain and validate resource mip metadata at
the Swift boundary. Empty, overflowing, unavailable-mip, and out-of-mip X/Y
regions are rejected before entering the C renderer, while Gallium continues to
own target-specific cube/array layer validation. Protocol tests exercise full
and reduced mip edges plus coordinate-overflow cases.

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

## Adopted API completion

`VZVirtualMachineConfiguration.label` is applied at all four configuration
assembly boundaries: macOS creation, macOS run, Linux creation, and Linux run.
Names are normalized for system services, blank labels are omitted, and the
result is capped at Apple's 64 UTF-16-code-unit limit without splitting a Swift
grapheme cluster. Import and portability tests use the same normalization, so a
moved or imported machine does not silently diverge from a newly created one.

`VZUSBController.Delegate` is installed only after Accessory Access listener
registration succeeds and is cleared during teardown. Controller disconnects
are reconciled by object identity against both attached and still-pending
passthrough devices. Automated coverage exercises explicit detach, unexpected
disconnect, duplicate Accessory Access/controller callback orderings, disconnect
during attach, console-logout batches, and the stop fence. Physical-device tests
remain mandatory because no synthetic unit test can make the framework claim,
detach, or revoke a real USB accessory.

## Execution order

The remaining hardware- and host-transition work is specified as a repeatable
field runbook in [MACOS_27_FIELD_ACCEPTANCE_CHECKLIST.md](MACOS_27_FIELD_ACCEPTANCE_CHECKLIST.md).
It defines safety exclusions, exact expected states, stop conditions, and
evidence retention for physical USB, fresh provisioning, VMNet transitions,
interactive VirGL A/B, and the final notarized Homebrew candidate.

### Latest signed-artifact evidence

On September 3, 2026, commit `0b848f5` was rebuilt as EZVM 2.0.0 through the
Developer ID archive/export path after the login keychain identity became
available again. The production entitlement allowlist contained
Virtualization, VMNet, and Accessory Access; the app, CLI helper, and all four
bundled VirGL libraries shared TeamIdentifier `YPV49M8592`. The generated ZIP
passed its SHA-256 check, survived an extract-and-verify round trip, and its
extracted app passed strict deep-signature verification, Gatekeeper assessment,
CLI doctor JSON parsing, version validation, entitlement validation, Launch
Services startup, and the visible/responsive SwiftUI-window readiness gate.
The same checkout also passed the disposable real-APFS low-space rejection
gate before mutation and the 64 GiB sparse-ASIF snapshot, audit, restore,
reopen, and logical-capacity-preservation gate.
That exact candidate then passed the 390-second signed guest matrix against
macOS 27, Omarchy, and Ubuntu. The versioned mode-`0600` report recorded CLI
JSON, concurrent VMs, SIGKILL restart, EFI recovery, macOS saved-state
cross-process restore, authenticated Agent transfer, VirGL on both Linux
guests, Ubuntu ASIF, VMNet Shared guest IPv4 and fresh-process reacquisition,
ASIF cross-process snapshot restore, and ASIF export/validate/import/boot. The
candidate still does not have a notarization ticket stapled to it, and no
claimable physical USB accessory was present. Fresh macOS provisioning,
physical USB, host sleep/network transitions, and representative VirGL A/B
workloads therefore remain separate real-environment gates.
Two additional signed Omarchy idle A/B runs (30 and 60 seconds) passed the
checked-in VirGL cadence, presentation-latency, CPU-delta, and memory-delta
budgets with no drawable misses or presentation failures. They establish a
repeatable idle regression baseline but deliberately do not close the
interactive-workload gate.

On September 2, 2026, commit `929dd38` was built as EZVM 2.0.0 through the
Developer ID archive/export path. The app, CLI helper, and bundled VirGL
libraries shared TeamIdentifier `YPV49M8592`; Gatekeeper accepted the app and
the production entitlement allowlist contained Virtualization, VMNet, and
Accessory Access.

`verify-macos27-guest-matrix.sh` then passed against the frozen macOS 27,
Omarchy, and Ubuntu fixtures. Evidence included CLI JSON and concurrent-VM
operations, SIGKILL restart and saved-state fallback, EFI recovery, macOS
cross-process saved-state restore, VirGL and Guest Agent operation on both
Linux guests, VMNet Shared transfer and fresh-process reacquisition, and ASIF
snapshot creation, cross-process audit, restore, reboot, and clean stop.

The next signed matrix additionally performs the isolated real-volume low-space
gate plus ASIF export, validation in an independent app process, restore import
with machine-identity preservation, and an imported-guest boot and clean stop.
These gates are implemented but must be
rerun once the Developer ID identity is visible in the unlocked login keychain.
The same path passed on September 2 using a disposable virtualization-only
ad-hoc test signature, proving the application behavior independently of that
remaining release-signing gate.

Release runs can set an absolute `EZVM_MATRIX_REPORT` path to atomically retain
a versioned JSON result containing duration, executable SHA-256, guest set, and
the exact automated checks that passed. The report is written mode `0600` and
contains no fixture or user paths. This makes repeated notarized/Homebrew runs
comparable without treating terminal scrollback as release evidence.

This is signed development evidence, not release promotion. Physical USB,
fresh macOS provisioning, real host sleep/network transitions, representative
VirGL A/B workloads, notarization, and Homebrew installation remain required.
The release build environment variable is `EZVM_SIGNING_IDENTITY`; similarly
named legacy variables do not select the Developer ID archive/export path.
The build now rejects the obsolete `EASYVM_SIGNING_IDENTITY` spelling before
creating an output directory, preventing a release operator from silently
producing an ad-hoc archive.

After that signed matrix, the five core paths received an additional
code-level lifecycle pass through commit `8bc3ade`. The complete Swift suite,
the 26-test Custom VirGL package suite, and an unsigned macOS 27 Release build
pass at that revision. This is regression evidence for transaction, ordering,
and resource-boundary behavior; it does not replace the real-hardware gates
listed above.

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
