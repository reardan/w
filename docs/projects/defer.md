# `defer` statements

Go-style `defer` for W (v1). Implemented in `grammar/defer.w`, parsed in
`grammar/statement.w`, tested by `tests/defer_test.w` and the
`tests/defer_*_error_fixture.w` compile-error fixtures (`./wbuild defer_test`,
`./wbuild defer_64_test`).

```w
int first_byte_of(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0 - 1
	defer close(fd)
	# ... every return below runs close(fd) first
```

## Semantics (v1, deliberate)

- `defer <simple-statement>` defers a single expression statement,
  typically a call. There is no block form.
- Deferred statements run in **LIFO** order at **every function exit**:
  before each `return` and at the function's fall-through end.
- Defers are **function-scoped**, not block-scoped (like Go): a defer
  registered inside an `if` still runs at function exit, on every path
  that reaches an exit after the registration... with one caveat below.
- **Exit-time evaluation**: the deferred expression is re-parsed and
  re-emitted at each exit point, so it observes mutations that happen
  after the `defer` line. `int x = 1` / `defer report(x)` / `x = 2` /
  `return` runs `report(2)`. This is *unlike Go*, which captures argument
  values at defer time. Capturing would need a runtime thunk mechanism
  the single-pass compiler does not have; the trade-off is documented and
  asserted by `test_defer_evaluates_at_exit_time`.
- Caveat of the single-pass design: emission happens at the exit points
  the parser reaches *after* the registration. A `return` placed
  textually before a `defer` in the same function does not run it (the
  registry did not contain it yet when that `return` was compiled). This
  matches "defers registered on the path actually executed" for
  straight-line code, which is the useful interpretation.
- `return expr` evaluates the return expression **first**, saves it
  (push/pop of `eax` around the deferred code; struct-by-value returns
  are already copied into the caller's buffer by
  `copy_struct_return_value` before the defers run), then runs the
  defers, then unwinds and returns. Struct-by-value returns therefore
  work with `defer`.

## Restrictions (v1)

Enforced at registration with specific errors (see the fixtures):

- The deferred statement must be a **simple expression statement**:
  declarations (`defer int x = 1`), control flow (`defer return`,
  `defer if ...`, `defer break`, ...), blocks and nested `defer` are
  compile errors. This keeps `stack_pos` bookkeeping balanced across the
  re-parse at each exit point.
- `defer` inside a **generator body** is rejected: a generator's exits
  (`yield` switches, `__w_gen_return`) do not run a normal `ret` path.
- `defer` at **top level** (outside a function) is rejected.
- A deferred statement that starts with a type name is parsed as a
  declaration attempt and rejected; in the rare case of a function
  sharing its name with a struct type, wrap the call
  (`defer (point(1))` is not supported — rename instead).
- A defer that references a **block-local** variable and outlives its
  block fails at compile time ("Cannot find symbol") when a later exit
  point re-parses it outside the block: without capture, the local no
  longer exists there. Reference function-scope locals (or globals)
  from deferred statements.

## Implementation: span capture and re-parse

The compiler is single-pass with no AST, so a deferred statement cannot
be stored as a tree and replayed. Instead `defer` reuses the generics
machinery's span-capture pattern (`docs/projects/generics.md`,
`grammar/generic.w`):

- **Registration** (`defer_register`): record the current file path and
  `token_start_offset` (plus line/column for diagnostics) in a small
  per-function registry (`defer_spans` / `defer_count`, reset by
  `function_definition` via `defer_reset`), then skip tokens to the end
  of the line without emitting code.
- **Emission** (`defer_emit_all`): at each exit point, walk the registry
  LIFO. For each entry: save the complete tokenizer state
  (`generic_reparse_save`), re-open the recorded file on a fresh fd,
  `seek()` to the span, prime the tokenizer, and parse the statement
  with the ordinary `expression()` machinery — which emits its machine
  code inline at the exit point. Then restore the outer tokenizer state
  (`generic_reparse_restore`) and continue the outer parse as if nothing
  happened.
- **Exit points**: the `return` handler in `grammar/statement.w` calls
  `defer_emit_returning()` (which saves `eax` around the deferred code);
  the fall-through end is the function body block's close, found via the
  `defer_function_body_pending` flag `function_definition` arms and the
  block handler in `statement()` consumes — the defers must be emitted
  *before* the body block pops its locals, so re-parsed statements can
  still reference them.
- **Local addressing just works**: locals are addressed `esp`-relative
  from the live `stack_pos` at emission time (`sym_get_value` in
  `compiler/symbol_table.w`), so a deferred reference to a local resolves
  correctly even when the exit point sits behind additional local
  declarations (asserted by `test_defer_local_after_more_locals`).
- The REPL (`repl.w`) accepts `defer` in entries (registered statements
  run at the entry function's end) and checkpoints/restores
  `defer_count` on compile-error rollback, like the loop globals; the
  debugger's expression evaluator (`debugger/eval.w`) resets the
  registry before compiling each snippet.

## Possible future work

- Defer-time argument capture (Go semantics) via a runtime thunk list.
- Block-scoped defers or a `defer:` block form.
- Running defers on `exit()`/panic paths.
