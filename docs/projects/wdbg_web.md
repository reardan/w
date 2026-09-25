# wdbg_web: a browser front end for wdbg (issue #98)

Status: v1 landed (tools/wdbg_web.w, tools/wdbg_web/, `./wbuild wdbg_web`,
tested by `wdbg_web_test`).

## Usage

```sh
./wbuild wdbg_web
./bin/wdbg_web tests/debug_fixture.w
# https://127.0.0.1:41234/?code=5f0c...   <- open this
./bin/wdbg_web --core core.1234 bin/prog   # post-mortem: a wcore report
```

The browser warns once about the self-signed certificate; accept it.
Options: `--port`, `--bind`, `--http`, `--cert/--key`, `--code`,
`--no-break-start`, `--wdbg`, `--wcore`, `--static`, and `-- args...`
for the program (full list in the tool's header comment).

## Shape

```
browser  --https/JSON-->  bin/wdbg_web (x64)  --pipes-->  bin/wdbg prog.w
  tools/wdbg_web/*          poll(2) loop                  unchanged text
  (static HTML/JS)          http_server.w routing         command loop
                            tls.w server role
                            selfsigned.w cert
```

- **Transport: wdbg's own text protocol.** The issue weighed a new
  structured protocol against reusing the stdin/stdout loop behind a
  server. v1 reuses it: wdbg prints `wdbg> ` before every read even off a
  tty (lib/line_edit.w's plain path), so "everything up to the next
  prompt" is exactly one command's answer. `debugger/` does not change.
  The browser parses the text (locations `func (file:line)`, `#N` frames,
  `breakpoint N at ...`, `name = value` rows).
- **HTTP API** (header comment of tools/wdbg_web.w has the full list):
  `/api/state`, `/api/cmd` (one command line, bounded wait for the next
  prompt), `/api/poll` (output while the program runs), `/api/inspect`
  (`l`, `bt`, `i locals`, `i args`, `i b`, `i w` in one round trip),
  `/api/source` (only files `i files` lists), `/api/restart`,
  `/api/core`. It is plain JSON over HTTP, so curl and scripts can use it
  too; this is the natural base for the deferred `w-debug-mcp`/DAP
  wrapper in `docs/projects/ai_tooling_next_steps.md`.
- **TLS.** libs/standard/net/selfsigned.w mints an ECDSA P-256 key and a
  self-signed v3 certificate (SAN `localhost` + the bound IPv4) at
  startup, handed to tls.w through `tls_server_config.test_cert_pem` /
  `test_key_pem` so the key never touches disk. `--cert/--key` serve a
  real pair; `--http` drops TLS.
- **Access control.** 127.0.0.1 by default. A random 128-bit code is in
  the printed URL; every request must present it (`?code=`, the
  `X-Wdbg-Code` header, or the `wdbg_code` cookie the server sets:
  HttpOnly, SameSite=Strict, Secure under https). Commands are one line
  per request, so a body cannot smuggle a second command. Static paths
  are restricted to a safe character set without `..`.
- **Concurrency.** http_server.w's accept loop serves one connection to
  completion before accepting the next; a browser's speculative and
  idle keep-alive connections would wedge it. wdbg_web keeps the
  ServerContext (bind, TLS config, routing types) but runs its own
  poll(2) loop over the listener, every connection and wdbg's pipes, and
  serves one request from whichever connection is readable. TLS
  handshakes still block, but only after the client has started one.
  The pure-W handshake costs a few seconds of CPU, so keep-alive matters:
  a page load is typically one or two handshakes.

## Not in v1 / next steps

- **Pause a running program.** wdbg has no asynchronous interrupt (a
  SIGINT kills it; an external SIGTRAP lands in the single-step path).
  The page offers Restart instead.
- **WebSocket push.** Output is polled while the program runs. A
  WebSocket (libs/standard/web/websocket.w) would push it, but a
  long-lived socket needs the server loop to multiplex frames, not just
  requests.
- **A W/wasm UI.** The page is plain HTML/JS. The wasm + UI framework
  path (tools/web/) could replace it on top of the same API.
- **Structured wdbg output.** Parsing text is adequate for the panes;
  a `--json` mode in wdbg itself would remove the guessing and serve the
  MCP/DAP wrapper as well.
- **Attach mode** (`wdbg --attach pid`) is not exposed yet.
