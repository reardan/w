# HTTP/2, HPACK and gRPC (issue #436, "Protocols")

Pure-W implementations under `libs/standard/web/`, with no dependency
beyond `lib/`, `structures/` and the existing `libs/standard/net/dns.w`.

| File | What |
| --- | --- |
| `hpack.w` | RFC 7541 header compression |
| `http2.w` | RFC 9113 framing, streams, flow control; blocking client + minimal server |
| `grpc.w` | gRPC unary calls (client + server) over `http2.w` |

Each file's header comment is the API reference; this note records the
design choices and what is left.

## HPACK (`hpack.w`)

- Static table, dynamic table with size accounting (`name + value + 32`),
  eviction on insert and on size change, size updates (decoder enforces
  the SETTINGS ceiling and "only before the first field"; the encoder
  signals min-then-final after a peer SETTINGS change).
- All five representations are decoded; the encoder emits indexed,
  literal-with-incremental-indexing (default), without-indexing
  (`indexing = 0`) and never-indexed (`hpack_headers_add_sensitive`).
- Huffman: the Appendix B code is canonical, so the file stores only the
  257 code lengths and rebuilds the codes at first use. Decoding is a
  canonical bit-at-a-time walk; EOS, over-long padding and non-ones
  padding are rejected. The encoder uses Huffman when it is not longer
  than the raw string -- the policy that reproduces Appendix C.
- Hard caps fail closed: integers (4 continuation bytes), string length,
  header-list size (SETTINGS_MAX_HEADER_LIST_SIZE accounting), field
  count; CR/LF/NUL in fields and empty names are rejected.
- `hpack_test.w` checks C.1 (integers), C.2.1-C.2.4, C.3/C.4 (request
  sequences, plain and Huffman) and C.5/C.6 (responses with a 256-byte
  table and eviction) in both directions: decode must produce the fields
  and table, encode must produce the RFC bytes.

## HTTP/2 (`http2.w`)

- Transport: prior knowledge, either cleartext (h2c) or h2 over TLS 1.3
  (RFC 9113 section 3.2). `h2_connect_tls` offers ALPN `h2` through
  `libs/standard/net/tls.w` (RFC 7301: `tls_config_set_alpn`,
  `tls_server_config_set_alpn`, `tls_alpn_selected`) and refuses a server
  that selected anything else; `h2_accept_tls` requires `h2` so a client
  that does not offer it gets `no_application_protocol`.
  `h2_client_new_tls` / `h2_server_new_tls` wrap an already-established
  `tls_conn`. The transport seam is `h2_conn.tls` plus
  `h2_conn_write_all` / `h2_conn_read`: all framing above them is
  transport-agnostic, and on TLS a deadline is enforced by polling the fd
  before a record starts, so an expired deadline never splits a TLS
  record. There is no HTTP/1.1 `Upgrade: h2c` path, and server push is
  permanently disabled (we send `ENABLE_PUSH = 0`; a PUSH_PROMISE is a
  connection PROTOCOL_ERROR).
- Single-threaded blocking model. `h2_pump` reads one frame and routes it
  to its stream object, so several streams can be in flight and awaited
  in any order; senders pump while a flow-control window is closed.
- Receive windows are enforced and replenished at half; the connection
  window is raised to 1 MiB at startup. Bodies are buffered whole
  (`max_body`, default 16 MiB, fail closed with RST_STREAM).
- Deadlines: `h2_set_deadline` bounds reads without corrupting the
  connection (partial frames stay buffered), so callers such as gRPC can
  abandon one stream with RST_STREAM(CANCEL) and keep the connection.
- `http2_test.w`: the W client against the W server (concurrency,
  trailers, 200 KB each way, PING), scripted raw-frame servers for
  CONTINUATION, padding, small/violated windows, PING, GOAWAY,
  PUSH_PROMISE, oversized frames, bad HPACK, RST_STREAM, 1xx and
  content-length, and raw clients against the W server for its
  stream-id and request-validation errors.
- `http2_tls_test.w`: the W client against the W server over TLS with the
  checked-in P-256 fixture cert (GET/POST, concurrency, trailers, 200 KB
  each way, PING, a deadline expiring on an idle TLS connection), plus
  both ALPN refusal paths. ALPN itself is covered by
  `libs/standard/net/tls_alpn_test.w`. gRPC over TLS would hook in by
  having `grpc.w` open its channel with `h2_connect_tls` and serve
  accepted sockets with `h2_accept_tls` instead of `h2_connect` /
  `h2_server_new`.

Not done (candidates for follow-ups): priority scheduling (PRIORITY is
validated and ignored, as RFC 9113 permits), streaming request bodies
to the server application before END_STREAM, extended CONNECT, and a
SETTINGS ACK timeout.

## gRPC (`grpc.w`)

- Unary RPCs only, following the grpc repository's PROTOCOL-HTTP2.md:
  `POST`, `content-type: application/grpc`, `te: trailers`, 5-byte
  length-prefixed messages, `grpc-status` / `grpc-message` trailers
  (percent-encoded), trailers-only responses, `grpc-timeout`.
- Serializer-agnostic: messages are bytes in, bytes out. No rule forbids
  `libs/standard` importing `libs/extras` (only `libs.x.unsafe` is
  policed, by `unsafe_import_test`), but no `libs/standard` module does
  today, so `grpc.w` keeps that layering; `grpc_test.w` pairs it with
  `libs/extras/protobuf/message.w` descriptors (`pb_encode` /
  `pb_decode_into`).
- Compression is not negotiated: the compressed flag must be 0 and a
  compressed message is answered with UNIMPLEMENTED. gzip via
  `libs/extras/compress` would be the natural follow-up (it would need
  `grpc-encoding` / `grpc-accept-encoding` handling and, per the
  layering above, an adapter outside `libs/standard`).
- Deadlines: the client sends `grpc-timeout` in milliseconds and bounds
  its wait with `h2_set_deadline`; on expiry it cancels the stream and
  keeps the connection. The server parses every unit (H/M/S/m/u/n),
  exposes `grpc_call.timeout_ms` / `grpc_call_time_left_ms`, and answers
  DEADLINE_EXCEEDED when the handler overran.
- Status mapping on the client covers non-200 HTTP statuses, missing
  `grpc-status`, non-gRPC content types, RST_STREAM codes, GOAWAY-refused
  streams and dead connections.

Not done: streaming RPCs (client, server, bidi), compression, gRPC over
TLS (blocked on ALPN, as above), a code generator from `.proto`.
