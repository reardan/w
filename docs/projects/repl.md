# REPL v1 Design: multi-line entries, persistence, and `repl file.w`

Status: **implemented** (see `repl.w`, the `repl_test` build target and
the notes at the bottom). Goal: make the REPL feel like Python's — you can
define functions and structs at the prompt, values survive between
entries, bare expressions echo their result, and `./bin/repl file.w` runs
a program and then drops into a prompt with all of its symbols live (the
`python -i` workflow).

## Current state (verified against `repl.w` at head)

Each entry is one line, staged to `/tmp/w_repl_line.w`, compiled as the
body of a fresh anonymous function `__repl_N` into an RWX mmap buffer,
and called immediately. `lib/lib.w` and `lib/assert.w` are compiled into
the same buffer at startup. Compile errors long-jump back to the prompt
(`repl_setjmp`/`repl_longjmp`) and a checkpoint rolls back `codepos`,
`table_pos`, `stack_pos`, and the loop-emission state.

Observed limitations, each reproduced by piping input into `./bin/repl`:

- **No multi-line input.** `int add(int a, int b):` fails immediately
  with `';' expected, found '('`: the reader hands one line at a time to
  the compiler, and the line is parsed as a *statement*
  (`variable_declaration()` sees `int add`, then chokes on `(`). There
  is no way to enter a function, struct, or an indented `if`/`while`/
  `for` body.
- **Nothing persists.** `int x = 5` compiles as a *local* of `__repl_N`;
  its stack slot dies when the call returns and `repl_compile_line`
  rolls `table_pos` back, so the next entry gets
  `Cannot find symbol: 'x'`. There is no way to declare a global, import
  a module, or define anything from the prompt.
