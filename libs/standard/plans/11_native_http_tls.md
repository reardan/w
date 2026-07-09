# Plan: native HTTPS client stack (HTTP/1.1, SSE, TLS 1.3) in pure W

Tracking issue: reardan/w#155. Origin: w-private#16 (libcurl FFI proposal,
closed in favor of an in-house stdlib implementation) and w-private#18 §1.

## Motivation

wharness — the W-native coding agent (w-private) — calls the Anthropic
Messages API by shelling out to `curl` through `lib/process.w`'s
`process_run`, passing the JSON body over stdin and smuggling the API key
past argv with curl's `--variable %ANTHROPIC_API_KEY` / `--expand-header`
(which pins a hard `curl >= 8.3` dependency). The limits are concrete
(w-private #16, folded into roadmap #18 section 1):

- **No SSE streaming** — incremental output would mean parsing live stdout
  from a `curl --no-buffer` subprocess with no framing guarantees.
- **No response headers** — the retry loop is blind 2s/4s/8s backoff; it
  cannot honor `retry-after` on 429/529 or log `request-id`.
- **A subprocess per turn**, and the curl version dependency.

The original proposal was an FFI binding over libcurl's easy interface.
The decision on #16 went the other way: *"Rather than bringing this in via
FFI, I think my preferred solution is actually to implement all this
functionality in house in std lib."* This plan is that in-house path —
**no FFI and no external libraries**, matching the compiler's own ethos
(no assembler, no linker, no libc). That means W implementations of URL
parsing, DNS resolution, HTTP/1.1, SSE, the TLS 1.3 handshake and record
layer, X.509 certificate validation, and the crypto primitives underneath.
A side benefit over both curl paths: the API key stays in-process in
ordinary memory, never in argv, environment expansion, or a subprocess.

This explicitly overrides two earlier non-goals:

- `07_compression_crypto.md`: "No homegrown cryptographic algorithms."
- `08_networking_web.md`: "No TLS implementation from scratch" /
  "Add TLS via C library binding".

The security trade-off is acknowledged in "Security posture" below.

## Target area

Base code directories: `libs/standard/crypto/`, `libs/standard/net/`, and
`libs/standard/web/`.

Suggested modules:

- `libs.standard.crypto.chacha20`
- `libs.standard.crypto.poly1305`
- `libs.standard.crypto.sha2` (SHA-256 exists in `lib/sha256.w`; add SHA-384)
- `libs.standard.crypto.hmac`
- `libs.standard.crypto.hkdf`
- `libs.standard.crypto.x25519`
- `libs.standard.crypto.bignum` (for RSA/ECDSA verification only)
- `libs.standard.crypto.rsa_verify`
- `libs.standard.crypto.ecdsa_p256`
- `libs.standard.crypto.random` (getrandom syscall / `/dev/urandom`)
- `libs.standard.crypto.base64` / hex (shared with plan 07)
- `libs.standard.net.dns`
- `libs.standard.net.tls`
- `libs.standard.net.x509` (DER/ASN.1 parse, PEM, trust store, chain verify)
- `libs.standard.web.urlparse`
- `libs.standard.web.http_client`
- `libs.standard.web.sse`
- `libs.standard.web.retry`

## Current W starting point

- `lib/net.w`: IPv4 TCP/UDP sockets over raw syscalls (`sys_socket`,
  `sys_connect`, `sys_sendto`, `sys_recvfrom`), nonblocking mode.
- `lib/poll.w`, `lib/event_loop.w`, `lib/task_io.w`: readiness and async I/O.
- `lib/sha256.w`: pure-W SHA-256 (already used by the build cache).
- `lib/http.w`: response-header writer only; `examples/web/http_client.w` is a
  50-line plaintext GET demo.
- `lib/stream.w`, `lib/framing.w`: buffered reader/writer utilities.
- No DNS, URL parsing, chunked transfer decoding, base64, HMAC, AEAD,
  big-integer arithmetic, ASN.1, or TLS anywhere in the tree.
- `int64`/`uint64` are **x64-only** today (see README.md language notes), and
  the primary target is 32-bit x86.

## Protocol and algorithm choices (keep the surface minimal)

- **TLS 1.3 only** (RFC 8446), client only. No TLS 1.2, no renegotiation, no
  compression, no session resumption/0-RTT in MVP. TLS 1.3's handshake is
  substantially simpler and every relevant API endpoint supports it.
- **Single mandatory cipher suite**: `TLS_CHACHA20_POLY1305_SHA256`.
  ChaCha20-Poly1305 is constant-time in pure software without lookup tables,
  unlike AES-GCM which needs table-based or carry-less-multiply
  implementations. `TLS_AES_128_GCM_SHA256` can come later if a server that
  matters refuses ChaCha20 (rare).
- **Key exchange**: X25519 only.
- **Certificate signature verification**: RSA PKCS#1 v1.5 and RSA-PSS with
  SHA-256/SHA-384, and ECDSA P-256 with SHA-256. That covers the Let's
  Encrypt, DigiCert, and Google Trust Services chains that terminate the
  APIs we care about. Verification only — W never needs to sign.
- **HTTP/1.1 only** (RFC 9110/9112): `Content-Length` and `chunked` bodies,
  `Connection: keep-alive`, no HTTP/2 or 3. SSE works fine over HTTP/1.1.
- **DNS**: A records over UDP port 53 with TCP fallback on truncation,
  `/etc/resolv.conf` + `/etc/hosts` handling. No IPv6/AAAA in MVP (sockets
  are IPv4-only today), but don't design it out.

## Platforms

wharness runs on both Linux and macOS, so unlike most of `lib/`, this stack
is **not** Linux-only:

- Linux x86/x64/arm64 first (CI-covered), `arm64_darwin` as a fast follow.
- `lib/__arch__/arm64_darwin/syscalls.w` already wraps the Darwin socket
  syscalls (`sys_socket`, `sys_connect`, `sys_recvfrom`, ...), but
  `lib/net.w`'s `sockaddr_in` uses Linux layout — Darwin splits the leading
  16 bits into `sin_len`/`sin_family` bytes. Audit and fix as an explicit
  phase 2 work item; add a darwin socket smoke test runnable via
  `tools/mac/run_darwin_tests.sh`.
- DNS: `/etc/hosts` and `/etc/resolv.conf` exist on macOS too (resolv.conf
  is synthesized but present); good enough for MVP.
- Trust store: Linux uses `/etc/ssl/certs/ca-certificates.crt` and common
  alternates; macOS has no system PEM bundle (certs live in the Security
  keychain). On darwin, honor `SSL_CERT_FILE`, then a config-provided
  path; document generating a bundle (`brew`'s ca-certificates or
  `security export`) rather than binding the Security framework.

## 32-bit portability rule

All crypto must be written with 32-bit-safe limb arithmetic:

- X25519 and P-256 field elements: signed/unsigned 32-bit limb schedules
  (e.g. 10x25.5-bit limbs for curve25519) with explicit carry handling —
  no `int64` in the portable path.
- SHA-384/512's 64-bit words: represented as hi/lo 32-bit pairs (the same
  trick every 32-bit SHA-512 implementation uses).
