# Lint rules and `--fix`

`w check --lint file.w...` adds opt-in lint rules to the compiler's
always-on warnings. `w check --fix file.w...` rewrites the named files'
mechanically fixable whitespace issues in place before checking them.
Both live in `compiler/lint.w`; `./wbuild lint_test` freezes the
behavior and the message text.

```sh
./bin/wv2 check --lint --quiet file.w           # report
./bin/wv2 check --fix --quiet file.w            # repair whitespace, then check
./bin/wv2 check --lint --fix --json file.w      # both, NDJSON diagnostics
./bin/wv2 check --lint --line-length=100 file.w # tighter width limit (0 = off)
```

## Scope

- Only the files named on the command line are linted, never their
  imports: a library's findings are not something the caller can fix.
  A compiler-internal file (`w check --lint compiler/lint.w`) is linted
  while `w.w` compiles in its place.
- Every finding is an ordinary warning: `--strict` counts it, `--json`
  emits it as an NDJSON record, and the message ends with the rule name
  in brackets (`... is never used [unused-local]`).
- A source line containing the word `nolint` is exempt from every lint
  rule, and `--fix` leaves it untouched.

## Rules

| Rule | What it flags | `--fix` |
|---|---|---|
| `unused-local` | a typed or `:=` local that nothing references (names starting with `_` and loop variables are exempt) | no |
| `unreachable` | the first statement after `return`, `break`, `continue` or `goto` in the same block (a `label:` resets it) | no |
| `shadow` | a typed local that hides a live local or parameter of the same name (loop variables are exempt, since they stay bound after their loop) | no |
| `assign-in-condition` | `=` as the whole condition of an `if`/`while`; `((x = f()))` and `(x = f()) != 0` stay quiet | no |
| `self-assign` | `x = x` | no |
| `duplicate-import` | a plain `import` of a module the same file already imported | no |
| `trailing-whitespace` | spaces or tabs at the end of a line (not inside a multi-line string) | yes |
| `crlf` | CRLF line endings (reported once per file) | yes |
| `blank-lines` | more than two consecutive blank lines | yes |
| `leading-blank-lines` | blank lines at the start of the file | yes |
| `trailing-blank-lines` | blank lines at the end of the file | yes |
| `line-too-long` | a line wider than `--line-length` columns (default 120, tabs count as 4) | no |
| `bidi-control` | a bidi embedding, override or isolate control (U+202A-U+202E, U+2066-U+2069) or U+061C anywhere in the file, comments and string literals included: the Trojan Source reordering (CVE-2021-42574) | no |
| `mixed-script` | an identifier mixing Latin, Greek and Cyrillic letters (`nаme` with a Cyrillic `а`) | no |
| `confusable` | an identifier that differs from an earlier name in the same file only by Greek/Cyrillic letters that look Latin (`рath` vs `path`) | no |