- **No expression echo.** `1 + 2` compiles, runs, and prints nothing.
- **No file loading.** `main(int argc, int argv)` ignores its arguments.
- **Startup noise.** `struct_declaration=1, current_symbol=...` prints
  unconditionally from `program()` (it also pollutes every ordinary
  compile's stderr).

The one-buffer/one-symbol-table model is the right foundation — wdbg
already proves a whole program can be compiled into the buffer and run
in-process — so this plan extends the existing design rather than
replacing it.

## A. Multi-line entries (Python-style continuation)

Keep the "stage the entry to a temp file and compile it" model; only the
*reader* changes. `repl_read_line` stays; a new `repl_read_entry`
accumulates lines into one `string` buffer:

- Prompt `w> ` for the first line, `.. ` for continuations.
- **Continuation triggers** (checked by a small textual scanner that
  tracks string/char-literal state, `#` and `/* */` comment state, and
  `(`/`[`/`{` depth across the entry so far):
  - the line's last significant character is `:` or `{`  → block mode
  - bracket depth > 0, or an unterminated `/* */` comment → keep reading
- **Block mode ends on an empty line** (Python's rule). Bracket mode
  ends as soon as the depth returns to zero and the line does not open a
  block. A lone complete line is executed immediately, exactly as today.
- Indentation stays real tabs, as everywhere in W. The banner should say
  so, since terminals make tabs easy to type but easy to forget.

Alternative considered and rejected: feeding the tokenizer from stdin
and pausing the parser when it runs out of input. The compiler is
single-pass and emits code *while* parsing; suspending it mid-statement
would need coroutine machinery for no user-visible gain. Python itself
decides "incomplete vs. complete" with a source-text heuristic
(`codeop`), which is what the scanner above is.

## B. Top-level definitions: functions, structs, imports

Once an entry can span lines, `repl_compile_line` (rename:
`repl_compile_entry`) grows a dispatcher, mirroring `program()`:

1. While the token is `import` / `struct` / `c_lib` / `extern`, call the
   existing `import_statement()` / `struct_declaration()` /
   `extern_statement()` parsers. These only define things; nothing runs.
2. If the token is a type name (`type_lookup(token) >= 0`), parse
   `type_name()` and the identifier, then peek:
   - `(` → **function definition**. Extract the parameter-list + body
     branch of `program()` into a shared `function_definition(symbol)`
     helper and call it from both places, so the prompt and file compiles
     stay one code path. This is the only compiler refactor the feature
     needs and it is mechanical.
   - anything else → **persistent variable declaration** (section C).
3. Otherwise → statement path: compile the whole entry as the body of
   `__repl_N` and call it, as today. Multi-line `if`/`while`/`for`
   bodies now just work, since the entry file contains the whole block.

Definitions land in the same buffer and symbol/type tables as
everything else, so they are immediately callable — that part falls out
of the existing model for free.

**Redefinition follows Python's rebinding model.** `sym_define_global`
errors with `symbol redefined` on a 'D' symbol, so the REPL path instead
declares a *fresh* symbol for a repeated name. `sym_lookup` scans the
whole table and keeps the **last** match, so the new definition shadows
the old one naturally; the old code/storage stays orphaned in the buffer
(a few dead bytes, fine for an interactive session). One documented
difference from Python: calls compiled *before* the redefinition keep
their old target, because calls bind addresses at compile time, not per
lookup.

## C. Persistent variables ("saves old values")

Top-level declarations at the prompt become **globals with storage in
the RWX buffer**, not locals of `__repl_N`:

- For `type name` or `type name = expr` at entry top level:
  1. Declare the symbol and define it at the current `codepos`, then
     `emit_zeros(size)` — `word_size` normally, the rounded struct size
     for by-value struct types (one word is all `program()` gives
     globals today; the REPL should do the same or better). The data
     words sit in front of the entry's function code and are never
     executed, because `__repl_N` is only entered by `call`.
  2. If there is an `= expr` initializer, compile the assignment
     `name = expr` as the first statement *inside* `__repl_N`, so
     arbitrary runtime expressions work as initializers (the assignment
     path in `expression()` already stores through the global with the
     correct width).
- Later entries resolve `x` through the symbol table as a defined
  global: reads, assignments, and `&x` all work unchanged.
- Declarations *inside* a function or block defined at the prompt stay
  locals, unchanged.

This is deliberately not "persist locals between entries" (the
`docs/todo.txt` idea): keeping a live stack frame across entries fights
the calling convention and the rollback machinery, while promoting
prompt-level declarations to globals matches what a Python user actually
expects (`x = 5` at the prompt is a module-level binding, not a local).

## D. Expression echo

When the statement path compiles an entry that is a **single bare
expression**, emit it as `return expression()` inside `__repl_N`, record
the returned type index in a `repl_result_type` global, and have the
prompt print the call's result:

- default: `itoa(value)`
- `char*` (type char, pointer level 1): print as a string, `0` guard
- other pointer types: `hex(value)`

Two compiler-side details make this precise instead of heuristic:

- `expression()` returns type 3 ("constant") for both `1 + 2` and
  `x = 5`, so the REPL cannot tell assignments apart from values by type
  alone. Add a one-line flag in `grammar/expression.w` (set when the
  top-level `accept("=")` fires, cleared by the REPL before each entry)
  and suppress the echo for assignments, matching Python.
- `void` results (a bare call to a `void` function) print nothing.

## E. Run a file, then attach the prompt (`python -i`)

CLI: `./bin/repl [file.w] [args...]`, plus a `--no-main` flag to load
definitions without executing. Startup becomes:

1. mmap the buffer, `define_asm_functions()`, compile `lib/lib.w` and
   `lib/assert.w` — as today.
2. **Register the precompiled modules in the import registry**
   (`import_register("lib/lib")`, `"lib/assert"`). Today they are
   compiled via `compile_save` directly, which skips the registry, so
   any loaded file whose imports reach `lib.lib` would recompile it into
   a `symbol redefined` cascade. Cleanest shape: extract an
   `import_module("lib.lib")` helper from `import_statement()` that
   resolves/registers/compiles, and use it both here and there.
3. If a target file was given: `compile_file(target)` into the same
   buffer. Its functions, globals, structs, and imports land in the
   shared tables — the wdbg model exactly.
4. Unless `--no-main`: look up `main` with `sym_address` (assert it is
   defined) and call it with argc/argv shifted by one so the target sees
   itself as `argv[0]`.
5. Enter the interactive loop. After `main` returns, the prompt can call
   any function from the file and read or assign its globals directly,
   because they are ordinary 'D' symbols in the shared table.

One robustness fix this mode forces: `compile_relative_path()` calls
`exit(1)` when it reaches the filesystem root, and
`compile_attempt`/`asserts` paths can also die outright. Inside the REPL
(`repl_recovery == 1`) these must route through `error()` so the
long-jump recovery fires and a failed `import` or `:load` returns to the
prompt instead of killing the session.

## F. Error-recovery hardening

The checkpoint in `repl_compile_entry` must grow with the new features.
Roll back on failure, in addition to the current set:

- the type-table length (a failed `struct` declaration mid-parse leaves
  a half-built type — `list.w`'s `length` for the type list, plus
  `table_pos` already covered)
- `imported_count` (a failed import must be retryable after the user
  fixes the file; the registered path would otherwise shadow the retry)
- `current_function_symbol`, `enclosing_tab_level` (function-definition
  entries now touch them)

`codepos` rollback already covers partially emitted code, including the
data words of a failed declaration.

## G. Polish

- Gate the `struct_declaration=1, ...` print in `grammar/program.w`
  behind verbosity (`print_int_v1`). It currently spams stderr on every
  compile, not just the REPL.
- New banner: mention multi-line entry rules (blank line ends a block),
  tabs, `:quit`, `:help`. Add a `:help` command; `:symbols`
  (via the existing `print_symbol_table`) is cheap and useful.
- Update `docs/todo.txt` / `docs/ui.txt` limitation lists when done.

Out of scope for v1, since landed: line editing and history
(`lib/termios.w` raw mode + `lib/line_edit.w`, persisted to
`~/.w_history`, wired into both the REPL prompt and the wdbg command
loop), evaluating expressions at a wdbg breakpoint with locals bound in
(`debugger/eval.w`), and the x64 REPL (real x64
`repl_setjmp`/`repl_longjmp` stubs, `MAP_32BIT` code buffer,
`repl_x64`/`repl_test_x64` targets). Still future: a `:load` command as
an alias for the file mode.

## H. Testing

Extend the `repl_test` target (piped stdin, output assertions),
one case per feature:

- multi-line function definition, then a call that prints
- `int x = 5` in one entry, `print(itoa(x))` in a later one;
  redefinition with a different type
- bare-expression echo (`1 + 2` → `3`); no echo for `x = 5`
- `struct` definition at the prompt, then `new`/field access
- `import structures.string` at the prompt, then using it
- a compile error *inside* a multi-line entry, then a working entry
  (recovery), including a failed `import` of a nonexistent module
- file mode: a small `tests/repl_fixture.w` with a `main` that prints
  and a helper function; assert both the main output and a prompt call
  of the helper afterwards; `--no-main` variant

Regression guards: `./wbuild verify` (the `program()` refactor and the
`expression()` flag touch the compiler, so the self-host fixpoint must
stay byte-identical) and the full `./wbuild tests`.

## Sequencing (each step lands green on `./wbuild verify` + `repl_test`)

1. Extract `function_definition()` from `program()`; gate the struct
   debug print. Pure refactor.
2. Multi-line reader in `repl.w` — statements and control-flow blocks
   work across lines.
3. Declaration dispatch: functions, structs, imports, extern from the
   prompt; checkpoint/rollback additions.
4. Persistent globals with initializers; redefinition shadowing.
5. Expression echo.
6. File-load-then-attach mode: import-registry fix, `exit(1)` →
   `error()` paths, argv forwarding, `--no-main`.
7. Test matrix + docs updates.

## Implementation notes (deltas from the plan above)

- **Jump-over regions instead of ordering constraints.** The entry's
  anonymous function is defined at the start of the entry, and every
  region that must not execute inline — module code from imports,
  extern shims, function bodies, global storage words — is wrapped in a
  `jmp rel32` (`repl_skip_start`/`repl_skip_end` in `repl.w`). This lets
  declarations and statements interleave freely in one single-pass
  compile: `int q = 3; q + 4` works, as does a function definition
  followed by statements in the same entry.
- **Echo knows call return types.** `expression()` returns "constant"
  (3) for every call, which would echo a `void` call's garbage eax. The
  call compiler in `grammar/postfix_expr.w` now records the callee's
  declared return type (`last_call_return_type`/`last_call_end`); when
  an entry's bare expression *ends* in a call, that type drives the
  echo: `print(...)` stays silent, `itoa(5)` prints `5` as a string.
- **Prototypes resolve, definitions shadow.** `repl_declare_global`
  reuses an existing 'U' symbol (so a prototype's backpatch chain of
  pending call sites resolves), but shadows a 'D' one with a fresh
  symbol.
- **Loading a file with no `main` is not fatal**: the REPL checks the
  symbol is defined ('D') before calling, since a 'U' symbol's address
  slot holds its backpatch chain, and continues to the prompt either
  way.
- **Unterminated string literals are rejected by the reader** (the
  tokenizer cannot recover from one); the scanner treats an open string
  as a continuation, so multi-line strings still work.
- The flag is spelled `--no_main` (lib/args flag parsing convention).
- **Auto-indent (added after the initial landing).** When stdin is a
  terminal (`ioctl TCGETS`), continuation lines start with the expected
  tabs, echoed after the `.. ` prompt and stored into the entry, so what
  you see is exactly what compiles. A `:` line indents one level; a line
  whose first token is `return`/`break`/`continue`/`pass` dedents (the
  IDLE rule); a blank line dedents one level and ends the entry at
  column 0. Any tabs the user types are added on top of the automatic
  ones. Piped input is detected as non-interactive and keeps its
  explicit tabs, so scripted sessions are unaffected.

- **Line editing and history (added with the x64 work).** On a tty the
  prompt is a raw-mode readline-style editor (`lib/line_edit.w`):
  cursor movement, Ctrl-A/E/K/U/W/L, Ctrl-C cancels the line, Ctrl-D on
  an empty line is EOF, and up/down browse a deduplicated history
  persisted best-effort to `~/.w_history`. Piped input keeps the plain
  reader, so scripted sessions are unaffected. The auto-indent tabs are
  part of the editor's buffer, so editing a recalled line preserves
  them.

Known limitations (documented in `docs/todo.txt`): calls compiled before
a redefinition keep the old binding — fixing this needs a persistent
call-site indirection table, tracked separately since it touches call
codegen on every architecture rather than being a REPL-only change (see
the follow-up issue filed alongside this fix). `struct`/`union`/`enum`
redefinition and the line editor's single-row-only redraw were both
fixed in the same pass as this limitations note: a repeated
struct/union/enum name now resets and reuses its existing type-table
record in place (`type_reset_for_redefinition`,
`compiler/type_table.w`) instead of being permanently shadowed by the
first definition, and `lib/line_edit.w`'s redraw now tracks how many
terminal rows the buffer occupies (`le_prev_rows`, using
`lib/termios.w`'s new `term_get_cols`) so a wrapped entry redraws
correctly instead of leaving stale rows on screen.