- `bignum`: base-2^16 or 2^30 limbs stored in 32-bit ints so products fit.

An x64-only fast path using `int64` is a later optimization, not the
baseline. Tests must run on x86, x64, and arm64 targets.

## Security posture

Homegrown TLS is a real risk and we accept it deliberately:

- Client-only scope: we protect the confidentiality/integrity of outbound
  API calls; we are not building a server exposed to hostile clients.
- Certificate validation is **on by default**: chain building to a system
  trust store (`/etc/ssl/certs/ca-certificates.crt` and common alternates),
  validity dates, hostname verification against SAN dNSName entries
  (wildcard rules per RFC 6125). An explicit `tls_insecure_skip_verify`
  knob exists for tests only and must be loud in the API name.
- Constant-time discipline for secret-dependent operations (ChaCha20,
  Poly1305 accumulation, X25519 ladder, HMAC compare). Verification-side
  bignum (RSA/ECDSA public ops) handles no secrets and may be variable-time.
- Every primitive lands with published test vectors (RFC 8439, RFC 7748,
  NIST CAVP SHA vectors, Wycheproof subsets checked in as fixtures) before
  anything composes on top of it.
- Failures must be closed: any parse error, bad MAC, or verify failure
  tears down the connection with a clear error; no fallback-to-insecure.

## API sketch

`web/http_client.w`

