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
Equal source bytes always keep a function; filesystem timestamps are not
involved. With the retained forest on (`--ast-retain`, `--ast-required` or
`--ast-emit-retained`), a function whose bytes changed is also kept when its
retained tree is unchanged (S2.4): when the two sources differ only in `#`
comments and trailing blanks, the new source is compiled once at the end of
the session with standard error muted, its retained nodes and bindings are
compared with the kept compile's (kinds, operands, literals, types
structurally, bindings and symbol references by meaning, every position by
line and column), and the probe is rolled back. `tree_reused` counts the
functions kept that way and `tree_probed` the probes. A probe that warns
differently from the kept compile, fails, or differs anywhere falls back to
recompiling the suffix, which reports its own diagnostics. The kept function's
retained source version and staging file keep the bytes that were compiled.
A comment line inserted or removed moves later lines and is a change; so is
any change to the session's AST modes, `--ast-emit-retained` included.

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
functions that happen to be independent; an edit that leaves the function's
retained tree unchanged (above) is not an edit in this sense. Deleting a suffix only restores its
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
binding and type edges and computes transitive invalidation plans. Its graph
type and invalidation walk live in `compiler/module_graph.w`, which
`tools/wbuildd.w` uses to decide which memoized `check`/`deps`/`symbols`
answers an edit affects and to re-check only those
([wbuildd.md](wbuildd.md) §8). That decides which *answers* to recompute; it
emits no code. It is not wired into these incremental sessions and does not
expand their admission rules.
Its graph owns its data, but covers only dependencies represented by the current
retained traversal; it is not sufficient to authorize general code reuse. See
[the module dependency increment](ast_migration.md#declaration-inventory-and-independent-module-dependency-analysis)
for ownership, schema and remaining gaps.

## Independent native function updates

`repl/incremental_graph.w` adds a separate append-only strategy using the same
production compiler and conservative scalar-function admission rules:

```w
repl_init()
incremental_graph_init()
incremental_result result = incremental_graph_update(sources)
int address = incremental_graph_address(c"my_function")
incremental_graph_clear()
repl_cleanup()
```

Each update supplies the complete ordered list of function definitions. It
compiles changed definitions and their transitive users, while unrelated
definitions retain their machine code and addresses regardless of their position
in the list. Reordering independent functions and deleting unreferenced functions
emit no code. The admission rules require calls to earlier functions or self,
so a forward dependency walk suffices; identifier references conservatively
count as dependencies even when a local shadows their spelling. A changed callee
invalidates its users even when its signature appears unchanged, preserving the
production compiler's type checking and any emission-time specialization.

All dirty definitions compile in one no-execution REPL transaction. A failed
compile restores the previous complete program, including symbol and retained
tree state. Only a successful update patches recorded function-address and direct
call sites through the REPL's existing late-binding registry. `status`, `reused`
and `compiled` describe the result; `failed_index` identifies admission failures,
but is `-1` for a transaction compile failure, whose diagnostic identifies its
source position in the staged batch. No-op updates perform no compilation. The
prefix and independent update APIs reject attempts to mix their strategies in
one session. Changes to compiler state or emission options reject reuse.

This strategy does not relocate code: old definitions remain allocated until
`incremental_graph_clear()`, and changed definitions append new code. Deleted
names disappear from the address API; their internal compiler records remain
until clear and can be shadowed if the name is reintroduced. A deleted function's
name is reserved until clear: incoming definitions may not mention it, even as
a local variable, unless that function is also reintroduced in the same update.
This conservative admission rule prevents an out-of-scope or later local from
accidentally resolving to a deleted compiler symbol. Callers must discard
saved addresses after an update and invoke each address with its declared ABI.
The API still excludes imports, globals, composite types and arbitrary modules,
and it is not integrated into `wbuildd`. It makes independent scalar-function
reuse available without claiming a general module cache or bounded session memory.

`tests/incremental_graph_test.w` exercises both native widths: independent byte
and address reuse, transitive invalidation, deletion/reordering/reintroduction,
recursive calls, signature changes, atomic failed updates, missing dependencies
and changed compiler options.

## Per-definition relocation (design; not implemented)

The original checkpoint strategy reuses a *prefix*: an edit to one definition
throws away every definition after it. The independent strategy preserves
unrelated definitions at their original addresses, at the cost of keeping old
code allocated. Compacting those definitions or linking them into a fresh image
requires relocation: copying their bytes to a new address and fixing every
place where those bytes encode an address. This
section records what such a definition record must hold. It is a design
only: nothing below exists yet, and `wbuildd`'s module-graph invalidation
(above) does not depend on it.

### Why the bytes are not relocatable today

The single-pass emitter writes directly into one code buffer at
`code_offset + codepos`, and it bakes absolute virtual addresses into the
instruction stream as it goes:

- **Address slots.** Every reference to a global function or variable
  goes through `be_addr_slot_emit` (`code_generator/arm64.w`): a
  `mov $imm32,%eax` on x86/x64, an `adrp`+`add` pair on arm64, a wasm
  constant. A defined symbol's slot is written with its final address
  (`sym_emit_value`). An undefined one stores the previous slot's address,
  forming a backpatch chain threaded through the slots themselves
  (`addr_chain_link`/`addr_chain_patch`, `compiler/symbol_table.w`), and is
  patched when the definition appears. Generic instantiations and lazy
  runtime helpers use the same chains.
- **PC-relative pairs.** arm64's `adrp` immediate is a page delta from
  the instruction's own address. Moving a definition therefore changes
  slot bytes even when the target did not move.
- **Data addresses.** Under the W^X split, mutable globals and enum
  tables live in the data segment at `data_offset + datapos`, so their
  addresses depend on every earlier data allocation.
- **Inline data.** String literals and descriptor blobs are inline in
  the text, jumped over with a call (x86) or a branch (arm64). They move
  with the function and need no patch. Intra-function branches are
  rel32/imm19 displacements and also move unchanged.
- **Side tables keyed by address**: DWARF line rows, subprogram records
  and `.debug_frame` CFI (#555), wdbg's line table, the REPL's
  `repl_call_site_hook` call-site list, wasm funcref indices, and
  dynamic import stubs (GOT/IAT cells).

### What a relocatable definition record needs

1. **Code bytes.** The definition's emitted bytes, starting at its first
   instruction (prologue) and ending before the next definition. Inline
   string and blob data is included. The bytes are stored as emitted at
   some base address; the patch list says which bytes depend on it.
2. **A patch list of absolute references.** One entry per byte position
   whose value depends on where something lives:
   `{offset within the record, kind, target, addend}`.
   - `kind` is the slot encoding: `addr_slot` (rewritten with the
     existing `be_addr_slot_write(pos, value)`, which already
     re-encodes for x86 imm32, arm64 `adrp`+`add` and wasm), `data_addr`
     (the same slot, targeting the data segment), `tls_offset`,
     `import_cell` (GOT/IAT/stub), and `funcref` on wasm.
   - `target` is a stable identity, never an address: the retained
     binding `linkage` ID for a global symbol (prototype, uses and
     definition share it), a data-object identity for globals and
     literal pools in the data segment, or the generic-instance or
     lazy-helper key that its backpatch chain uses today.
   - Recording it costs one append at each place that writes a slot
     today: `sym_emit_value`'s `D`/`U` branches, `addr_chain_link` and
     the data-segment definers. Every slot is then in the list, not
     only the ones still undefined when the definition ends. Once the
     list exists, the chains become one way to fill it rather than the
     only record of the slots.
   - Relocating means copying the bytes, then writing each entry's
     resolved target plus addend at its new position. No byte outside
     the list may depend on the record's own address. A debug build
     can check this by emitting the same definition at two bases and
     diffing: the bytes may differ only at listed offsets.
3. **A symbol/type snapshot id.** The bytes are only valid against the
   declarations they were compiled with. Examples: struct layouts and
   field offsets folded into immediates, a callee's arity and return
   type, and `const` and enum values emitted as immediates. The id is a hash over what the definition's emission
   *read*:
   - the signatures and layouts of every type and symbol the definition
     bound to (the retained binding and type edges
     `compiler/module_dependencies.w` already collects, per definition
     rather than per module);
   - the target, word size and ABI;
   - codegen options (AST mode, `--debug`, pac);
   - the compiler binary's own hash.

   A record whose id no longer matches is recompiled, never patched.
   This is why the module graph alone cannot authorize reuse: it records
   which modules depend on which, not the values the emitter folded in.
   It also records no negative lookups, such as an import that resolved
   past a missing file.
4. **Side-table fragments**, each relative to the record start: DWARF
   line rows and the subprogram/variable entries for the definition,
   its CFI, and the wdbg line-table rows. With relocated code these are
   shifted, not regenerated. A record without them can still be used
   for a non-debug link.
5. **Data contributions.** Mutable globals, enum tables and literal
   pools that the definition defines (not just references) are separate
   data records with their own identity, size, alignment and initial
   bytes. These could be patch lists of their own for address-valued
   initializers. Code refers to them only through `data_addr` patches.

### What it would take, in order

1. Record patch lists alongside today's emission (no behavior change).
   Gate: a "two bases, diff only at listed offsets" check over the
   compiler.
2. Compute snapshot ids from the per-definition binding/type edges.
   Gate: an edit to a struct layout invalidates exactly the definitions
   that read it.
3. A linker step that lays out records and applies patches. Gate:
   byte-identical images against a fresh compile when nothing is reused.
   Generic instances, lazy runtime helpers and data-segment layout are
   the hard parts here.
4. Only then reuse records across compiles (`wbuildd` or a cache keyed
   by snapshot id). This is the step that makes *builds* incremental;
   the module-graph invalidation in `wbuildd` today only makes
   *re-checking* incremental.

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
