# W LSP server (MVP)

Status: **MVP implemented** — `tools/lsp/w_lsp.w`, built as `bin/wlsp`
(`make wlsp`), tested by `make lsp_test` (part of `make tests`).

`wlsp` is a stdio Language Server Protocol server written in W. It is a
thin long-running adapter over the compiler's machine-readable
subcommands: diagnostics come from `w check --json` and go-to-definition
from `w symbols --json`. There is no in-process compiler API — every
request shells out to `./bin/wv2`, which keeps the server dependency-free
and always consistent with the compiler the repo builds.

## Architecture

The wire and JSON layers are the same ones the MCP server
(`tools/mcp/w_toolchain_mcp.w`) uses:

- `lib/framing.w` — Content-Length framing over stdin/stdout (the LSP
  wire format).
- `structures/json.w` — request/response trees (`json_parse` /
  `json_stringify`).
- `lib/process.w` — `process_run` to shell out to `./bin/wv2` with a
  timeout.

Dispatch is a hand-rolled `strcmp` chain on the JSON-RPC `method`, like
the MCP server; the generic `lib/json_rpc.w` dispatch table is not used
because LSP mixes requests with notifications and has its own lifecycle.

Like `bin/wmcp`, the server chdirs to the repo root when launched via a
path ending in `bin/`, so `./bin/wv2` resolves regardless of the
client's working directory.

## Supported methods

- `initialize` — advertises full-text document sync (`change: 1`,
  `openClose`, `save`) and `definitionProvider`.
- `initialized`, unknown notifications (including `$/…`) — ignored.
- `shutdown` / `exit` — the usual lifecycle; EOF on stdin also exits.
- `textDocument/didOpen`, `textDocument/didSave` — run
  `./bin/wv2 check --json <path>` against the file on disk, group the
  NDJSON records by file (a check can surface diagnostics in imported
  files), and send one `textDocument/publishDiagnostics` notification
  per file. URIs that got diagnostics on the previous check of the same
  document but not on this one are cleared with an empty array.
- `textDocument/didChange` — stores the full text (used for identifier
  extraction); no re-check, since the compiler reads from disk.
- `textDocument/didClose` — drops the stored text and clears every URI
  the document's last check published.
- `textDocument/definition` — extracts the `[A-Za-z0-9_]` identifier at
  the requested position from the stored text (or the file on disk),
  runs `./bin/wv2 symbols --json <path>`, and returns the matching
  declaration records as an array of `Location`s (or `null`).

Record positions are converted from the compiler's 1-based line/column
to 0-based LSP positions; a diagnostic's range spans the reported
`token`, a definition's range spans the symbol name.

## Limitations (by design, for the MVP)

- **Whole-file, on-save checking.** Diagnostics reflect the file on
  disk, not unsaved buffer contents (`w check` has no stdin mode). Each
  check is a full compile to `/dev/null` — fast for this compiler, but
  not incremental.
- **Single error.** The compiler stops at the first `error()`, so at
  most one error record appears per check (warnings before it all
  surface).
- **Definition covers globals only.** `w symbols --json` dumps global
  symbols, functions, enum constants, and user-declared types with their
  declaration sites. Locals and parameters are not in the dump, so the
  server cannot resolve them; identifiers with several declarations
  return every match.
- **x86 only.** The server itself is built for x86 (the structures/
  container stack has known x64 bugs), and it invokes plain
  `wv2 check` — x64-specific diagnostics are out of scope.
- **No references, hover, rename, or completion** — those need the
  semantic indexer (see `docs/projects/ai_tooling.md`, "Out of scope").

## Editor wiring

Any LSP client that can launch a stdio server works. Examples:

Neovim (0.11+):

```lua
vim.lsp.config['wlsp'] = {
  cmd = { '/path/to/w/bin/wlsp' },
  filetypes = { 'w' },
  root_markers = { 'w.w', '.git' },
}
vim.lsp.enable('wlsp')
```

VS Code (via a minimal extension or a generic LSP client such as
"Generic LSP Client"): point the server command at
`/path/to/w/bin/wlsp` for language id `w`.

Build the server first: `make wlsp` (which bootstraps `bin/wv2` if
needed via `make build`).

## Testing

`make lsp_test` compiles `tools/lsp/lsp_test.w` and drives the real
binary over piped stdio (the `mcp_test` pattern): initialize handshake,
didOpen of `tests/warning_fixture.w` asserting the published warning
set, didClose clearing it, didOpen of a clean file publishing an empty
set, `textDocument/definition` on a `sym_fixture_add` call site landing
on its declaration in `tests/symbols_fixture.w`, a null result for a
non-identifier position, and a clean shutdown/exit.

## Natural next steps

- Re-check on `didChange` by teaching `w check` to read from stdin (or
  writing the buffer to a temp file), for as-you-type diagnostics.
- Document symbols (`textDocument/documentSymbol`) — the data is already
  in `w symbols --json`; only the response shape is new.
- Locals/parameters and references need the semantic indexer tracked in
  `docs/projects/ai_tooling.md`.
