# Semantic index: `windex` / `w-index-mcp`

Status: **implemented** — `tools/index/w_index.w` (built as `bin/windex`,
`make windex`) and `tools/mcp/w_index_mcp.w` (built as `bin/wimcp`,
`make wimcp`), the two deferred items from
[reardan/w#25](https://github.com/reardan/w/issues/25) named "semantic
indexer" and "`w-index-mcp`". `bin/wlsp` (`docs/projects/lsp.md`) uses
`windex` to add hover, find-references, and rename to the LSP MVP.

## Why this shape

`w symbols --json` (`compiler/compiler.w`) only ever recorded
**declarations** — the compiler has no persistent record of where a
symbol is *used*: `sym_get_value()` (`compiler/symbol_table.w`) looks a
name up and emits code for it without recording the reference site, and
there is no importer→imported graph (imports are resolved and discarded
per file via `compile_save`, see `grammar/import_statement.w`). Building
true usage-site tracking into the single-pass compiler would be a much
larger change with its own self-host-fixpoint risk.

Instead, `windex` compiles the given entry file(s) via
`wv2 symbols --json` for the authoritative declaration set (name, kind,
type, file, line, column — and, since this project, a `fields` array for
struct/union declarations, see below), then **textually scans** every
file that declaration set touches for identifier occurrences, the same
word-boundary technique `bin/wlsp` already used for go-to-definition
(`lsp_identifier_at`). A reference is "real" when its text matches a
known declared name; it is not scope- or type-checked. Caller/callee
resolution goes one step further: a function's body span is
approximated from W's tab-indentation rule (the next non-blank,
column-0 line ends the block), not true block/scope analysis.

This is an honest, MVP-shaped tradeoff, not a hidden limitation:
everywhere in the codebase where indentation gets used as a boundary
heuristic, it composes with W's actual grammar rule (blocks are
tab-indented, so the next un-indented line really does end every
enclosing block), and it is stated in every affected doc rather than
discovered by a caller.

## `w symbols --json`'s new `fields` array

`compiler/compiler.w`'s `symbols_dump` walks the type table (structs,
unions, enums, aliases) as well as the symbol table; struct/union
records now also carry the field list already available from
`compiler/type_table.w` (`type_num_args`, `type_get_field_name_at`,
`type_get_field_type_at`, `type_get_field_offset_at`):

```json
{"name": "sym_fixture_point", "kind": "struct", "type": "sym_fixture_point", "file": "tests/symbols_fixture.w", "line": 5, "column": 8, "arch": "x86", "fields": [{"name": "x", "type": "int", "offset": 0}, {"name": "y", "type": "int", "offset": 4}]}
```

Field declarations carry no line/column in the type table (only the
struct/union's own name does — see `type_set_decl_location` calls in
`grammar/struct_declaration.w` / `grammar/union_declaration.w`), so
`fields` entries have no location. `symbols_test` (`Makefile`,
`build.json`) still asserts the pre-existing `name`/`kind`/`type`
substrings byte-for-byte; `fields` is a pure addition.

## `windex` CLI

```sh
windex symbol     <name> <file...>   # find_symbol: matching declaration record(s)
windex type       <name> <file...>   # get_type: same data as `symbol`, separate for query intent
windex struct     <name> <file...>   # get_struct_fields: one record per field
windex references <name> <file...>   # find_references: every occurrence, is_declaration flagged
windex callers    <name> <file...>   # every call site's enclosing function
windex callees    <name> <file...>   # every call site inside name's own body
windex imports    <file>             # imports_for: textual re-parse of 'import a.b[.*][ as alias]'
```

`<file...>` are the entry file(s) compiled via `wv2 symbols --json` —
the same file(s) an agent would pass to `w symbols` today. Every other
file in that compile's transitive closure (declarations' `file` fields)
is in scope for reference/caller/callee scanning; files outside that
closure are invisible to the query, same tradeoff `w check`/`w symbols`
already make (whole program reachable from what you point at, nothing
more). Output is always NDJSON, one record per line, no human mode —
this is an agent/editor-facing tool the way `bin/wlsp` and `bin/wmcp`
already are, not a terminal-first one like `w check`.

## `w-index-mcp` tools

`tools/mcp/w_index_mcp.w` (`make wimcp` → `bin/wimcp`, same JSON-RPC 2.0
stdio shape as `w-toolchain-mcp`): `find_symbol`, `find_references`,
`get_type`, `get_struct_fields`, `callers`, `callees` take
`{name, files}`; `imports_for` takes `{file}`;
`changed_file_test_targets` takes `{files}` and delegates to
`bin/wtest changed` (same tool the issue's `w-index-mcp` spec names,
kept alongside the semantic queries rather than only on
`w-toolchain-mcp`, since an agent already holding index results for a
changed file will often want its test targets next). Every tool other
than `imports_for`/`changed_file_test_targets` shells out to `windex`
and returns `{exit_code, stdout, stderr, records}` — `records` is the
parsed NDJSON array.

## Known limitations

- **Textual, not scoped.** A local variable and an unrelated global
  sharing a name are conflated; shadowed identifiers are indistinguishable.
- **Function spans are indentation-approximated**, not scope-derived
  (see "Why this shape" above); a stray column-0 comment inside what
  should be a nested block would truncate a span early.
- **`callers`/`callees` cost is O(references × declarations)** in the
  current implementation (a linear scan per candidate) — fine for the
  CLI's one-shot-per-query usage, not intended for a hot loop.
- **x86 only**, matching `bin/wlsp`: `windex` shells to plain
  `./bin/wv2 symbols --json` (no `x64` support yet).

## Testing

- `symbols_test` (`Makefile`/`build.json`) covers the `fields` array
  addition via `tests/symbols_fixture.w`'s `sym_fixture_point`.
- `index_test` (`tools/index/index_test.w`, driving the real
  `bin/windex` binary over `tests/index_fixture.w` and the existing
  `tests/import_alias_warning_fixture.w`) covers every subcommand.
- `index_mcp_test` (`tools/mcp/index_mcp_test.w`) drives `bin/wimcp` over
  stdio: initialize, `tools/list`, and one call per tool.
- `lsp_test` (`tools/lsp/lsp_test.w`) extends its existing coverage with
  hover, references (with and without `includeDeclaration`), and rename
  assertions against `tests/index_fixture.w`.
