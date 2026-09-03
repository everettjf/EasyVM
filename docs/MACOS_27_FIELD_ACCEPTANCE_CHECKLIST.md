# EZVM macOS 27 field acceptance checklist

Use this checklist only with a Developer ID-signed EZVM 2.0.0 candidate built
from `codex/wwdc26-virtualization`. It covers the release evidence that cannot
be replaced by unit tests, unsigned builds, synthetic callbacks, or an idle VM.

Do not test with a keyboard, pointing device, dock, hub, system disk, security
key, phone containing irreplaceable data, or any accessory needed to control
the host. Use disposable VM clones and a sacrificial USB device. Stop a run
immediately if the host loses input, storage I/O reports corruption, or a VM
cannot be cleanly stopped.

## Evidence header

Record this once for every complete run:

- [ ] Date, tester, Mac model, macOS build, Xcode/SDK build
- [ ] Git commit, EZVM version, candidate ZIP SHA-256
- [ ] `codesign --verify --deep --strict` passes
- [ ] Production entitlement allowlist passes
- [ ] Notarization and stapling status are stated explicitly
- [ ] Guest fixture names and immutable fixture checksums are recorded outside
      the report; enrollment tokens and personal filesystem paths are not
- [ ] Result report and sanitized diagnostics are retained for every failure

## 1. Physical USB and `VZUSBController.Delegate`

Prerequisites:

- [ ] One disposable mass-storage device with nonessential test data
- [ ] One non-storage accessory known not to be required by macOS
- [ ] Optional second disposable accessory for ordering tests
- [ ] Omarchy, Ubuntu, and macOS disposable VM clones

For each supported guest:

- [ ] Start the VM and open USB. VoiceOver reads `USB accessories` plus a
      truthful state value.
- [ ] Choose the sacrificial device in Accessory Access. Cancel once and verify
      EZVM returns to a usable empty state without a retry loop.
- [ ] Choose it again, connect it, and verify the toolbar count becomes
      `USB (1)` only after controller attachment succeeds.
- [ ] Verify Save State and Stop is unavailable while attach/detach is pending
      and while a device is attached; the reason names USB rather than a generic
      configuration failure.
- [ ] Perform guest I/O, then disconnect through EZVM. The guest loses the
      device once, the toolbar count clears, and saving becomes available.
- [ ] Reconnect, perform guest I/O, and physically unplug. Exactly one
      non-blocking unexpected-disconnect notice appears; no stale Attached state
      or blocked Save action remains.
- [ ] Unplug while Connect is still pending. The pending operation resolves as
      interrupted and cannot later become Attached.
- [ ] With two disposable devices, attach and detach in both orders. Counts,
      per-device actions, and notices remain independent.
- [ ] Revoke or change Accessory Access approval. EZVM distinguishes denial,
      listener failure, ownership conflict, and physical disappearance.
- [ ] Repeat guest reboot, normal stop, force stop, host sleep/wake, app quit,
      and fast-user-switch/console-logout boundaries. No delegate callback acts
      on a released coordinator and no device remains claimed after teardown.

Retain a sanitized diagnostic bundle for every failure. Never retain USB serial
numbers in the checklist, logs, screenshots, or issue text.

## 2. Fresh macOS 27 provisioning

Prerequisites:

- [ ] A currently signed macOS 27-or-later restore image downloaded from Apple
- [ ] At least two disposable destination bundles: automatic and manual setup
- [ ] A generated test password that is not reused anywhere else

Automatic path:

- [ ] The creation review states full name, username, auto-login, Remote Login,
      and temporary Keychain lifetime without displaying the password.
- [ ] Create succeeds from an absent destination and produces exactly one VM.
- [ ] First boot reaches the requested account and desktop; login and Remote
      Login behavior match the review.
- [ ] Before confirmation, the ThisDeviceOnly credential remains recoverable
      and no plaintext password exists in the VM bundle, configuration, logs,
      diagnostics, process arguments, or environment.
- [ ] Confirm successful provisioning. Credential deletion succeeds and the UI
      leaves no pending or retry state.

Recovery paths:

- [ ] Cancel during `VZMacOSInstaller.install`; wait for the callback and verify
      complete rollback of the owned destination and temporary credential.
