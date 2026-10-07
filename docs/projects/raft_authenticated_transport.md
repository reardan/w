# Authenticated remote Raft transport

`libs/standard/distributed/raft_tls.w` carries the frozen Raft wire codec over
TLS 1.3. Use it for remote peers; `raft_tcp.w` remains a plaintext loopback test
transport. The TLS implementation is the existing `libs/standard/net/tls.w`
(X25519, ChaCha20-Poly1305, ECDSA P-256 server certificates).

The client validates the server certificate chain, expiration and the exact
hostname configured for the destination node ID. There is no skip-verification
setting in the Raft API. Inside the encrypted connection, the client supplies
its node ID, destination ID, a 32-byte cluster namespace, and a 32-byte pairwise
credential. The server checks all of these before acknowledging authentication
or decoding a Raft message. Every received message must name the authenticated
source and local destination; every send must name the local source and the
configured peer destination. This is server-certificate TLS plus encrypted
client credentials, **not mutual certificate TLS**.

A provisioned credential alone grants no Raft authority. The source/destination
must also be in the node's live replication peer set, including learners.
Membership version changes invalidate sessions, even if a removed ID is later
added again. Credential replacement invalidates existing sessions as well.
Checks occur before I/O and after suspension, before delivering a message.
Messages already returned to the owner still require the Raft core's ordinary
membership checks when processing them.

## Provisioning

1. Create a dedicated cluster CA, and issue each node its own ECDSA P-256 server
   key and certificate. Give the certificate a DNS SAN equal to that node's
   configured hostname, `serverAuth` EKU, and `digitalSignature` key usage. The
   PEM chain is leaf first. Distribute the CA bundle through your trusted
   deployment system; this transport never downloads or discovers trust roots.
2. Generate a unique 32-byte cluster namespace and distribute it to all nodes.
   Generate a distinct cryptographically random 32-byte secret for **each pair**
   of nodes; distribute that secret only to those two nodes. Use your existing
   secret manager or `random_bytes` from `libs.standard.crypto.random`. Supply
   raw bytes, not a password or a textual hex string. Protect the server key and
   credential files with service-account-only permissions. Never reuse the
   checked-in test credentials in a deployment.
3. Bootstrap a trusted Raft member configuration. Set up a `raft_tls_config`
   bound to that live `raft*`, then configure each peer's ID, expected hostname,
   and pairwise credential. Preprovisioning a future learner's credential is
   safe: it does not authorize a connection until membership admits that ID.

`raft_tls_config_new(node, cluster32, ca_path, chain_path, key_path,
timeout_ms, max_sessions)` copies the supplied bytes/paths. Limits are a
positive operation timeout up to 60 seconds and a positive session cap up to
64. `raft_tls_set_peer(config, id, hostname, current32, previous32_or_null)`
copies and wipes replaced secrets; at most 64 credentials can be configured.
Configs belong to one scheduler/thread and outlive all their sessions.

## Connecting and dispatching

Run transport operations inside `lib/task` workers. Establish a TCP connection
with `net_connect_timeout(remote_ip, remote_port, timeout_ms)` and pass the
connected descriptor to `raft_tls_connect(config, fd, expected_peer_id)`.
On the listener, pass accepted descriptors to `raft_tls_accept(config, fd)`.
Both functions take ownership of the descriptor on every return path. They
return an authenticated session or null; `config.last_error` provides the
client handshake's static diagnostic without exposing credentials.

The listener can bind any explicitly configured IPv4 address using `lib/net`.
Keep its kernel backlog and number of scheduled accept workers bounded. The
transport reserves its session slot **before** doing a TLS handshake, and
counts handshakes against `max_sessions`. A listener should stop spawning
workers when that cap is reached, rather than accumulating descriptors in an
external work queue.

`raft_tls_send(session, message)` encodes immediately, returns 1 on success,
and leaves message ownership with the caller. `raft_tls_recv(session)` returns
a caller-owned `raft_msg*` or null. Pass only successfully returned messages to
`raft_on_msg`, then free them using `raft_msg_free`. Serialize operations on a
session; a busy flag rejects overlapping calls, because the TLS state and Raft
framing are not concurrently duplex-safe. For independent send/receive workers,
use separate authenticated connections, as the loopback transport does.

Each call has a whole-operation monotonic deadline, including handshake plus
credential exchange. Nonblocking sockets park only the current task. Optional
absolute deadlines in the shared TLS raw I/O also stop continuously readable
hostile traffic, which would not otherwise hit a task's readiness wait. A
partial write, truncated frame, or failed receive poisons the stream. Close it
with `raft_tls_close`, then reconnect and let Raft retransmission retry complete
messages. Do not close a session while another task is using it; cancel/join
that task first. Close is immediate, wipes TLS secrets and frees the session;
it does not wait for a TLS close-notify exchange.

There are no transport inbox/outbox queues. Frames are limited to 1 MiB and
allocated only after validating the length. TLS bounds records and handshake
reassembly separately (16 KiB plaintext records, 64 KiB handshake messages).
Snapshot chunks fit within the frame budget. Owners must bound their own
message queues and apply backpressure. Reconnects are explicit, so a failed
peer cannot create an internal retry storm.

## Rotation and revocation

For pairwise credential rotation, provision the new secret at both ends and
call `raft_tls_set_peer` with `current=new, previous=old`. Existing sessions
become unusable on their next operation and reconnects authenticate using the
new current secret; receivers accept either during the overlap. After both
nodes have switched, set `previous=null`. An old credential then fails on a
fresh connection. Replacing a credential during a client handshake also forces
that attempt to reconnect. Old credential buffers are wiped before freeing.

For server certificate/key or CA rotation, drain and close sessions, replace
the credential files/configs, and reconnect. A CA rollover can use a bundle
containing both roots during the transition, then remove the old root and
recreate configs after draining sessions. Removing a trust root does not
retroactively revalidate an existing TLS session; explicitly draining is part
of certificate revocation. There is no OCSP/CRL fetching or automatic secret
reload. Membership removal independently blocks both new connections and
subsequent operations on existing ones.

## Reproducible integration coverage

`./wbuild raft_tls_test raft_tls_64_test` runs an ephemeral TCP listener and
client with real CA and hostname verification. The tests cover exchange and
reconnect, wrong credentials, wrong hostnames, untrusted/expired certificates,
wrong cluster/destination, a credential belonging to an unauthorized node,
forged Raft source IDs, oversized frames, rotation overlap and old-key refusal,
rotation during a handshake, membership revocation/version changes, admission
limits, stalled-handshake deadlines and deadlines on already-readable sockets.
The test source is a runnable task-based connection/dispatch example.

The `raft_tls_fixtures` directory contains public test-only credentials with a
fixed 2020–2040 validity window and an intentionally expired certificate.
`generate.py` regenerates them with Python's `cryptography` package; tests need
neither Python nor OpenSSL. These tests use ephemeral ports and need no network
service, public CA, DNS lookup, or Internet access.