The three Unicode rules (issue #460) scan the raw text like the
whitespace rules. The lookalike table in `compiler/lint.w`
(`lint_confusable_table`) covers the practical Greek and Cyrillic
twins of Latin letters, not the full Unicode confusables data, and
`confusable` compares names across the whole file rather than per
scope. Identifiers written entirely in one non-Latin script with no
Latin twin (`данные`, `ζωή`) never trip either rule.

`--fix` also repairs the two always-on style warnings: a line indented
with spaces is re-indented with one tab per four columns (a leftover of
fewer than four columns stays as spaces after the tabs, and an indent
narrower than one tab is left alone), and a missing final newline is
added. The note `fixed N issue(s) in '<file>'` goes to stderr unless
`--quiet` is given.

The existing `--imports` and `--bool-ops` checks compose with `--lint`
but are not part of it: both audit the whole import closure, and the
tree relies on transitive imports by design.

## JSON output

`--json` writes one NDJSON record per diagnostic on stdout, lint
findings and ordinary compiler diagnostics alike
(`docs/projects/ai_tooling.md` "Output format" has the original seven
fields). AST completion plan unit C3.2 appended four more; the
human-readable output is byte-identical with or without them.

```json
{"file": "/src/a.w", "line": 5, "column": 9, "severity": "error", "message": "Cannot find symbol: 'countr'", "token": "countr", "arch": "x86", "code": "W0001", "end_line": 5, "end_column": 15, "help": "did you mean 'counter'?", "related": [{"file": "/src/a.w", "line": 1, "column": 5, "message": "'counter' is declared here"}]}
```

- `code`: a stable identifier for the message's shape, `W` plus four
  digits. The table is `diag_code_table()` at the end of
  `compiler/diagnostics.w`: one row per distinct message, written as the
  frozen message text (without the `warning: ` label) with `@` for each
  variable part. A message takes the code of the matching row with the
  most literal characters, so a specific row beats a general one
  regardless of table order; a message no row matches gets `W0000`.
  The table is append-only. A new diagnostic takes the next free number
  at the end; a removed one keeps its row; a reworded one keeps its code
  and updates its pattern. Codes are computed from the final message
  text inside the `--json` emitter, so call sites carry no code and the
  human output never sees one.
- `end_line`, `end_column`: the end of the reported token's span,
  exclusive (just past its last character), 1-based and counted in
  codepoints like `column`. The token's text is the raw source bytes
  the tokenizer consumed, so the end is the start advanced over it (a
  multi-line string literal moves `end_line`). When the source can be
  read back (a regular file) the token is first checked against the
  bytes at the start position, and a diagnostic whose token is not there
  gets a zero-width span, `end == start`: lint findings (which report a
  position, not a token), end-of-file warnings, `<command-line>`
  records (`0, 0`). Hosts without `statx` (darwin, win64, wasm compilers)
  trust the token text.
- `related`: always present, usually `[]`. Each entry is
  `{file, line, column, message}` for a declaration the diagnostic is
  about. Today:

  | Diagnostic | Code | Related note |
  |---|---|---|
  | `Cannot find symbol: '...'` with a did-you-mean | W0001 | `'name' is declared here` (the suggestion) |
  | `Cannot find symbol: '...': declared later in this file ...` | W0001 | `'name' is defined here` |
  | `symbol redefined: '...'` | W0002 | `previous definition of 'name' is here` |
  | `return type mismatch: ...` | W0003 | `function 'name' is declared here` |
  | `function '...' argument N type mismatch: ...` | W0004 | `function 'name' is declared here` |
  | `':=' redeclares '...'` | W0008 | `'name' is declared here` |
  | `generic '...' redefined` | W0009 | `previous definition of generic 'name' is here` |

  Other type mismatches (assignment, initialization, ...) have no
  single declaration to point at and keep `[]`. Arity warnings (W0005,
  W0006) keep `[]` too: the AST front end replays them without the
  callee's symbol, and both front ends must emit identical records
  (`ast_expression_test` compares them).

The lint rules' codes:

| Rule | Code | Rule | Code |
|---|---|---|---|
| `unused-local` | W0091 | `crlf` | W0098 |
| `unreachable` | W0092 | `blank-lines` | W0099 |
| `shadow` | W0093 | `leading-blank-lines` | W0100 |
| `assign-in-condition` | W0094 | `trailing-blank-lines` | W0101 |
| `self-assign` | W0095 | `line-too-long` | W0102 |
| `duplicate-import` | W0096 | `bidi-control` | W0103 |
| `trailing-whitespace` | W0097 | `mixed-script` | W0104 |
| | | `confusable` | W0105 |

`ast_diagnostic_codes_test` pins the code, span and note of each row of
the first table. The redefinition, `:=` and mismatch cases also run
with `--ast-required`, and "Cannot find symbol" with
`--ast-full-expressions` (`--ast-required` reports an unknown name as
its own unsupported-expression error, W0395).

## How the semantic rules hook in

The compiler is single-pass with no AST, so each rule rides an existing
parse point:

- `unused-local`: `sym_index_lint` (compiler/symbol_table.w) holds one
  byte per symbol-index entry. The declaration paths mark a tracked
  local, `sym_lookup` marks it used, and each block exit
  (`grammar/statement.w`) reports the tracked locals it is about to
  truncate that are still unused.
- `unreachable`: `statement()` publishes whether the statement it just
  parsed jumped (`lint_last_stmt_jumps`), and both block loops check it
  before the next statement.
- `shadow`: the new record's same-name chain link (`sym_index_prev`)
  already points at the binding it hides.
- `assign-in-condition`: the if/while condition records its first token
  and nesting depth, so `expression()`'s `=` arm can tell whether it is
  the whole condition or the inside of a `(...)` group spanning it.
- `self-assign`: `token_serial` (compiler/tokenizer.w) counts
  `get_token()` calls, so `expression()` knows when each side of `=` was
  a single token.

## Gaps

- No unused-import, unused-parameter or unused-function rule yet. An
  unused import needs to know which module each resolved symbol came
  from and to treat side-effect imports (test registration, operator
  overloads) as uses; parameters are often unused on purpose in
  callbacks.
- `unused-local` counts any reference, so a local that is only ever
  assigned to still counts as used.
- `--fix` covers whitespace only. A rewriting formatter (issue #25's
  `wfmt`) still needs a lossless token stream the single-pass tokenizer
  does not keep.
- `unreachable` does not know about calls that never return (`exit`,
  `error`), or an `if`/`else` whose branches all return.
