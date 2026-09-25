# HTTP/2, HPACK and gRPC (issue #436, "Protocols")

Pure-W implementations under `libs/standard/web/`, with no dependency
beyond `lib/`, `structures/` and the existing `libs/standard/net/dns.w`.
Message compression plugs in through a registry (`codec.w`, below), so
`libs/standard` still does not import `libs/extras`.

| File | What |
| --- | --- |
| `hpack.w` | RFC 7541 header compression |
| `http2.w` | RFC 9113 framing, streams, flow control; blocking client + minimal server |
| `grpc.w` | gRPC unary and streaming calls (client + server) over `http2.w`, with message compression |
| `codec.w` | content-coding registry (`gzip`, `deflate`, ... by name) |
| `libs/extras/compress/codecs.w` | registers gzip/deflate from `libs/extras/compress` into `codec.w` |

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

- Unary, server-streaming, client-streaming and bidirectional calls,
  following the grpc repository's PROTOCOL-HTTP2.md: `POST`,
  `content-type: application/grpc`, `te: trailers`, 5-byte
  length-prefixed messages, `grpc-status` / `grpc-message` trailers
  (percent-encoded), trailers-only responses, `grpc-timeout`,
  `grpc-encoding` / `grpc-accept-encoding`.
- Serializer-agnostic: messages are bytes in, bytes out; `grpc_test.w`
  pairs it with `libs/extras/protobuf/message.w` descriptors
  (`pb_encode` / `pb_decode_into`).
- Client streaming API: `grpc_stream_open` sends the request HEADERS,
  then `grpc_stream_send` / `grpc_stream_close_send` /
  `grpc_stream_recv` (1 message, 0 clean end, -1 failed) in any order,
  `grpc_stream_cancel`, and `grpc_stream_finish` for the status,
  headers and trailers. `grpc_unary_call` is a thin wrapper over it. A
  send that fails because the server already finished does not decide
  the status: the buffered messages and the server's own status are
  still read by `grpc_stream_recv`.
- Server: `grpc_server_register_stream` handlers start as soon as the
  request HEADERS arrive (unary handlers still see the whole request)
  and use `grpc_call_recv` / `grpc_call_send`; response headers go out
  with the first message, and returning finishes the call (trailers, or
  trailers-only when nothing was sent). A handler whose response is
  complete while the client is still sending ends the stream and then
  sends RST_STREAM(NO_ERROR) (RFC 9113 section 8.1). HTTP-level
  rejections (405, 415) still wait for the request's END_STREAM so
  plain HTTP clients see a normal end of stream.
- Model: one blocking thread. The client can interleave several calls
  on one channel; the server runs one call at a time per connection
  (frames for other streams are buffered meanwhile), so a client must
  not make one call on a connection wait for a later call on the same
  connection. Receive windows are replenished as DATA arrives, not as
  messages are consumed: two peers blocked in send (bidi with neither
  side reading) cannot deadlock on flow control, and unread input is
  bounded by `h2_conn.max_body` (RST_STREAM(ENHANCE_YOUR_CALM) ->
  RESOURCE_EXHAUSTED). Sends go through `h2_send_data`, which honors the
  peer's windows. Before each message a sender also handles frames that
  are already readable (`grpc_pump_ready`: buffered complete frames, or
  a `poll` on `h2_conn.fd`), so cancellation or an early server status
  is noticed without waiting for a window to close.
- Cancellation and deadlines mid-stream: `grpc_stream_cancel` sends
  RST_STREAM(CANCEL) (status CANCELLED); the server's next
  `grpc_call_send` / `grpc_call_recv` fails with `call.cancelled` set.
  The client bounds every blocking step by the call deadline and cancels
  on expiry (DEADLINE_EXCEEDED, connection kept); the server bounds
  recv/send by `grpc-timeout` and reports DEADLINE_EXCEEDED.
- Compression. **Layering decision:** `grpc.w` does not import
  `libs/extras/compress`. It looks codings up in
  `libs/standard/web/codec.w`, a small process-wide registry of named
  whole-buffer codecs, and `libs/extras/compress/codecs.w`
  (`compress_codecs_register()`) registers gzip and zlib-wrapped
  deflate there. Reasons: it keeps the documented "libs/standard does
  not depend on libs/extras" layering; the registry is the single source
  of truth for what a process can *decode*, which is exactly what
  `grpc-accept-encoding` must advertise; it is shared by other
  negotiating protocols (WebSocket permessage-deflate, HTTP
  Content-Encoding) instead of each one growing its own adapter; and it
  lets other codings (zstd, snappy) plug in without touching `grpc.w`.
  The cost is one opt-in call; without it gRPC runs identity-only, which
  is fully spec-compliant. This mirrors the SHA-1 seam
  (`whash_register` / `ws_use_sha1`), minus the policy force.
- Negotiation: both sides send `grpc-accept-encoding` (registered
  names) when anything is registered. The client compresses every
  request message with the channel's coding
  (`grpc_channel_set_compression`, flag 1 + `grpc-encoding`). The server
  answers with its configured coding (`grpc_server_set_compression`)
  when the client accepts it, else mirrors the request's coding when the
  client accepts that, else identity; `grpc_call_set_compression`
  overrides per call. An unregistered request `grpc-encoding` is
  UNIMPLEMENTED (trailers-only, with the server's
  `grpc-accept-encoding`). On the client, an unsupported response coding
  or a compressed flag without `grpc-encoding` is INTERNAL; corrupt
  compressed data is INTERNAL on either side.
- Size caps fail closed: the wire length and the *decompressed* length
  of each message are both capped at `max_message` (4 MiB default,
  per channel and per server); inflate stops as soon as its output
  would pass the cap and the call fails RESOURCE_EXHAUSTED, so a 1 KB
  message cannot expand to 1 MB in memory.
- Status mapping on the client covers non-200 HTTP statuses, missing
  `grpc-status`, non-gRPC content types, RST_STREAM codes, GOAWAY-refused
  streams and dead connections.
- Tests: `grpc_test.w` (unary, protobuf, status mapping) and
  `grpc_stream_test.w` (each streaming kind, 1.2-1.5 MB streams past
  every flow-control window, interleaved calls, bidi ping-pong, error
  after messages, cancellation and deadline mid-stream, gzip/deflate
  unary and streaming, oversize decompression both ways, encoding
  mismatch, and scripted client-side coding errors).

Not done: gRPC over TLS (blocked on ALPN, as above), a code generator
from `.proto`, per-message compression opt-out on a compressed stream,
flow-control windows tied to message consumption, and concurrent calls
within one server connection.
