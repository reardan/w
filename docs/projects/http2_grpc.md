# HTTP/2, HPACK and gRPC (issue #436, "Protocols")

Pure-W implementations under `libs/standard/web/`, with no dependency
beyond `lib/`, `structures/` and the existing `libs/standard/net/dns.w`.

| File | What |
| --- | --- |
| `hpack.w` | RFC 7541 header compression |
| `http2.w` | RFC 9113 framing, streams, flow control; blocking client + minimal server |

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

- Transport: cleartext with prior knowledge (h2c). **Follow-up:** h2 over
  TLS needs ALPN in `libs/standard/net/tls.w` plus a transport seam in
  `h2_conn` (it owns a plain fd today). There is no HTTP/1.1 `Upgrade:
  h2c` path, and server push is permanently disabled (we send
  `ENABLE_PUSH = 0`; a PUSH_PROMISE is a connection PROTOCOL_ERROR).
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

Not done (candidates for follow-ups): priority scheduling (PRIORITY is
validated and ignored, as RFC 9113 permits), streaming request bodies
to the server application before END_STREAM, extended CONNECT, and a
SETTINGS ACK timeout.