- `http_response* http_get(char* url)` / `http_request(http_req* req)`
- `http_req`: method, url, headers list, body, timeout_ms, max_redirects
- `http_response`: status, headers map, body bytes, error code
- Streaming variant: `http_stream* http_open(http_req* req)` with
  `int http_stream_read(http_stream* s, char* buf, int len)` so SSE can
  consume the body incrementally without buffering it.

`web/sse.w`

- `sse_reader* sse_open(http_stream* s)`
- `sse_event* sse_next(sse_reader* r)` — blocking next event; parses
  `event:`/`data:`/`id:`/`retry:` fields, multi-line data joining, comment
  lines, and CR/LF/CRLF line endings per the WHATWG EventSource spec.
- Honors `retry:` by updating the reader's reconnect-delay field; the caller
  owns actual reconnection (composes with `web/retry.w`).

`web/retry.w`

- `retry_policy`: max_attempts, base_delay_ms, max_delay_ms, jitter,
  retryable status set (429/5xx including 529)
- `int retry_delay_ms(retry_policy* p, int attempt, http_response* resp)` —
  honors `Retry-After` (both delta-seconds and HTTP-date forms) when present,
  else exponential backoff with jitter from `crypto.random`. Response headers
  (`request-id`, rate-limit headers) are plain map entries on
  `http_response`, so callers can log them.

`net/tls.w`

- `tls_conn* tls_connect(int sockfd, char* server_name, tls_config* cfg)`
- `int tls_read(tls_conn* c, char* buf, int len)` / `tls_write(...)`
- `void tls_close(tls_conn* c)` (sends close_notify, frees keys)
- `tls_config`: trust store path override, insecure_skip_verify (tests only)

`net/dns.w`

- `int dns_resolve_ipv4(char* hostname, int* out_ip)` — `/etc/hosts`, then
  resolv.conf servers, 2s timeout per server, ID randomized from
  `crypto.random`.

## Implementation phases

Each phase is independently landable, tested, and useful on its own. Phases
1–3 already replace the curl subprocess for plaintext/dev use and define the
final API; TLS slots in underneath without changing callers.

### Phase 1: encoding + randomness plumbing

- `crypto/base64.w`, hex helpers (shared deliverable with plan 07 phase 2).
- `crypto/random.w`: `sys_getrandom` wrapper (new syscall number in all four
  `lib/__arch__/*/syscalls.w` tables) with `/dev/urandom` read fallback.
- Tests: RFC 4648 vectors, length/bounds checks.

### Phase 2: URL parse, DNS, plaintext HTTP/1.1

- `web/urlparse.w`: scheme/host/port/path/query for http+https, percent
  decode/encode (tightens plan 08 phase 3 to what the client needs).
- `net/dns.w` as sketched.
- Darwin socket audit: fix `sockaddr_in` layout for `arm64_darwin`
  (`sin_len`/`sin_family` bytes) without breaking the Linux callers of
  `lib/net.w`; darwin smoke test.
- `web/http_client.w`: request writer, status-line/header parser,
  `Content-Length` and `chunked` decoding, keep-alive, redirects,
  streaming body reader. Built on `lib/stream.w` buffered I/O.
- Tests: pure-W local HTTP test server fixture (extends `examples/web/`)
  covering GET/POST, chunked, malformed headers, oversized headers,
  redirect loops, connection close mid-body.

### Phase 3: SSE + retry policy

- `web/sse.w` and `web/retry.w` as sketched.
- Tests: WHATWG parsing cases (field ordering, BOM, comment keep-alives,
  multi-line data, `retry:`), Retry-After delta and HTTP-date forms,
  backoff growth and jitter bounds. Local SSE test server fixture that
  dribbles events with delays and mid-stream disconnects.
- **Milestone: the client API shape is final.** wharness can integrate
  behind its `wh_api_send` seam (keeping the curl subprocess as fallback)
  for plaintext endpoints and local proxies; TLS later slots in underneath
  without changing callers.

### Phase 4: symmetric crypto + key schedule

- `crypto/chacha20.w` (RFC 8439), `crypto/poly1305.w`, AEAD composition
  `chacha20poly1305_seal/open`.
- `crypto/sha2.w`: SHA-384 via hi/lo 32-bit pairs; keep `lib/sha256.w` as
  the SHA-256 core or fold it in behind the same interface.
