# Native incremental function compilation

`repl/incremental.w` adds an opt-in production compiler API for native x86/x64
sessions. It retains emitted machine code, symbol/type state and retained AST
nodes for an unchanged prefix of ordered function definitions. An edit restores
the checkpoint immediately before the first changed definition and recompiles
only the suffix through `repl_eval` and the existing production backend. No
alternative language implementation or whole-program artifact cache is involved.

This is a deliberately restricted first incremental emission surface. It does
not finish issue #489, supply a standalone executable linker, or make arbitrary
modules incrementally compilable. Issue #488 remains closed.

## API

Initialize the production REPL once with `repl_init()`, then call
`incremental_init()` before loading user definitions. The session owns the
process-global compiler state until `incremental_clear()`.

Pass a `list[char*]` of complete function sources to `incremental_update`. Sources
are copied into session ownership; callers may release their input after the
call. The result reports `status`, `reused`, `compiled`, `failed_index` and a
static `message`. Successful unchanged updates emit no code. `reused` counts
unchanged leading functions, while `compiled` counts newly emitted functions.
Exact source bytes determine equality, including comments and whitespace;
filesystem timestamps are not involved.

`incremental_address(name)` returns a compiled function's native address, or
zero for an absent name. The caller must invoke it with the declared ABI and
must discard saved addresses after every update. Compilation does not execute
function bodies or entry initialization. A caller can invoke compiled functions
without adding REPL evaluation entries, so doing so preserves the compiler's
checkpoint ownership.

`incremental_clear()` rolls the session back to its initial prelude and frees
its source/checkpoint records. Call `repl_cleanup()` when the entire REPL lifetime
ends to remove its staging files. As with ordinary REPL compilation, staging
files and source/debug records accumulate during a session; this API does not
claim bounded total process memory or independently owned program snapshots.

## Admission and invalidation

The admission lexer restricts entries to one function with scalar `int`, `bool`,
`char` or `void` return type, scalar named parameters, scalar local declarations,
arithmetic/comparisons, `if`/`else` and `while` with parenthesized conditions and
colon blocks, and direct calls to earlier session functions
or the function itself. The production compiler still parses and checks every
changed function; admission is only a conservative safety gate.

Imports, forward prototypes, generics, compound types, global declarations,
strings, containers, labels, pointer dereferences, indirect calls, foreign calls,
lazy runtime builtins and other syntax that
could mutate an already compiled prefix are rejected **before** any existing
code is invalidated. Duplicate function names, reserved compiler/test names and collisions with the
preloaded runtime are rejected too. There is no implicit full-program fallback with weaker
invalidation guarantees. A session admits at most 256 functions, each at most
65536 source bytes.

An admitted edit invalidates every later definition, including callers and
functions that happen to be independent. Deleting a suffix only restores its
checkpoint; appending definitions only compiles the appended entries. A compile
error removes the old invalid suffix and keeps the successfully compiled prefix
available. Repairing the source retries the missing suffix. Admission errors
leave the previous complete program intact.

The prelude is the already compiled, immutable in-process environment. No imports
are resolved or read during incremental updates. The compiler binary cannot
change inside that process. Changes to ABI, code generation/diagnostic options,
AST modes, type/import counts or code/symbol positions reject further updates;
embedders must not mix other compilation APIs into an active session. To change
the prelude or target, start a fresh compiler process. General module dependency
invalidation, changed import resolution and per-definition relocation remain
future work, as do replay directly from semantic trees and cross-target output.

The separate `compiler/module_dependencies.w` API now analyzes retained import,
binding and type edges and computes transitive invalidation plans. It is not
wired into these incremental sessions and does not expand their admission rules.
Its graph owns its data, but covers only dependencies represented by the current
retained traversal; it is not sufficient to authorize general code reuse. See
[the module dependency increment](ast_migration.md#declaration-inventory-and-independent-module-dependency-analysis)
for ownership, schema and remaining gaps.

## Regression gates

`./wbuild incremental_compilation_test incremental_compilation_64_test` runs
production AST-required compilation with retained trees and checks:

- Warm updates emit nothing; a same-size middle edit preserves exact prefix
  machine bytes, function addresses and the retained-node boundary.
- The compiled functions produce changed results after suffix replay.
- Compiler failures retract stale downstream functions and repairs succeed.
- Deletion, append and first-definition changes select the expected suffix.
- Unsafe syntax and changed compiler modes/ABI reject reuse without mutation.
- Clear restores the initial compiler code and symbol boundaries.

The ordinary bootstrap fixpoint continues to use non-incremental compilation.
