# Finishing the production AST (#489): status and a parallel work plan

Status: plan, 2026-10-06, written against `main` at `9da02ea` (the last
AST commit, "retained declaration inventory and module dependency
analysis"). Companion to [ast_migration.md](ast_migration.md), which is the
task-by-task history of what has landed; this document is the forward
plan. The retired `wc2` experiment's requirements list in
[wc2.md](wc2.md) still applies to every unit below.

Issue #489's body predates all of this ("blocked on the #488 spike"). #488
is closed and the production migration is well past the spike. #489 was
closed after AST and retained emission became the defaults. Its broader
definition of done below still needs the architectural follow-ups.

### Implementation checkpoint (2026-10-09)

The assessment and task specifications below preserve the original baseline;
they are not a claim that all of the listed gaps still exist. The current
implementation is described in `ast_migration.md`.

- The AST and retained-emission default switches, diagnostic codes/spans,
  DWARF support, in-process multi-error recovery, daemon answer invalidation
  and the first optional optimizer have landed.
- The CI matrix now includes a separate `ast_expression_suite` leg with the
  same runtime/ptrace/display setup as ordinary tests. The compiler canaries
  remain in the ordinary suite.
- Expression storage now grows beyond the former node, literal, source-window
  and speculative-type capacities; the explicit syntax nesting guard remains.
- Independent function reuse is available through `repl/incremental_graph.w`:
  dependency-based invalidation, atomic updates, and unchanged functions kept
  at their existing addresses. Its scalar admission rules and append-only
  lifetime do not implement general module relocation or a `wbuildd` code cache.
- Supported deferred calls retain unbound syntax and bind their names at each
  exit. Other deferred syntax and generic bodies still use source replay.
- Independent layout/control analysis is being separated from backend state.
  Whole-function parse-before-emission remains an architectural milestone;
  per-statement retained emission alone does not satisfy checkpoint B.

Streaming grammar retirement still follows P1.5's tagged-release/seed gate.
The final local compile-time measurements are 1.40x streaming on x86 and 1.47x
on x64; the 1.25x target remains unmet. Both complete test suites pass (1,023
targets each), along with the x86, x64, Win64 and wasm self-host fixpoints.
See the latest section of `ast_migration.md` for the measurements and scope.

## 1. Where the AST work stands

### 1.1 What exists

Measured on this checkout (4-core Xeon 2.1 GHz container, `./wbuild build`
and `build_x64`, `bin/wv2 … --strict w.w`, median of three runs):

| Compile of `w.w` (58k lines) | x86 host | x64 host | Image vs. streaming |
| --- | --- | --- | --- |
| default (streaming) | 0.82 s | 0.74 s | — |
| `--ast-full-expressions` | 2.10 s | — | identical |
| `--ast-required` | 2.08 s | 2.13 s | identical |
| `--ast-retain --ast-required` | 5.70 s | 5.69 s | identical |
| `check --all-errors` (vs. `check` 0.73 s) | 37.7 s | — | n/a |
| `tree --json` of `w.w` | 10.0 s, 185 MB, 337k records | — | n/a |

`bin/wv2 check --quiet --ast-retain --ast-required --stats w.w` reports
44,393 AST expression roots and **zero** streaming roots; 3,478 functions,
20,719 expression statements, 6,350 returns, 10,137 `if` regions, 991
`while` loops, 6,673 local declarations and 1,121 globals all go through
the `ast_*` grammar and `emit_*_ast` emitters. 288,575 retained nodes,
29,127 retained types and 17,707 bindings are built for the compiler.

So the opt-in path is **complete for the compiler corpus and the test
suite** (the serial `./wbuild ast_expression_suite` runs the whole
manifest in required mode), **byte-identical on all six image targets**,
and gated by self-host fixpoints in every mode
(`ast_expression_verify`, `ast_required_expression_verify`). Consumers
of the retained forest exist: `w tree --json` (schema v2),
`check --all-errors`, `repl/incremental.w`, and
`compiler/module_dependencies.w`.

### 1.2 What it is not yet

The structure of the landed code is the thing to understand before
splitting work, because it is not the end state #489 describes.

1. **Emission still happens during parsing, in source order.** An
   expression is parsed into a bounded *temporary* arena
   (`compiler/expression_ast.w`, 4,096 nodes on the stack of
   `ast_expression_try_at`), emitted by `code_generator/expression_ast.w`
   immediately, and the arena is gone. Statements are single
   `statement_ast` records lowered on the spot; function, loop and global
   nodes are boundary records around the old emission order. The grammar
   is "AST-shaped" per construct, but there is no point in time at which
   a whole function body exists as a tree that has not been emitted.
2. **The retained forest is a record of the traversal, not the input to
   emission.** `--ast-retain` copies each temporary arena into
   `compiler/retained_ast.w` *after* emission (`retained_expression_note`).
   Nothing reads it back to emit. Its own doc says "lowering still uses
   temporary nodes and some borrowed symbol bindings", "backend table
   indices remain explicitly raw metadata", "opcode-specific lowering
   payloads are not yet fully retained".
3. **Parse-time semantic side effects remain.** Type and import
   declarations update the type/symbol tables as they are parsed; local
   declarations assign stack slots during the parse. That is what forces
   `check --all-errors` to isolate every statement in a forked process
   (`compiler/analysis.w`), which is why it is 52x slower than `check`
   and why a discarded declaration produces follow-on "Cannot find
   symbol" errors at every later use (reproduced with a three-error
   file: the second error is reported as a warning by the type checker
   and the third is a follow-on from the first).
