# EZVM Guest Agent Protocol v1

EZVM's Linux guest agent uses AF_VSOCK through Virtualization.framework's
Virtio Socket device. The fixed service port is `10240`. The transport never
requires privileged host networking.

## Trust and enrollment

Each VM receives an independent random 256-bit token. The host stores its copy
outside the VM bundle under the user's Application Support directory. The
enrollment directory is mode `0700` and each token file is mode `0600`, so
normal VM launches do not trigger an interactive Keychain prompt. Installation
places the guest copy in a root-readable file. The token is never stored in the
EZVM bundle's `config.json`, included in diagnostics, or logged. It is present
in the separately exported enrollment file and in the guest's root-only
`/etc/ezvm-agent/config.json`.

This storage choice preserves per-VM mutual authentication while allowing
unattended VM launches and release smoke tests. Treat the host account and its
Application Support data as part of the trust boundary; enrollment files must
never be synchronized, committed, or included in support bundles.

The guest starts authentication with a random nonce and an HMAC-SHA256 proof
bound to the protocol version and VM identity. The host rejects a mismatched VM,
unsupported version, malformed nonce, or proof, then returns its own nonce and
proof. This makes authentication mutual and prevents one VM from impersonating
another.

## Framing and messages

Every JSON frame has a four-byte, big-endian length prefix and is limited to 1
MiB. Authenticated envelopes contain a handshake-derived session ID, a
monotonically increasing sequence, request ID, operation, payload, and
HMAC-SHA256 proof. A receiver rejects messages from an earlier connection,
replayed or out-of-order sequences, and any modified field.

Protocol v1 operations are:

- `heartbeat`: liveness and boot identity
- `status`: agent version, OS/kernel/host name, IP addresses, boot ID, uptime
- `shutdown`: explicit authenticated power-off request
- `restart`: explicit authenticated reboot request
- `uploadStart`, `uploadChunk`, `uploadCommit`: bounded, checksum-verified host-to-guest transfer
- `downloadInfo`, `downloadChunk`: bounded, checksum-verified guest-to-host transfer
- `transferCancel`: explicit cleanup of either transfer direction
- `input`: bounded Linux `input_event` batches for the Custom VirGL display
- `ownerProvisioning`: one-shot delivery of validated Omarchy owner setup data
- `clipboardSet`, `clipboardGet`: bounded text or PNG transfer through the active desktop Session Agent
- `desktopNotifications`: bounded, read-only polling of sanitized Omarchy notification snapshots

Status responses advertise additive capabilities. `file-transfer-v1` enables the
transfer UI. `ssh-addresses-v1` enables validated `ssh://` links and is advertised
only while the Guest Agent observes a listening SSH socket; IP addresses remain
available as diagnostic status even when SSH is not running.
`input-uinput-v1` is advertised only when the agent successfully creates its
root-owned `/dev/uinput` device; EZVM then forwards keyboard, relative pointer,
button, and wheel events from the Custom VirGL display. The Apple graphics
backend continues to use Virtualization.framework's native USB input path.
`input-uinput-desktop-v1` means the agent has verified that the active desktop
compositor actually owns the EZVM input device. The host must not infer this
only from `hyprctl` or a compositor socket: stale runtime sockets can produce a
false positive or false negative after login/restart.
`shared-folders-v1` is advertised only while the agent can verify an active
VirtioFS mount whose tag is exactly `ezvm_shared` and whose guest mount point is
exactly `/mnt/ezvm-shared`. The existence of the host device or a guest mount
unit is not sufficient. Hosts should present shared-folder workflows as
degraded whenever this capability is absent and must not infer readiness from
the configured VM model alone.
`clipboard-text-v1` and `clipboard-image-v1` come from an unprivileged desktop
Session Agent rather than the root system service. The Session Agent requires
an active Wayland environment, a same-UID `spice-vdagent` process, and an
enabled SPICE clipboard configuration; PNG additionally requires the declared
`image/png` derived format. It registers over a local Unix socket, the system
Agent authenticates its UID with `SO_PEERCRED`, accepts only an allowlist of
capabilities, and expires the registration after 15 seconds. This channel does
not accept commands from either side.
`clipboard-agent-text-v1` and `clipboard-agent-image-v1` use the same
authenticated Session Agent boundary but move clipboard bytes through the
VirtioFS staging directory. The Session Agent verifies the exact byte count and
SHA-256 before publishing a selection and reads it back through Wayland before
reporting success. The macOS integration is independently disableable.
`desktop-notifications-v1` is advertised only when an active Wayland Session
Agent can verify the current user's Omarchy notification-state directory. The
read-only `desktopNotifications` operation accepts no action payload and returns
at most 20 current snapshots. The Session Agent accepts only owned, regular,
bounded snapshot files whose names match Omarchy's notification format; both
the Session Agent and root proxy sanitize and bound the ID, application, title,
body, urgency, and timestamp. Click commands, image paths, and other Omarchy
snapshot fields never cross the boundary. The macOS App establishes an initial
baseline instead of replaying old notifications, retries failed deliveries,
and only activates its own window when the user clicks a mirrored notification.
Mirroring is off by default, independently disableable, and requires macOS
notification authorization.
`input-uinput-absolute-v1` is advertised only when the agent also creates a
separate tablet-style `/dev/uinput` device. A capable host sends
`EV_ABS/ABS_X` and `EV_ABS/ABS_Y` in the inclusive range `0...32767`, followed
by `SYN_REPORT`, and routes pointer buttons to that tablet. This keeps the
macOS pointer coupled to the guest and removes pointer capture; older agents
continue to use the relative-input fallback.
A host that
connects to an older v1 agent receives no capability list and keeps these newer
actions hidden, while heartbeat and power operations continue to work.

