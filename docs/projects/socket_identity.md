# Kernel socket identity and half-close

`lib/net.w` exposes `socket_peer_address_checked`,
`socket_peer_credentials_checked`, and `socket_shutdown_checked`. Each fills a
caller-owned `io_result`, returns its `IO_*` category, preserves native syscall
errors, and reports zero transferred bytes. These are immediate control calls:
they do not wait for readiness, allocate memory, acquire descriptor ownership, or
consult a task deadline. `lib/transport.w` exposes the corresponding
`transport_peer_address`, `transport_peer_credentials`, and `transport_shutdown`
operations with task cancellation and the transport's absolute deadline checked
before invoking the adapter.

## Three distinct forms of identity

- `transport_peer(t)` is a copied display label. It may be supplied by a caller;
  Unix accepted-connection labels include the listener path for context.
- `transport_peer_address(t, &address, &result)` calls `getpeername`. The
  `net_peer_address` record contains a normalized `family`, `length`, and 128
  bytes of raw native sockaddr storage in `data`. Only the first `length` bytes
  are meaningful. IPv4 address/port bytes use network order. Unix names can be
  unnamed or, on Linux, contain embedded NULs for abstract addresses; they are
  never implicitly converted to C strings. An accepted unbound Unix client's
  kernel address is unnamed, not the listener's pathname.
- `transport_peer_credentials(t, &credentials, &result)` obtains local Unix
  connection credentials from the OS. Linux uses `SO_PEERCRED` for pid, uid, gid.
  Darwin uses `LOCAL_PEERCRED` for uid and primary gid, and explicitly returns
  pid = -1. These describe the connection's OS credential snapshot and do not
  establish cryptographic authentication or promise the process is still alive.
  ID fields preserve the native 32-bit bit pattern, including on x86.

Address and credential queries never set `transport_authenticated`. That flag is
reserved for cryptographically verified adapters such as TLS. TCP credential
queries return `IO_UNSUPPORTED`, even on Linux kernels that would otherwise
return a dummy `SO_PEERCRED` record. Connected Unix datagrams whose
kernel result contains no credentials also return `IO_UNSUPPORTED`. Query failures clear the output record
(address family/length zero, credentials -1), preventing stale identity reuse.

## Directional shutdown and ownership

`NET_SHUT_READ`, `NET_SHUT_WRITE`, and `NET_SHUT_BOTH` select the directions.
Write shutdown sends an orderly end-of-stream after queued output; the peer can
finish reading that output while the caller continues reading the peer's reply.
Read shutdown leaves writes available. Reads on a shut-down read direction and
writes on a shut-down write direction keep the OS's behavior; the write adapter
suppresses SIGPIPE and reports EPIPE as an ordinary error.

Shutdown does not close or free anything. It affects the underlying socket even
when `owns_fd = 0`, so borrowed wrappers require the caller's permission to alter
that socket. A successful transport shutdown remembers each completed direction;
repeating it returns `IO_OK` without another syscall. Failed operations do not
mark a direction completed. The raw checked socket function deliberately retains
the kernel's repeated-shutdown behavior and error. Deadline and cancellation
checks still apply to repeated transport calls.

`transport_close` remains unconditional cleanup: it ignores expired deadlines,
closes owned descriptors once, and succeeds on repeated calls. After close, all
three new transport operations return EBADF without touching the descriptor.
The wrapper remains allocated until `transport_free`.

## Adapter and platform support

A custom `transport_new` adapter starts with null `peer_address_fn`,
`peer_credentials_fn`, and `shutdown_fn` capabilities. Each missing capability
returns `IO_UNSUPPORTED` with native_error 0. Adapters can opt in independently.
TLS does not expose raw socket shutdown: that would bypass TLS close-notify
semantics. The API never obtains credentials or socket addresses by casting an
unknown adapter's context.

Linux x86/x64/ARM64 and Darwin ARM64 supply native address and shutdown adapters.
Darwin's credential layout follows XNU's [Unix socket options](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h)
and [xucred definition](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/ucred.h).
Win64 and Wasm identity adapter modules explicitly advertise no support;
these targets currently have no general `lib/net.w` socket backend. No placeholder
syscall result is reported as success or as peer authentication.

`lib/socket_identity_test.w` tests connected and accepted TCP/Unix addresses,
credential success and unsupported cases, both shutdown directions, surviving
direction I/O, cancellation/deadline checks, repeated shutdown/close, borrowed
ownership, and native EBADF/EINVAL/ENOTSOCK/ENOTCONN/EPIPE preservation. Its standard
targets run on Linux x86 and x64; it also compiles for ARM64 Linux and Darwin.