4. **Bodies are still reparsed from the file.** Generic instantiation
   (`grammar/generic.w` `generic_reparse_start`, four `seek` sites),
   deferred expressions (`grammar/defer.w`), operator-overload lookahead
   and lazy runtime helpers reopen the source and seek to a recorded
   offset. The retained forest "records the traversal, including
   repeated deferred/generic visits; it is not a replacement for those
   reparses."
5. **The AST path is 2.5x slower than streaming** and retaining is 7x.
   The cost is structural: every expression is byte-preflighted
   (`ast_expression_end`/`ast_expression_root_end`), the tokenizer is
   snapshotted, the expression is parsed speculatively, the tokenizer is
   restored, and the accepted tokens are **replayed** through the
   streaming lexer for diagnostics and literal decoding before emission.
   Retaining additionally allocates one `new retained_node` (60 fields)
   per node and copies literal/text arenas. This, not coverage, is what
   blocks the production-default decision (milestone 3 in
   ast_migration.md).
6. **Two front ends are maintained.** The streaming expression and
   statement grammar (about 7,400 lines across `grammar/expression.w`,
   `unary_expression.w`, `postfix_expr.w`, `binary_op.w`, the builtins,
   `statement.w`, `for_statement.w`, …) is still the default and is
   mirrored by the 3,426-line `grammar/ast_expression.w` plus the
   `ast_*.w` statement files. Every language change is made twice, and
   `ast_expression_suite` (the only gate that runs the *suite* in AST
   mode) is not in `tests`, so CI does not run it.
7. **Incremental compilation is a restricted API, not a build feature.**
   `repl/incremental.w` admits only scalar functions with no imports,
   types, globals, strings or containers; `module_dependencies.w`
   computes invalidation plans but is not wired to anything; nothing
   relocates an independently emitted definition.

### 1.3 Definition of done for #489

