# Plan: networking, internet protocols, and web utilities

## Target area

Base code directory: `libs/standard/net/`, `libs/standard/web/`, and
`libs/standard/email/`

Suggested modules:

- `libs.standard.net.socket`
- `libs.standard.net.selectors`
- `libs.standard.net.ssl`
- `libs.standard.net.ipaddress`
- `libs.standard.net.uuid`
- `libs.standard.web.urlparse`
- `libs.standard.web.request`
- `libs.standard.web.http_client`
- `libs.standard.web.http_server`
- `libs.standard.web.cookies`
- `libs.standard.web.mimetypes`
- `libs.standard.email.message`
- `libs.standard.email.smtp`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/socket.py` and `Modules/socketmodule.c` - socket API and address handling.
- `Lib/selectors.py` and `Modules/selectmodule.c` - multiplexing facade.
- `Lib/ssl.py` and `Modules/_ssl.c` - TLS wrapping over sockets.
- `Lib/urllib/parse.py`, `Lib/urllib/request.py` - URL parsing and HTTP openers.
- `Lib/http/` - client/server status codes, parsing, cookies.
- `Lib/socketserver.py` and `Lib/http/server.py` - simple server patterns.
- `Lib/ipaddress.py` - IPv4/IPv6 parsing and networks.
- `Lib/uuid.py` - UUID generation and parsing.
- `Lib/email/` and `Lib/smtplib.py` - email message and SMTP client behavior.
- `Lib/mimetypes.py` - extension-to-type mapping.

## Current W starting point

- `lib/net.w` wraps IPv4 TCP/UDP sockets and nonblocking mode.
- `lib/poll.w` and `lib/event_loop.w` provide low-level readiness and timers.
- `lib/http.w` only writes basic HTTP response headers.
- `examples/web/` contains minimal HTTP server/client/proxy examples.
- `lib/json_rpc.w` implements JSON-RPC over Content-Length framing.
- No DNS, TLS, URL parsing, HTTP request parser, cookies, MIME, email, IPv6, or
  high-level client/server abstraction exists.

## Goals

1. Wrap existing socket functionality under a Python-inspired standard namespace.
2. Add URL parsing, IP address parsing, UUID, MIME helpers.
3. Add HTTP request/response parsing plus simple client/server helpers.
4. Add TLS via C library binding after socket abstraction is stable.
5. Add email/SMTP after text and networking foundations exist.

## Non-goals for MVP

- No full `asyncio` integration in this plan; concurrency owns that.
- No browser-grade HTTP stack.
- No TLS implementation from scratch.
- No complete email MIME policy engine in the first pass.

## API sketch

`net/socket.w`

- `socket* socket_create_tcp4()`
- `int socket_bind(socket* s, char* host, int port)`
- `int socket_listen(socket* s, int backlog)`
- `socket* socket_accept(socket* s)`
- `int socket_connect(socket* s, char* host, int port)`
- `int socket_send(socket* s, char* data, int length)`
- `int socket_recv(socket* s, char* buf, int length)`
- `void socket_close(socket* s)`

`net/selectors.w`

- `selector* selector_new()`
- `int selector_register(selector* sel, int fd, int events, void* data)`
- `list[selector_event*] selector_select(selector* sel, int timeout_ms)`

`net/ipaddress.w`

- `int ipv4_parse(char* text, int* out)`
- `char* ipv4_format(int address)`
- `int ipv4_in_network(int address, int network, int prefix)`
- IPv6 deferred unless syscall/address structs are ready.

`net/uuid.w`

- `uuid uuid4()`
- `int uuid_parse(char* text, uuid* out)`
- `char* uuid_format(uuid id)`

`web/urlparse.w`

- `url* url_parse(char* text)`
- `char* url_unparse(url* u)`
- `char* url_quote(char* text)`
- `char* url_unquote(char* text)`
- `map[string, list[string]] parse_qs(char* query)` after map string APIs settle.

`web/http_client.w`

- `http_response* http_get(char* url)`
- `http_response* http_request(http_request* req)`
- MVP: HTTP/1.1 over plain TCP, Content-Length bodies.

`web/http_server.w`

- `http_server* http_server_new(int port, http_handler* handler, void* ctx)`
- `int http_server_serve_forever(http_server* server)`
- Parse method, path, headers, body.

`net/ssl.w`

- `ssl_context* ssl_create_default_context()`
- `ssl_socket* ssl_wrap_socket(ssl_context* ctx, socket* s, char* server_hostname)`
- `int ssl_read/ssl_write/ssl_close`

## Implementation phases

### Phase 1: socket facade and errors

- Wrap `lib.net` with owned `socket` structs and consistent error returns.
- Add host parsing for dotted IPv4 first; DNS can use libc `getaddrinfo` later.
- Tests: localhost bind/connect, send/recv, nonblocking error path.

### Phase 2: selectors

- Wrap `lib.poll` into selector-style register/unregister/select.
- Use this from HTTP server tests instead of raw poll.
- Tests: socketpair readiness, timeout, unregister behavior.

### Phase 3: URL, IP, UUID, MIME

- Port URL parse behavior from `urllib.parse` for common schemes.
- Add percent encode/decode with strict invalid escape handling.
- UUID4 should use `crypto.secrets`.
- Tests: Python docs URL examples, IPv4 edge cases, UUID round trip.

### Phase 4: HTTP parser

- Implement request/status line parsing, header map, Content-Length body.
- Enforce header/body limits.
- Add response writer with status constants.
- Tests: GET, POST, malformed header, keep-alive deferred/closed behavior.

### Phase 5: HTTP client/server

- Client: parse URL, connect, write request, read response.
- Server: accept loop, call handler, write response, close connection.
- Tests: local server/client round trip, 404 handler, body echo.

### Phase 6: TLS

- Bind OpenSSL or system TLS library.
- Validate certificates by default for clients.
- Tests may be gated if cert store/library is absent; include local self-signed
  fixture only if validation behavior is explicit.

### Phase 7: email and SMTP

- Start with message header parsing and MIME type helpers.
- Add simple SMTP client after TLS and DNS are available.
- Tests: parse headers, fold/unfold, SMTP command formatting with fake server.

## Compatibility notes from Python

- Python sockets are cross-platform and support many address families. W can be
  Linux-first and IPv4-first, but API names should not block IPv6 later.
- Python `urllib.request` is large. W should start with `http_get` and explicit
  request structs.
- Python `ssl` is security-sensitive. Do not expose insecure defaults copied
  from examples; certificate validation should be on by default.

## Acceptance criteria

- A W test can run a local HTTP server and client round trip.
- URL/IP/UUID helpers match Python for documented examples.
- Socket wrappers manage ownership and close descriptors in tests.
- TLS is either implemented with validation or clearly absent from the MVP API.
