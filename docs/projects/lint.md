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

`--fix` also repairs the two always-on style warnings: a line indented
with spaces is re-indented with one tab per four columns (a leftover of
fewer than four columns stays as spaces after the tabs, and an indent
narrower than one tab is left alone), and a missing final newline is
added. The note `fixed N issue(s) in '<file>'` goes to stderr unless
`--quiet` is given.

The existing `--imports` and `--bool-ops` checks compose with `--lint`
but are not part of it: both audit the whole import closure, and the
tree relies on transitive imports by design.

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