Three checkpoints, each closable on its own. The issue's end state
("`grammar/` rules build AST nodes and `code_generator/` walks them,
instead of the single-pass fusion") is checkpoint B; A and C are what
make it worth having.

- **A. One front end.** AST mode is the default, the streaming
  expression/statement grammar is deleted, and the AST compile is within
  1.25x of today's streaming wall-clock on both host widths. `verify`,
  `verify_x64`, `verify_arm64`, `verify_darwin`, `verify_win`,
  `verify_wasm` hold.
- **B. Tree-then-emit.** A function body is parsed completely into the
  retained forest with no code emitted, then emitted by walking that
  tree. Generics and deferred expressions are instantiated from retained
  trees, not by seeking the file. REPL and wdbg run on the same path.
  `check --all-errors` is a tree walk, not a fork per statement.
- **C. Consumers.** `check --json` carries stable codes, end columns and
  related notes; DWARF has subprograms, variables and types (#536);
  there is an optional tree-rewriting pass slot for #110; the
  module-dependency graph drives `wbuildd`'s invalidation.

## 2. Work units

Each unit is sized for one medium-effort coding agent
working on its own branch and PR. "Owns" lists the files the unit may
edit; "touches" lists shared files it may edit only under the rules in
§3. "Gates" are the targets that must pass before the PR is opened; every
compiler-tree unit additionally runs `./wbuild verify verify_x64` and
`./wbuild tests` (and `parser_generator_w_test` is included in `tests`).
No unit adds language syntax: everything here is in `w.w`'s seed-compiled
import closure (CLAUDE.md "Seed constraint").

### Phase 1 — make the AST path the production path (checkpoint A)

**P1.1 AST parse cost: remove the speculative-parse-and-replay double
work.** Target: `bin/wv2 --ast-required --strict w.w` within 1.25x of the
streaming compile on x86 and x64 (today 2.5x). Profile first (the
compiler has `--stats`; add counters for bytes preflighted, tokenizer
snapshots, tokens replayed, and report them in the PR). Expected
levers, in order: skip the byte preflight when the tokenizer buffer
already holds the line and the previous root ended cleanly; parse once
with a recording lexer instead of parse-then-replay, keeping the replay
only for the literal/diagnostic events that need source order (string
decoding, bit-31 cast notes, `--lint` assignment checks); stop
snapshotting the whole tokenizer state per root. Diagnostics and images
must stay byte-identical; the fixture matrix in `ast_expression_test`
is the oracle.
Owns: `grammar/ast_expression.w` (preflight and prepare sections,
roughly lines 1–460 and 3230–3410), `compiler/expression_ast.w`,
`compiler/tokenizer.w` (snapshot/restore helpers only).
Gates: `ast_expression_test`, `ast_expression_verify`,
`ast_required_expression_verify`, `ast_symbol_probe_test`,
`ast_integer32_test`, `ast_expression_suite` (serial, run once before
opening the PR), timing table in the PR body.

**P1.2 Retained-forest cost and query ergonomics.** Target:
`--ast-retain --ast-required` within 1.5x of `--ast-required` (today
2.7x), and `ast_retained_memory_test` green under `W_DEBUG_ALLOC=1`.
Replace per-node `new retained_node` with a chunked arena owned by the
session (checkpoint rollback becomes a high-water mark), intern
binding/type names, stop copying expression text arenas that are
already owned by the source version (point at the source bytes by
offset), and make `retained_query_dump` stream per record instead of
materialising. Add `tree --json --file <path>` and `--no-expressions`
filters so a 185 MB dump is not the only way to ask a question. Schema
stays version 2 unless a field is added, in which case bump to 3 and
update `ast_tree_query_test`.
Owns: `compiler/retained_ast.w`, `compiler/retained_semantic.w`,
`compiler/retained_query.w`, `grammar/retained_ast.w`,
`tests/ast_retained_*`, `tests/ast_tree_query_test.w`.
Gates: `ast_retained_test`, `ast_retained_memory_test`,
`ast_semantic_test`, `ast_tree_query_test`, `module_dependencies_test`,
`incremental_compilation_test`, timing table.

**P1.3 Run the required-mode suite in CI.** Add a second CI job that
runs `./wbuild ast_expression_suite` (it generates a required-mode
manifest with `bin/wast_audit required-manifest` and runs `tests`
serially, so it is a separate leg, not a member of `tests`). While
there, record in `tools/wast_audit.w` why the suite is serial (the
nested-build race noted in ast_migration.md) and open an issue if the
race is in `wexec`. Also make `./wbuild tests` include a cheap canary:
`bin/wv2 check --quiet --ast-retain --ast-required w.w` on both hosts
(a `# wbuild:` target in a new `tests/ast_canary_test.w`).
Owns: `.github/workflows/ci.yml`, `tools/wast_audit.w`,
`tests/ast_audit_test.w`, `tests/ast_canary_test.w` (new).
Gates: `ast_audit_test`, the new CI leg green on the PR.

**P1.4 Flip the default (serial; after P1.1, P1.2, P1.3 merge).** Make
`ast_expressions_mode = 2` the default; add `--streaming` as the opt-out
and keep `--ast-required` as a no-op-with-check. Invert the comparison
gates: `verify` now exercises the AST path; `ast_expression_verify`
compares `--streaming` against the default; `wast_audit
required-manifest` becomes a check that no step still passes an
AST flag. Update wdbg/REPL flag handling (`debugger/wdbg.w` lines
~1056–1083, `repl/incremental.w` option key), `CLAUDE.md`'s command
summary, `README.md`, and the "Current production migration status"
section of ast_migration.md. This is the maintainer decision milestone
3 records; the PR body must carry the P1.1/P1.2 timing tables and the
`ast_expression_suite` result so the decision is made on numbers.
Owns: `compiler/compiler.w` (option block ~820–860 and reset ~1085–1130),
`debugger/wdbg.w`, `repl/incremental.w`, `tests/ast_expression_test.w`
directive block, `tools/wast_audit.w`, docs.
Gates: everything in `tests`, `ast_expression_suite`, `verify_arm64`,
`verify_win`, `verify_wasm`, `verify_darwin` (the release workflow's
matrix, run on the PR via `workflow_dispatch` or locally per
`docs/release.md`).

**P1.5 Retire the streaming expression and statement grammar (after
P1.4 has shipped in a tagged release and `SEEDS` points at it).** Delete
the dead streaming paths and the `ast_expressions_mode >= 2` branches
that guard them (grep count today: 22 files). The byte-identical
differential oracle disappears with it; for one release keep a
`seed_image_test` that compiles the differential fixtures with `./w`
(the pinned seed, which still contains the streaming front end) and
with `bin/wv2` and compares images, then drop it at the next seed bump.
Split by file group across up to three agents, since the deletions are
independent once nothing selects the streaming path:
(a) expressions: `grammar/expression.w`, `unary_expression.w`,
`postfix_expr.w`, `primary_expr.w`, `binary_op.w`, `*_expr.w`,
`conditional_expr.w`, `increment.w`, `multi_assign.w`;
(b) builtins and literals: `print_builtin.w`, `list_builtin.w`,
`hash_builtin.w`, `json_builtin.w`, `protobuf_builtin.w`,
`template_string.w`, `string_literal.w`, `ndarray_index.w`,
`atomic_builtin.w`, `gpu_*builtin.w`, `var_builtin.w`;
(c) statements and declarations: `statement.w`, `for_statement.w`,
`while_statement.w`, `switch_statement.w`, `variable_declaration.w`,
`goto_statement.w`, `program.w`, `kernel_decl.w`, `generator_decl.w`,
`extern_statement.w`, `enum_declaration.w`, `gpu_for.w`.
Gates per agent: `verify`, `verify_x64`, `tests`, `parser_generator_w_test`
(the grammar file `tests/parser_generator/w.pg` does not change: no
syntax changes).

### Phase 2 — tree-then-emit (checkpoint B)

This is the architectural core and has a serial spine. S2.1 establishes
the mechanism on expressions, S2.2 extends it to whole bodies and can be
split by construct family, S2.3–S2.5 follow.

**S2.1 Emit expressions from the retained tree (serial spine).** Add
`--ast-emit-retained`: after an expression's retained group is built,
emit *from the retained group* instead of from the temporary arena,
through an adapter that reconstitutes an `expression_ast` arena from
retained nodes (`code_generator/retained_emit.w`, new). The point is to
discover and close every field the retained copy lacks ("opcode-specific
lowering payloads", "borrowed symbol bindings", raw backend indices):
each gap becomes a retained field or a resolved semantic reference, and
the mode ends byte-identical with the default on all six targets and
both hosts. Nothing else changes; the temporary arena remains the
default emitter until S2.5.
Owns: `code_generator/retained_emit.w` (new), `grammar/retained_ast.w`,
`compiler/retained_ast.w` (append-only fields; see §3),
`tests/ast_retained_emit_test.w` (new; the differential fixture list is
`ast_expression_test`'s data files, compiled in both modes and `cmp`'d).
Gates: new test, `ast_retained_test`, `ast_retained_memory_test`,
`ast_required_expression_verify` with `--ast-emit-retained` added as a
third fixpoint leg (edit of the `ast_expression_test.w` directive block,
coordinated per §3).

**S2.2 Parse a whole body, then emit (after S2.1; parallel by construct
family).** Under `--ast-emit-retained`, a function body is parsed into
the retained forest with emission suppressed, then emitted by a walk.
The hard part is the parse-time side effects: local slot assignment,
`defer` registration, goto/label resolution, generic-instantiation
queuing and first-use type registration all happen inside the parse
today. The rule for every family: the parse records the *fact* in the
tree (a `local` node with its type and declaration order; a label node;
a deferred-expression node), and the emitter reproduces the side effect
in the same order the streaming emitter did, so images stay identical.
Families, each one agent, each owning its grammar/emitter pair:
(a) simple, expression and return/yield statements:
`ast_statement_simple`, `ast_statement_value`, `ast_statement_expression`
in `grammar/ast_statement.w`; `emit_simple_statement_ast`,
`emit_statement_ast_expression`, `emit_statement_ast_value`,
`emit_statement_ast_exit` in `code_generator/statement_ast.w`;
`compiler/statement_ast.w`;
(b) blocks, `if`/`elif`/`else`, guards and `while`:
`ast_statement_guard`, `ast_if_statement_tail`, `ast_statement_block` in
`grammar/ast_statement.w`; `ast_while_statement` in `grammar/ast_loop.w`;
the `emit_guard_ast_*`, `emit_if_ast_*`, `emit_block_ast_*` emitters and
`emit_while_loop_ast_end`;
(c) `for` range/cursor/iteration loops and `switch`:
`ast_for_range_loop`, `ast_for_cursor_loop`, `ast_iteration_value` in
`grammar/ast_loop.w`; `ast_statement_switch_value`,
`ast_statement_switch_case`, `ast_switch_statement` in
`grammar/ast_statement.w`; `code_generator/loop_ast.w` and the
`emit_switch_*` emitters;
(d) local declarations, `defer`, `goto`/labels, raw asm:
`grammar/ast_declaration.w`, `ast_deferred_expression` in
`grammar/ast_statement.w`, the `emit_goto_*`/`emit_label_*`/
`emit_raw_*`/`emit_declaration_ast_*`/`emit_*_local_storage` emitters,
`grammar/defer.w` (record-only changes);
(e) function/script/generator/kernel boundaries, globals, thread-locals,
GPU launches: `grammar/ast_function.w`, `ast_global.w`, `ast_gpu.w`,
`ast_linkage.w`, `code_generator/function_ast.w`, `global_ast.w`,
`gpu_ast.w`, `linkage_ast.w`.
Family (a) lands first (it is the smallest and defines the emitter
walk's entry point in `retained_emit.w`); (b)–(e) branch from it and
can run concurrently. The mode's coverage counter
(`--stats` "retained-emitted statements" vs. "immediate statements")
must reach zero immediate statements on `w.w` when (e) merges.
Gates per family: `ast_retained_emit_test`, `ast_expression_test`,
`verify`, `verify_x64`, `tests`; the GPU family also `cuda_*` and
`gpu_*` targets (`bin/wtest changed` lists them).

**S2.3 Generic instantiation and deferred expressions from retained
trees (after S2.2).** Replace `generic_reparse_start`/`defer_reparse_start`
seeks with a walk of the retained definition tree under a type
substitution; the retained generic signature AST (task 38/45/46) already
captures headers. `defhash` keeps hashing tokens (it is a cache key, not
an emitter). Operator-overload and type-name lookahead rewinds stay (they
are lookahead, not reparse) unless trivially removable.
Owns: `grammar/generic.w`, `grammar/defer.w`, `grammar/lazy_runtime.w`,
`grammar/operator_overload.w`, `code_generator/retained_emit.w` (generic
section).
Gates: `generic_*`, `defer_*`, `operator_overload_*` targets, `verify`,
`verify_x64`, `tests`; `--stats` must show zero source seeks for
instantiation.

**S2.4 REPL and wdbg on the retained path (parallel with S2.3).** The
checkpoint/rollback machinery in `repl/core.w` already captures the
retained suffix; make the in-process compilers run `--ast-emit-retained`
and extend `ast_expression_test`'s REPL/debugger recovery legs to it.
`repl/incremental.w` reuses retained function trees for its unchanged
prefix instead of only source-byte equality (its admission rules do not
widen in this unit).
Owns: `repl/core.w`, `repl/incremental.w`, `debugger/eval.w`,
`debugger/wdbg.w`, `tests/incremental_compilation_test.w`, REPL/wdbg
tests.
Gates: `repl_*`, `wdbg_*`, `incremental_compilation_test`,
`ast_expression_test` (REPL/debugger legs).

**S2.5 Make retained emission the only emitter (serial; after S2.3,
S2.4).** `--ast-emit-retained` becomes the default, the temporary-arena
emission path in `code_generator/expression_ast.w` is reduced to the
adapter, and `--ast-retain` is implied by every compile (so P1.2's cost
target is now the compile's cost target: confirm within 1.25x of the
pre-plan streaming number, otherwise P1.2 reopens). Update
ast_migration.md's status and milestone list; this closes checkpoint B
and the issue's architectural question.
Owns: `compiler/compiler.w` option/reset blocks,
`code_generator/expression_ast.w`, docs.
Gates: all of `tests`, `ast_expression_suite`, the release verify matrix.

### Phase 3 — consumers (checkpoint C)

**C3.1 Multi-error checking without fork (after S2.2).** Once a body
parses without emitting, `check --all-errors` becomes: on an error
inside a body, mark the function's tree failed, synchronise to the next
statement (`analysis_skip` already does this) and keep parsing; emit
nothing for failed trees. Drop `fork`, the POSIX-only and
seekable-source restrictions, and the 100-error cap becomes a plain
counter. Follow-on errors from discarded declarations are suppressed by
keeping the failed declaration's binding as a poisoned symbol. Target:
`check --all-errors w.w` within 2x of `check`.
Owns: `compiler/analysis.w`, `tests/analysis_errors_test.w`,
`compiler/diagnostics.w` (poisoned-symbol note only).
Gates: `analysis_errors_test`, `warning_test`, `type_system_*_test`,
`lint_test`, `verify`.

**C3.2 Diagnostic codes, end columns and related notes (any time;
independent of Phase 2).** Add a stable `code` (`W0001`-style, table in
`compiler/diagnostics.w`), an `end_line`/`end_column` from the current
token's span (and from the retained node's `end` where one is live),
and `related: [{file, line, column, message}]` for the declaration a
"Cannot find symbol"/redefinition/mismatch refers to. Message text does
not change, so `warning_test` and the fixtures keep passing; the JSON
fixtures that pin exact records are updated in the same PR. Document
the fields in `docs/projects/lint.md`'s JSON section and
`docs/projects/ai_tooling_next_steps.md`.
Owns: `compiler/diagnostics.w`, `tests/*json*fixture*`, `tools/wfixture.w`
if it pins JSON fields, docs.
Gates: `warning_test`, `type_system_*_test`, `wfixture_*`, `lint_test`,
`verify`.

**C3.3 DWARF subprograms, variables and types from retained semantics
(#536; after P1.2, parallel with Phase 2).** `code_generator/dwarf.w`
today emits one childless compile unit. Emit `DW_TAG_subprogram` per
retained function (pc range from the function node's code span),
`DW_TAG_variable`/`DW_TAG_formal_parameter` with frame-base locations
from the existing runtime variable notes, and `DW_TAG_base_type`/
`structure_type`/`pointer_type` from `retained_types`. DWARF is emitted
by every compile today (there is no `-g`), so this unit needs the
retained forest on in every compile: it depends on P1.2's cost target and
should add the implicit retain itself if S2.5 has not landed yet. CFI is
#536's own follow-up and out of this unit.
Owns: `code_generator/dwarf.w`, `code_generator/dwarf_types.w` (new),
`tests/dwarf_*`.
Gates: `dwarf_addr_size_test`, a new `dwarf_variables_test` that walks the
emitted `.debug_info`/`.debug_abbrev` (the only in-house DWARF reader is
the line-table one in `lib/stack_trace.w`, so the test brings a small
DIE walker), `verify`, `verify_x64`, `verify_arm64`.

**C3.4 Module-dependency invalidation in wbuildd (after P1.2; parallel
with Phase 2).** `tools/wbuildd.w` invalidates by inotify and
re-runs `deps`; use `module_dependencies_invalidate` over a retained
snapshot of the last check to answer "which roots does this edit
affect" and to re-check only those. This does not make *builds*
incremental: per-definition relocation is a separate design, and this
unit writes that design into `docs/projects/incremental_compilation.md`
(what a relocatable definition record needs: code bytes, a patch list of
absolute references, a symbol/type snapshot id) rather than attempting
it.
Owns: `tools/wbuildd.w`, `compiler/module_dependencies.w`,
`tests/wbuildd_test.w`, `tests/module_dependencies_test.w`,
`docs/projects/incremental_compilation.md`, `docs/projects/wbuildd.md`.
Gates: `wbuildd_test`, `module_dependencies_test`.

**C3.5 Optimizer pass slot (#110; after S2.5).** Insert an optional
tree-rewriting pass between body parse and emission (`compiler/ast_opt.w`),
off by default, and implement two rewrites that the emission-time
peepholes in `optimization.md` cannot do: dead `if (0)`/`while (0)`
regions and constant-folded conditions. Measure `bin/wv3` size and
self-compile time with and without. The seed constraint applies to the
pass itself (it is in the compiler tree).
Owns: `compiler/ast_opt.w` (new), `tests/ast_opt_test.w` (new),
`docs/projects/optimization.md` §6.
Gates: new test, `verify` (pass off), `ast_opt_verify` (pass on, images
differ from the default by design, so this is a self-host fixpoint with
the flag, like `ast_expression_verify`), `tests`.

## 3. Ownership, conflicts and sequencing

**Waves.** Each wave is what can run concurrently; a unit starts when
the units it names have merged to `main`.

| Wave | Units in parallel | Serial gate before next wave |
| --- | --- | --- |
| 1 | P1.1, P1.2, P1.3, C3.2 | all four merged |
| 2 | P1.4 (serial), S2.1 (serial), C3.3, C3.4 | P1.4 and S2.1 merged |
| 3 | S2.2a, then S2.2b–e in parallel; P1.5a–c after a release carries P1.4 | S2.2 complete (zero immediate statements) |
| 4 | S2.3, S2.4, C3.1 | all merged |
| 5 | S2.5 (serial), then C3.5 | close #489 |

Four to five agents per wave is the practical ceiling: the shared files
below are where parallel PRs collide, and every compiler PR pays the
same `verify`/`tests` cost (about three minutes on the CI runner, more
for `ast_expression_suite`).

**Shared files and their rules.**

- `compiler/compiler.w` option parsing and `reset` blocks: a unit adds
  its flag and counters in one contiguous block tagged with the unit id
  in a comment, never reorders existing lines. P1.4 and S2.5 are the only
  units that change existing flags.
- `compiler/retained_ast.w` `retained_node`/`retained_source` structs:
  new fields are appended at the end of the struct and initialised in
  `retained_add` in the same order; no renames. P1.2 (arena) and S2.1
  (fields) both touch this file in different waves, by design.
- `tests/ast_expression_test.w` directive block (lines 3139–3169): only
  P1.4, S2.1 and S2.5 edit it, and only by appending `step=` lines to an
  existing target or adding a new `target=` block at the end. Every other
  unit puts its tests in its own `tests/ast_<unit>_test.w` with its own
  `# wbuild:` block.
- `docs/projects/ast_migration.md`: every unit appends one `## ` section
  at the end describing what landed and what it does not claim, in the
  style of the existing tasks; only P1.4 and S2.5 edit the "Current
  production migration status" and "Remaining milestones" sections.
  This document (`ast_completion_plan.md`) is updated by the
  orchestrator only, ticking units off in §2.
- `grammar/ast_expression.w`: P1.1 owns it in wave 1; S2.1 may only add
  calls to `retained_expression_note`'s neighbourhood (one hook site at
  `ast_expression_finish_prepared`). After wave 2 it is owned by S2.5.
- Dispatch sites in the streaming grammar (`grammar/statement.w`,
  `program.w`, `for_statement.w`, `switch_statement.w`,
  `variable_declaration.w`, `kernel_decl.w`): owned by P1.5 in wave 3;
  S2.2 agents must route through the existing `ast_*` hooks and not edit
  these files. If an S2.2 family genuinely needs a hook that does not
  exist, it adds one in its own `ast_*.w` file and asks the orchestrator
  to land the one-line call site.

**Branch and PR protocol.** One branch per unit named
`ast/<unit-id>-<slug>` (for example `ast/p1.1-parse-cost`), rebased on
`main` before the PR is opened, one PR per unit, draft until the gates in
§2 are green and the PR body carries the measurements the unit asks for.
The orchestrator merges in wave order; a unit whose base moved re-runs
`verify` after rebase. No unit force-pushes a branch another agent has
checked out. PR bodies follow the repository's "Before/After/How" form.

**What every agent brief must contain.** The unit's §2 entry verbatim;
the repository rules that bite here (tabs, no new syntax in the compiler
tree, fix warnings because self-host stages build with `--strict`,
`bin/wtest changed` for focused targets, `./wbuild tests` before
declaring done, `ast_expression_suite` where the unit says so); the
shared-file rules above; the instruction to measure before and after
with the exact commands in §1.1 and put the table in the PR; and the
instruction to stop and report rather than widen scope when a gate fails
for a reason outside the unit's files.

**Risks the plan accepts.**

- P1.5 removes the byte-identical streaming oracle. Mitigation is the
  one-release `seed_image_test`; after that the oracles are the
  self-host fixpoints, the executed fixtures and the cross-target image
  comparisons between modes that still exist (`--ast-emit-retained` vs.
  default until S2.5).
- S2.2 changes *when* side effects happen. The per-family rule (record
  the fact in the tree, replay it in the original order) is what keeps
  images identical; an agent that cannot keep a family byte-identical
  stops and reports which side effect is order-sensitive rather than
  accepting a differing image.
- REPL/wdbg state (the sharpest risk in wbuildd.md §3.3) is covered by
  the existing checkpoint tests; S2.4 is scheduled before S2.5 so the
  flip cannot land without them.
- The seed. Everything here is seed-compiled; agents may not use syntax
  newer than `SEEDS` (v0.3.0). P1.5 waits for a release that carries
  P1.4 only so the pinned seed keeps a streaming front end for the
  transitional comparison, not because the sources need it.

## 4. Commands that back §1

```sh
./wbuild build build_x64
for m in "" "--ast-full-expressions" "--ast-required" "--ast-retain --ast-required"; do
  time bin/wv2 $m --strict w.w -o bin/wv3_probe; cmp bin/wv3 bin/wv3_probe
done
bin/wv2 check --quiet --ast-retain --ast-required --stats w.w
time bin/wv2 check --quiet --all-errors w.w
time bin/wv2 tree --json --quiet w.w | wc -lc
./wbuild ast_expression_test ast_expression_verify ast_required_expression_verify
./wbuild ast_expression_suite        # serial; not in `tests`
```
