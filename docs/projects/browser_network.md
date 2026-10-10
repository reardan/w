# Browser resource loading foundations

Issue [#637](https://github.com/reardan/w/issues/637) adds reusable URL and resource
loading APIs. Navigation, cookies, caching, access policy and content isolation
remain embedding responsibilities.

## URL references

Import `libs.standard.web.urlparse`. `url_parse` accepts absolute HTTP/HTTPS URLs;
`url_resolve(base, reference)` returns a new owned URL using RFC 3986 component
merging and dot-segment removal. The base is borrowed. Free results with
`url_free`; `url_unparse` returns a separately owned string.

`URL` retains `fragment`, `has_fragment`, and `has_query` in addition to its
existing scheme/host/port/path/query fields. Empty `?` and `#` delimiters round
trip. HTTP sends the query delimiter, including empty queries, but never the
fragment. Scheme and host are ASCII lowercased and serialization omits default
ports. An absent path becomes `/`. Resolution removes literal dot segments;
parsing alone preserves path spelling. Percent escapes are validated and retained,
so `%2F`, `%23` and `%2e` never become structural separators or dot segments.
Repeated slashes and path/query case remain unchanged.

Bracketed IPv6 accepts hexadecimal groups, one optional `::`, and a terminal
dotted IPv4 address. Hosts serialize with lowercase hex, suppressed leading
zeros, and the first longest zero run of at least two groups compressed, following
[RFC 5952 section 4](https://www.rfc-editor.org/rfc/rfc5952#section-4).
Dotted tails serialize as two hex groups, so `::ffff:192.0.2.128` and
`::ffff:c000:280` have the same canonical host. Dotted octets must be decimal
0–255 without leading zeros. IPv4-mapped IPv6 remains distinct from an ordinary
IPv4 host. `url_same_origin` compares normalized scheme/host/effective-port
tuples, including equivalent IPv6 spellings.

Zone identifiers, IPvFuture, userinfo, IDNA, WHATWG backslash repair and
percent-escape normalization are not implemented. Spaces, controls, backslashes,
invalid ports and invalid percent escapes fail. DNS host normalization is still
ASCII lowercasing; it does not apply IDNA. The current TCP HTTP connector still
resolves IPv4 addresses only; accepting IPv6 URL syntax does not imply IPv6
transport support.

`file:` is explicitly rejected by both entry points. Local files need a separate
embedding policy and explicit file loader; they must not acquire an HTTP origin
or pass through the network redirect path.

## Owned clients and checked transport

```w
import libs.standard.web.http_client

http_client* client = http_client_new()
http_req* req = http_req_new(c"GET", c"https://example.com/")
req.client = client
req.total_timeout_ms = 5000
req.max_stream_bytes = 1048576
http_response* response = http_request(req)
# response.error, response.final_url, response.redirect_count, response.body_len
http_response_free(response)
http_req_free(req)
http_client_free(client)
```

An explicit client owns at most one active stream. Separate clients may run
concurrently in tasks. Serialize access to each individual client, including
close/free; use `task_cancel` to interrupt a task currently executing an open or
read. A second open before its stream closes reports `http_error_client_busy`.
`http_client_close` closes an opened active stream's transport and marks its
response cancelled; the stream remains caller-owned and must still be closed.
Closing twice is safe. A closed client cannot open new requests. Freeing a client
closes it and detaches its surviving stream handle.

Explicit clients bypass the legacy process-global idle cache and close every
connection. This is a deliberate ownership contract, with connection pooling
left for later. Existing calls without a client or total timeout retain legacy
connection reuse and inactivity timeouts. They do not become thread-safe through
this addition. Assigning `total_timeout_ms > 0` also selects checked transport
without requiring a client.

The checked path reuses `lib.transport` and `lib.transport_tls`: one monotonic
absolute deadline covers DNS server attempts, TCP connect, TLS handshake,
request writes, response headers, redirects and body reads. Explicit clients
use 30 seconds unless a positive total timeout is provided. A positive TLS
handshake timeout may further shorten that phase. DNS hosts/resolver files and
CPU work are synchronous; the deadline is checked before subsequent I/O, not a
preemptive CPU/file-system timer. Checked reads test task cancellation/deadline
even when bytes are already buffered. A task cancellation reports
`http_error_cancelled`; timeout reports `http_error_timeout`; failed TLS validation
or protocol negotiation reports `http_error_tls`. Partial buffered bodies retain
only bytes successfully delivered before an error.

`max_stream_bytes` bounds delivered bytes of the final response (positive values
opt in; owned clients default to 64 MiB). Redirect drains have a separate 64 KiB
cap and do not consume the final body's budget. Buffered requests additionally
honor `max_body_bytes`. Reading past the streaming cap probes one byte to tell
exact completion from overflow, reports `http_error_body_too_large`, and does not
return the excess byte. Close an error stream promptly to release its transport.

`response.final_url` is an owned serialized URL, including its fragment;
`redirect_count` counts followed redirects. It can be null when validation failed
before a URL was parsed. `req.approve_redirect` is an optional callback:

```w
type http_redirect_approval = fn(void*, URL*, URL*, int) -> int
```

It receives `redirect_context`, borrowed current/next URLs, and status before each
follow. Return zero to keep the original redirect response unfollowed; nonzero
approves. The redirect cap is still enforced. Callbacks must not mutate/free the
borrowed URLs, reenter the same client, or outlive the request. Apply destination
and credential policies in the embedding; the compatibility client does not
strip caller-supplied headers when origins change.

## Content decoding

Import `libs.standard.web.content_decode`. `content_decoder_new(encoding,
max_input, max_output)` creates an owned bounded collector. Both limits must be
positive. `content_decoder_feed(data, length)` copies a chunk and returns
`content_decode_more` or an error. An empty chunk does not mean EOF. Only
`content_decoder_finish` validates the complete stream and returns
`content_decode_done`, with owned `output` and `output_length`. Finish is
idempotent; feed after completion/error returns `content_decode_state_error`.
Free all storage with `content_decoder_free`.

`http_content_collect(stream, max_input, max_output)` consumes a borrowed HTTP
stream using its Content-Encoding and returns the same owned result. It leaves
stream ownership with the caller. A transport failure has status
`content_decode_transport_error`, with the specific HTTP error on the stream.

Identity works without registration. Import `libs.extras.compress.codecs` and
call `compress_codecs_register()` once before concurrent work for gzip and
zlib-wrapped deflate. Advertise these encodings explicitly in request headers.
The implementation reuses the existing codec registry and bounded inflater;
it does not implement another compressor. Unsupported/stacked encodings fail
explicitly. Input is collected incrementally, but decompression occurs once at
finish; this API does not yet produce streaming decompressed chunks. Gzip decoding validates and concatenates every member, sharing one output
budget across them. Reserved header flags, bad header/payload checksums, truncated
later members and trailing non-member bytes all fail without exposing partial
output. Deflate requires exactly one complete zlib stream and rejects trailing
bytes. Empty gzip members remain valid when the output budget is exhausted.

## Validation

`urlparse_test` and `urlparse_64_test` cover reference tables, delimiters, IPv6,
round trips and origin comparison. `http_browser_test` and
`http_browser_64_test` use controlled loopback servers for ownership, shutdown,
slow trickles, truncation, redirect approval/loops, bounded streaming, TLS failure
and cancellation. `content_decode_test` and `content_decode_64_test` cover byte
chunks, explicit EOF, every truncation of a compressed fixture, expansion/input
limits, concatenated gzip members, header/trailer validation, trailing-byte
rejection, unsupported encodings and binary identity/deflate data. Existing HTTP,
DNS, transport and TLS suites remain compatibility guards.

The combined [external consumer](../../examples/web/browser_resource.w) uses
same-origin redirect approval, checked loading, gzip/deflate decoding, and the
independent HTML/CSS APIs. It can be copied outside this checkout and compiled
from any directory with `bin/wv2 --import-root /path/to/w main.w -o consumer`.
The separate-directory probe is exercised against a controlled gzip HTTP server;
no public network service is required.
