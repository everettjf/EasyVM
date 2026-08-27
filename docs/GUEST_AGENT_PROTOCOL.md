# EZVM Guest Agent Protocol v1

EZVM's Linux guest agent uses AF_VSOCK through Virtualization.framework's
Virtio Socket device. The fixed service port is `10240`. The transport never
requires privileged host networking.

## Trust and enrollment

Each VM receives an independent random 256-bit token. The host stores its copy
in Keychain; installation places the guest copy in a root-readable file. The
token is never stored in the EZVM bundle's `config.json`, included in
diagnostics, or logged. It is present in the separately exported enrollment
file and in the guest's root-only `/etc/ezvm-agent/config.json`.

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

Status responses advertise additive capabilities. `file-transfer-v1` enables the
transfer UI and `ssh-addresses-v1` enables validated `ssh://` links. A host that
connects to an older v1 agent receives no capability list and keeps these newer
actions hidden, while heartbeat and power operations continue to work.

Transfers are limited to 64 GiB and 512 KiB chunks. Both sides require absolute,
clean paths and reject symbolic links. Uploads use a mode-`0600` temporary file
in the destination directory, stream SHA-256 verification, synchronize data,
and rename atomically only after the size and checksum match. Downloads use the
same staging-and-verification rule on the host, so cancellation, disconnect, or
corruption does not replace an existing destination.

Host-to-guest mutations must originate from a visible user action. Future
versions must negotiate a new version instead of silently changing v1 fields or
authentication rules.

## Install in a Linux guest

EZVM ships a separate ARM64 Linux archive with each GitHub release. It is not
silently installed into a VM and does not need a privileged host entitlement.

1. Download and verify `EZVM-GuestAgent-<version>-linux-arm64.tar.gz` and its
   `.sha256` file from the same release as the app.
2. In EZVM, right-click the stopped Linux VM and select **Export Guest Agent
   Enrollment...**. This creates or retrieves that VM's token from Keychain and
   writes a mode-`0600` enrollment file.
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