- [ ] Interrupt EZVM after the attempt is durably `applying`. Reopen it and
      verify that EZVM requests confirmation or an explicit retry—it must not
      silently resubmit or report success.
- [ ] Exercise invalid full name, username, and password. Each error points to
      the correct field without echoing secret text.
- [ ] Choose Setup Assistant fallback from a failed/pending attempt. The
      credential is removed only after destructive confirmation, automation is
      not submitted again, and manual setup remains possible.
- [ ] Move/rename a pending VM and verify its credential follows machine
      identity; clone with a new identity and verify the credential does not.
- [ ] Create with automatic provisioning disabled and complete ordinary Setup
      Assistant without an automation banner or retained credential.

## 3. VMNet host transitions

Use the signed Ubuntu ASIF fixture, VMNet Shared, a valid guest IPv4 address,
and authenticated Agent transfer as the success oracle. Do not toggle an
interface that is carrying an irreplaceable remote session.

- [ ] Establish guest IPv4, DNS, TLS, TCP forwarding, UDP forwarding, Agent
      byte round-trip, and same-logical-network two-VM communication.
- [ ] Toggle Wi-Fi off/on, switch Wi-Fi networks, and repeat Ethernet-to-Wi-Fi.
      The affected adapter leaves Connected, retries at most twice, stabilizes,
      and restores Agent/IPv4 success or presents one actionable manual retry.
- [ ] Enable and disable a representative VPN. Verify route/interface changes
      cannot leave a stale Connected label or an unbounded reconnect loop.
- [ ] Remove the configured external interface. The failure names the affected
      adapter and requires a settings change or retry as appropriate.
- [ ] Put the host to sleep during Connected, during retry backoff, and while VM
      startup is still preparing. On wake, only authoritatively disconnected
      adapters retry; stale pre-sleep completions cannot overwrite current state.
- [ ] Repeat a fresh EZVM process after every transition. Named-network leases
      are released after normal exit and process termination.
- [ ] Confirm the sanitized diagnostic export retains topology, subnet, MTU,
      interface and port-rule failure stages without VM names, paths, UUIDs,
      logical-network names, or unrelated host network data.

## 4. Interactive Custom VirGL A/B

Run Custom VirGL and Apple Virtio against COW clones of the same Omarchy image,
with identical CPU, memory, resolution, scale, compositor, and workload. Keep
the checked-in idle A/B as a regression baseline, not as interactive proof.

- [ ] Cold start to usable desktop is measured for both backends.
- [ ] Run browser scrolling, a WebGL scene, video playback, `glmark2`, workspace
      switching, cursor changes, keyboard layout changes, and text entry.
- [ ] Repeatedly resize through small, Retina, and 4K sizes; enter and leave full
      screen and move between Spaces. Guest geometry, cursor and input remain
      aligned with no stuck old scanout.
- [ ] Pause/resume, guest reboot, host sleep/wake, and renderer failure injection
      produce a clean recovery, a pre-boot Apple Virtio fallback, or one
      actionable stop—never a half-initialized display.
- [ ] Run a long soak and memory-pressure pass. Renderer and guest-backing
      reservations remain within their 2 GiB and 4 GiB aggregate budgets, frame
      queues remain bounded, and shutdown drains before renderer reuse.
- [ ] Capture CPU, RSS, frame cadence, drawable misses, presentation failures,
      average/P95/peak latency, and subjective defects for both backends.
- [ ] Promotion requires a measured benefit for the intended workloads and no
      unacceptable idle, input, stability, or memory regression. Otherwise keep
      Apple Virtio as the default and Custom VirGL visibly experimental.

## 5. Final Homebrew candidate

Only after the four sections above pass:

- [ ] Submit the exact ZIP for notarization and staple the accepted ticket
- [ ] Recreate the ZIP after stapling and update its SHA-256
- [ ] Install through the real Homebrew cask on a clean account
- [ ] Re-run signature, Gatekeeper, stapler, GUI readiness, three-guest matrix,
      USB smoke, VMNet transition, ASIF portability, and VirGL A/B gates
- [ ] Repeat the complete run without manual state repair
- [ ] Keep this branch unmerged until macOS 27 is formally released and the
      final SDK/build is substituted for the beta toolchain
