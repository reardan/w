# W LSP server (MVP)

Status: **MVP implemented, hover/references/rename added** —
`tools/lsp/w_lsp.w`, built as `bin/wlsp` (`./wbuild wlsp`), tested by
`./wbuild lsp_test` (part of `./wbuild tests`).

`wlsp` is a stdio Language Server Protocol server written in W. It is a
thin long-running adapter over the compiler's machine-readable
subcommands: diagnostics come from `w check --json`, go-to-definition and
hover from `w symbols --json`, and find-references/rename from the
semantic index (`bin/windex`, `docs/projects/semantic_index.md`). There
is no in-process compiler API — every request shells out to
`./bin/wv2`/`./bin/windex`, which keeps the server dependency-free and
always consistent with the compiler and index the repo builds.

## Architecture

The wire and JSON layers are the same ones the MCP servers
(`tools/mcp/w_toolchain_mcp.w`, `tools/mcp/w_index_mcp.w`) use:

- `lib/framing.w` — Content-Length framing over stdin/stdout (the LSP
  wire format).
- `structures/json.w` — request/response trees (`json_parse` /
  `json_stringify`).
- `lib/process.w` — `process_run` to shell out to `./bin/wv2` (diagnostics,
  definition, hover) and `./bin/windex` (references, rename) with a
  timeout.

Dispatch is a hand-rolled `strcmp` chain on the JSON-RPC `method`, like
the MCP server; the generic `lib/json_rpc.w` dispatch table is not used
because LSP mixes requests with notifications and has its own lifecycle.

Like `bin/wmcp`, the server chdirs to the repo root when launched via a
path ending in `bin/`, so `./bin/wv2` resolves regardless of the
client's working directory.

## Supported methods

- `initialize` — advertises full-text document sync (`change: 1`,
  `openClose`, `save`), `definitionProvider`, `hoverProvider`,
  `referencesProvider`, and `renameProvider`.
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
- `textDocument/hover` — same identifier extraction and `symbols --json`
  call as definition; renders the best-matching record (preferring a
  struct/union/enum/function/alias record over a same-named plain
  "object" one — see `tests/symbols_fixture.w`'s `sym_fixture_point`,
  dumped once as each) as `kind name: type`, plus
  `{ field: type, ... }` when the record carries a `fields` array.
- `textDocument/references` — runs `./bin/windex references <name> <path>`
  (`docs/projects/semantic_index.md`) and returns every occurrence as a
  `Location` array, honoring `context.includeDeclaration` (default
  `true`).
- `textDocument/rename` — runs the same `windex references` query and
  returns a `WorkspaceEdit` (`changes: {uri: TextEdit[]}`) replacing
  every occurrence's range with `newName`; an `-32803` error when the
  position resolves to no symbol or `windex` fails.

Record positions are converted from the compiler's 1-based line/column
to 0-based LSP positions; a diagnostic's range spans the reported
`token`, a definition/hover/reference/rename range spans the symbol name.

## Limitations (by design, for the MVP)

- **Whole-file, on-save checking.** Diagnostics reflect the file on
  disk, not unsaved buffer contents (`w check` has no stdin mode). Each
  check is a full compile to `/dev/null` — fast for this compiler, but
  not incremental.
- **Single error.** The compiler stops at the first `error()`, so at
  most one error record appears per check (warnings before it all
  surface).
- **Definition/hover cover globals only.** `w symbols --json` dumps global
  symbols, functions, enum constants, and user-declared types with their
  declaration sites. Locals and parameters are not in the dump, so the
  server cannot resolve them; identifiers with several declarations
  return every match (hover renders the richest one, see above).
- **References/rename are textual**, not scope-checked — inherited
  directly from `windex`'s contract; see
  `docs/projects/semantic_index.md`'s "Known limitations" (in particular
  the `main` special case, which affects caller/callee resolution, not
  references/rename directly).
- **x86 only.** The server itself is built for x86 (the structures/
  container stack has known x64 bugs), and it invokes plain
  `wv2 check`/`wv2 symbols`/`windex` — x64-specific diagnostics are out
  of scope.
- **No completion or semantic tokens** — not needed by the check/
  navigate/rename loop this MVP targets; revisit with evidence of need.

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

Build the server first: `./wbuild wlsp` (which bootstraps `bin/wv2` if
needed via `./wbuild build`).

## Testing

`./wbuild lsp_test` compiles `tools/lsp/lsp_test.w` and drives the real
binary over piped stdio (the `mcp_test` pattern): initialize handshake,
didOpen of `tests/warning_fixture.w` asserting the published warning
set, didClose clearing it, didOpen of a clean file publishing an empty
set, `textDocument/definition` on a `sym_fixture_add` call site landing
on its declaration in `tests/symbols_fixture.w`, a null result for a
non-identifier position, `textDocument/hover` on a call site in
`tests/index_fixture.w`, `textDocument/references` with and without
`includeDeclaration`, `textDocument/rename` producing a three-edit
`WorkspaceEdit`, and a clean shutdown/exit.

## Natural next steps

- Re-check on `didChange` by teaching `w check` to read from stdin (or
  writing the buffer to a temp file), for as-you-type diagnostics.
- Document symbols (`textDocument/documentSymbol`) — the data is already
  in `w symbols --json`; only the response shape is new.
- Locals/parameters still aren't in `w symbols --json`, so definition,
  hover, references, and rename all stay global-declarations-only.