- `crypto/hmac.w`, `crypto/hkdf.w` (extract/expand, RFC 5869), plus the
  TLS 1.3 `HKDF-Expand-Label`/`Derive-Secret` helpers.
- Tests: RFC 8439 and RFC 5869 vectors, Wycheproof ChaCha20-Poly1305
  subset, NIST SHA-384 vectors, RFC 8448 key-schedule trace values.

### Phase 5: X25519

- `crypto/x25519.w`: Montgomery ladder, 32-bit limb field arithmetic,
  constant-time conditional swap.
- Tests: RFC 7748 vectors including the 1k-iteration test, low-order point
  rejection (all-zero shared secret check).

### Phase 6: ASN.1, X.509, and signature verification

- `crypto/bignum.w`: modexp (Montgomery or simple square-and-multiply —
  public keys only), mod-inverse, comparison.
- `crypto/rsa_verify.w`: PKCS#1 v1.5 with strict DigestInfo match, RSA-PSS.
- `crypto/ecdsa_p256.w`: verification only (no signing, no secret handling).
- `net/x509.w`: DER parser (definite-length only), certificate fields
  (validity, subject/SAN, key usage, basic constraints), PEM decode, trust
  store loader, chain building and signature verification, hostname match.
- Tests: parse fixture chains checked into `tests/` (Let's Encrypt +
  DigiCert real chains, expired/self-signed/wrong-host negative fixtures),
  Wycheproof RSA/ECDSA verify subsets.

### Phase 7: TLS 1.3 client

- `net/tls.w`: ClientHello (SNI, supported_versions, key_share,
  signature_algorithms), handshake state machine, transcript hash, record
  layer with AEAD, server Finished/certificate verification, application
  data, key update, close_notify, alert handling.
- Tests: RFC 8448 handshake-trace unit tests against the state machine;
  loopback interop test against `openssl s_server` **gated on the tool
  being present** (test-only harness dependency, not a runtime one);
  negative tests: bad Finished MAC, wrong cert host, tampered record.

### Phase 8: integration + hardening

- Wire `net/tls.w` under `web/http_client.w` for `https://` URLs.
- End-to-end: streaming SSE over TLS against the local openssl-gated
  fixture; timeout coverage (connect, TLS handshake, header, idle-stream);
  memory ownership audit (every buffer freed on every error path).
- A small `examples/web/https_get.w` demo replacing the curl usage pattern.
- Downstream (w-private, tracked there): swap wharness's `wh_api_send` to
  the native client with SSE streaming and retry-after-aware backoff;
  retire the curl subprocess path once stable on both platforms.

## Deliberate non-goals (MVP)

- No TLS 1.2, session resumption, 0-RTT, client certificates, or ALPN
  (add ALPN only if HTTP/2 ever happens).
- No AES-GCM until a needed endpoint demands it.
- No CRL/OCSP revocation checking.
- No proxy support (`CONNECT`) in the first pass; the API leaves room.
- No gzip/deflate response decoding — send `Accept-Encoding: identity`
  until plan 07 lands inflate.
- No HTTP server work (plan 08 keeps that).

## Build/test wiring

- Every module gets a sibling `_test.w`, a `build.json` target, membership
  in the `tests` umbrella, and `tools/test_map.w` entries per CLAUDE.md.
- Crypto vectors land as checked-in fixture files, not network fetches.
- Nothing here enters `w.w`'s import graph, so there is no seed constraint;
  new language syntax is allowed from day one.
- CI/network: all tests run offline (local fixtures); the openssl-gated
  interop target is skipped cleanly when the binary is absent.

## Acceptance criteria

- `http_get(c"https://api.anthropic.com/...")` works with full certificate
  and hostname validation on x86, x64, and arm64 Linux targets, then
  `arm64_darwin`.
- SSE streaming consumes a long-running event stream incrementally with
  bounded memory, surfacing events as they arrive.
- `retry_delay_ms` honors `Retry-After` in both forms on 429/529 and backs
  off exponentially with jitter otherwise; `request-id` is readable from
  response headers.
- All crypto primitives pass their published vectors in `./wbuild tests`.
- Negative TLS tests (bad MAC, bad cert, bad host) fail closed.
- wharness can drop the `curl >= 8.3` subprocess transport entirely.
