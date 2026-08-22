# EasyVM Guest Agent Protocol v1

EasyVM's Linux guest agent uses AF_VSOCK through Virtualization.framework's
Virtio Socket device. The fixed service port is `10240`. The transport never
requires privileged host networking.

## Trust and enrollment

Each VM receives an independent random 256-bit token. The host stores its copy
in Keychain; installation places the guest copy in a root-readable file. The
token is never stored in `config.json`, included in diagnostics, or logged.

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

Host-to-guest mutations must originate from a visible user action. Future
versions must negotiate a new version instead of silently changing v1 fields or
authentication rules.