`owner-provisioning-v1` is advertised only while Omarchy's provisioning marker
is a regular file. The authenticated `ownerProvisioning` operation accepts one
schema-v1 request containing username, password, keyboard layout, optional
identity fields, hostname, and timezone. The host validates password
confirmation locally and transmits the password once; confirmation is not a
wire field. The agent independently validates all bounds and formats, rejects
Omarchy's reserved system usernames, verifies the timezone resolves to a
regular file inside `/usr/share/zoneinfo`, and atomically stages a mode-`0600`
one-shot file at `/run/ezvm-owner-provisioning.json`. It never overwrites an
existing request and never logs the payload. A factory-image provisioning
consumer must remove the staged file after loading it and feed the values into
the same provisioning functions used by Omarchy's interactive first-boot form.
The capability disappears when provisioning finishes, so this operation is not
a general-purpose guest account management interface.

Transfers are limited to 64 GiB and 512 KiB chunks. Both sides require absolute,
clean paths and reject symbolic links. Uploads use a mode-`0600` temporary file
in the destination directory, stream SHA-256 verification, synchronize data,
and rename atomically only after the size and checksum match. Downloads use the
same staging-and-verification rule on the host, so cancellation, disconnect, or
corruption does not replace an existing destination.

Host-to-guest mutations must originate from a visible user action. Future
versions must negotiate a new version instead of silently changing v1 fields or
authentication rules.

Input payloads contain at most 64 events and must end in `EV_SYN/SYN_REPORT`.
The agent accepts only bounded `EV_KEY`, `EV_REL`, and negotiated `EV_ABS`
values used by its declared keyboard, relative-pointer, and absolute-pointer
devices; arbitrary uinput event types are rejected.
Events are accepted only inside the mutually authenticated, replay-protected
session. If `/dev/uinput` is unavailable, the capability is omitted and host
input messages are not sent.

## Install in a Linux guest

EZVM ships a separate ARM64 Linux archive with each GitHub release. It is not
silently installed into a VM and does not need a privileged host entitlement.

1. Download and verify `EZVM-GuestAgent-<version>-linux-arm64.tar.gz` and its
   `.sha256` file from the same release as the app.
2. In EZVM, right-click the stopped Linux VM and select **Export Guest Agent
   Enrollment...**. This creates or retrieves that VM's protected host-side
   token and writes a mode-`0600` enrollment file.
3. Copy the archive and enrollment file into that same VM. Extract the archive,
   rename the enrollment file to `config.json`, and place it beside `install.sh`.
4. Run `sudo ./install.sh`. The installer supports systemd and OpenRC, installs
   the configuration as root-readable mode `0600`, enables the service, and
   starts it.
5. Delete the copied enrollment file and any other unneeded copy. Restart the
   VM window if it was already running. EZVM's **Guest Agent** toolbar menu
   will show authentication, readiness, guest metadata, IP addresses, and the
   explicit shutdown/restart actions. Current agents also expose validated SSH
   links and explicit upload/download actions with progress and cancellation.

If the agent is absent or misconfigured, the VM continues to boot normally and
EZVM retries the connection. A connection that stops responding is discarded
and retried; it is not left displayed as ready.
