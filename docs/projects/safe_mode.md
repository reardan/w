# Optional ownership and borrowing checks

Status: proposed. The `--safe` flag and ownership types below are not
implemented. This plan adds an opt-in mode that checks ownership and
borrowing at compile time, with explicit boundaries for raw-pointer code.
Existing W programs keep their current behavior by default.

Implementation tracking: [issue #644](https://github.com/reardan/w/issues/644).

The goal is to prevent dangling references, use after move or destruction,
double destruction, and conflicting access through references in checked
code. The guarantee depends on the compiler and audited runtime interfaces
upholding their contracts. A flag cannot infer every existing pointer's
ownership or make arbitrary legacy libraries safe.

## Compiler interface

Proposed commands:

```sh
./bin/wv2 --safe app.w -o app
./bin/wv2 check --json --safe app.w
```

Safety violations are errors independently of `--strict`. The flag checks
application roots and imported application functions, including generic
instantiations and compiler-generated operations. Unknown or unsupported
operations are errors rather than unchecked fallbacks. Reject
`--bounds=off` and frontend modes that bypass the analysis, regardless of
option order. Keep the default mode compatible with existing code.

New ownership types have the same move, borrowing and cleanup semantics
with or without `--safe`. The flag requires checked operations throughout
application code; removing it must not change whether the same declaration
owns or destroys its storage. Raw `T*` keeps its existing semantics.

## Current foundations and gaps

The [language reference](../language_reference.md#pointers-and-arrays)
documents raw pointers and bounds-checked arrays and slices. Bounds checks
do not establish that backing storage is still alive. W currently has no
general ownership checker or automatic lifetime management.

The [arena API](../../lib/arena.w) refuses reset or destruction while
explicitly registered borrows remain outstanding. Registration is the
caller's responsibility. The [debug allocator](../../lib/memory_debug.w)
helps detect memory errors during execution; it does not establish a
compile-time safety guarantee.

The compiler already retains [syntax trees](../../compiler/retained_ast.w)
and [semantic records](../../compiler/retained_semantic.w). Normal compilation
does not retain every semantic snapshot, so safe compilation must enable
the records it needs. Retained emission is incremental: it is not yet a
general whole-function analysis pipeline. The
[recorded function representation](../../compiler/function_record_ast.w)
currently covers a limited integer subset. Extending whole-function
coverage is a dependency, tracked alongside the
[production AST plan](ast_completion_plan.md).

## Ownership model

Settle surface syntax in the first milestone. The required concepts are:

| Concept | Contract |
| --- | --- |
| Owned pointer | One owner. Assignment or argument passing transfers ownership. Normal scope exit destroys the owned value. |
| Shared reference | Multiple readers may coexist. The backing storage remains alive for every use. |
| Mutable reference | Exclusive access to the referenced storage while borrowed, including restrictions on access through its owner. |
| Optional reference | Absence is explicit and must be checked before access. |
| Raw pointer | Existing `T*`. Dereferencing or manufacturing a checked reference requires an explicit unsafe boundary. |

Infer local ownership and borrowing where unambiguous. Require function
contracts to describe ownership transfer, borrowed parameters, escape
behavior, and the relationship between returned references and arguments.
Verify function bodies against those contracts, including recursive calls
and indirect calls through typed function pointers.

Checked references must be initialized, aligned, non-null and point to a
valid value of the declared type. Checked allocation must initialize that
value and either return a valid owner or report/trap allocation failure.
Check allocation-size arithmetic before allocating. Integer casts, union
access, bytewise copies and existing implicit conversions must not provide
a route to fabricate a reference or duplicate an owner.

Borrow lifetimes end after their last use where analysis can establish it.
Track fields separately when disjointness is proven; conservatively treat
potentially overlapping indexed accesses as conflicting. Initially reject
partial moves out of aggregates and reference-bearing aggregate patterns
without implemented lifetime rules.

## Unsafe boundaries and library contracts

Introduce explicit unsafe operations or blocks for raw-pointer
dereferences and arithmetic, pointer/integer conversions, unchecked foreign
calls, assembly and conversion from raw storage to checked references.
Unsafe code must still uphold the contracts of checked values it creates
or exposes; the boundary does not make invalid accesses well-defined.

Imported application code must be checked or reached through an explicit
unsafe interface. Do not trust an entire module because it was imported,
has a library path, or suppresses diagnostics. Existing auto-imported
container runtimes and on-demand libraries need a small audited interface
whose contracts are tied to the resolved implementation. Treat those
implementations as part of the trusted runtime, and invalidate checked
results when their code or contracts change.

Start with allocation, destruction, borrowing, bounds-checked slices and
minimal output interfaces. Add safe container interfaces only after modeling
reference invalidation: growth, clear, removal, replacement and destruction
can invalidate references into storage. Slices and strings need provenance
and lifetime tracking even though their runtime layout already includes a
length. Their raw data fields cannot bypass these restrictions.

## Implementation milestones

### 1 Specify semantics and add the compiler option

Write the ownership syntax and conversion rules, call contracts, nullability,
scope rules, cleanup order and unsafe boundary syntax before implementing
them. Specify representative accepted and rejected programs. Decide how
allocation failures and optional references are expressed using W's type
system; these are prerequisites for checked allocation.

Add option parsing, help, session reset and diagnostics in
[compiler/compiler.w](../../compiler/compiler.w). Thread the option through
normal compilation, structured checks and in-process compilation. Extend
[type records](../../compiler/type_table.w), retained types and bindings to
preserve qualifiers and contracts through aliases, casts and signatures.

Acceptance: default-mode fixtures retain their behavior; option conflicts
are deterministic; safe mode cannot report success for a construct whose
checking is not implemented. Keep the mode experimental until the usable
subset below passes its release gates.

### 2 Represent control flow and memory operations

Build an architecture-independent analysis representation from resolved
syntax and stable binding identities. Represent locals, field projections,
indexed storage, initialization, reads, writes, moves, borrows, calls and
destruction. Add edges for branches, loops, short-circuit expressions,
returns, break/continue and cleanup. Preserve source spans for every event.

Require complete analysis coverage for each admitted function. Extend the
whole-function pipeline where incremental retained emission lacks required
structure; do not assume the existing scalar recording API already supports
pointers or calls. Perform ownership analysis before lowering cleanup and
before publishing a binary or executing generated code.

Acceptance: fixtures inspect operation order and control-flow edges for
every admitted construct, including implicit conversions and generated
container calls. Unmodeled paths fail explicitly.

### 3 Check ownership and borrow lifetimes

Track each owned location as uninitialized, live or moved. Compute reference
provenance and borrow liveness across control-flow joins and loop backedges
until the analysis converges. A value must be valid on every incoming path
where it is used. Reborrowing must suspend conflicting access through the
parent reference for the duration of the child borrow.

Reject use after move/destruction, destruction or movement while borrowed,
conflicting accesses, references to expired stack storage, and uncontracted
escapes through returns, globals, fields or calls. Check function bodies
against declared contracts, and callers against the same contracts.

Use [structured diagnostics](../../compiler/diagnostics.w) with stable codes
and related locations: show the failing operation, the borrow or move that
caused it, and the later use keeping a borrow alive. These must be real
errors in both compilation and `check --json`.

Acceptance: positive fixtures cover valid transfer, sharing, exclusive
borrows and reborrows. Negative fixtures cover each rule on straight-line,
branching and looping paths, including recursive and imported calls.

### 4 Lower cleanup and integrate safe interfaces

Generate destruction for owned values at normal scope exits, returns,
break and continue. Define replacement assignment, field destruction order
and partially initialized construction. Initially reject unsupported
construction patterns. Preserve return values and transfer ownership before
cleaning up the remaining locals. Use conditional cleanup state only where
control flow requires it, so a value is destroyed at most once.

Model W's existing [defer semantics](defer.md): deferred expressions observe
values at exit, and returns evaluate their result before deferred work.
Specify the exact ordering between these expressions and automatic
destruction. Do not assume dynamic defer registration when the existing
emitter has different behavior. Reject ambiguous or unmodeled combinations,
including a deferred free that duplicates an owner's cleanup.

Ship the minimal audited allocation and slice interfaces, then extend
containers with invalidation-aware contracts. Define cleanup behavior on
termination and traps without promising cleanup on paths that cannot run it.

Acceptance: runtime fixtures count destruction across early exits, moves,
replacement, branch-dependent initialization and defer interactions. Invalid
container growth or destruction during a live borrow fails at compile time.

### 5 Integrate compiler sessions and build tooling

Include the safety mode, ownership contracts, compiler version, target and
relevant source dependencies in cached answers. Verify the existing cache
keys before adding new key components. Update function dependency hashes
when public ownership or lifetime contracts change.

Checkpoint and roll back analysis state with the existing compiler session.
Keep compile/check results consistent. Reject safe REPL execution until
persistent bindings, replacement, cleanup and cross-entry borrows are
modeled. Likewise, do not allow debugger evaluation or another in-process
entry point to silently ignore a requested safety mode.

Acceptance: toggling flags, editing imported contracts, failed compiles and
session rollback cannot reuse stale safe results or corrupt subsequent
checks. Document which targets and entry points support the experimental
mode; reject unsupported combinations.

### 6 Release a bounded safe subset

The first usable release supports ordinary single-threaded functions,
owned heap values, stack references, arrays/slices, structured branches and
loops, and simple borrowing across calls. Ship automatic cleanup and the
audited library interfaces with that release.

Initially reject constructs lacking rules: generators with borrows across
suspension, shared mutable globals, uncontracted callbacks, GPU memory,
cross-thread ownership transfer, unsafe aggregate representations and
arbitrary goto paths. Add each only with implemented rules and tests.
Raw interoperation remains possible through explicit unsafe interfaces.

Acceptance: the documented safe subset works end to end, unsupported cases
fail closed, and the full compatibility, coverage and performance gates
below pass. A diagnostics-only prototype is an intermediate milestone,
not the completed safe mode.

## Cost and compatibility

Ownership and borrow analysis run at compile time. Preserve ordinary
pointer width for references to sized values and existing slice layouts;
do not add a reference count or garbage collector. Runtime work consists
of required allocation/destruction, existing bounds checks, any necessary
allocation validation, and conditional cleanup flags where needed.

Measure compilation time, peak compiler memory, generated code size and
runtime on a fixed corpus. Compare checked programs with equivalent manual
cleanup programs, and measure the additional cost of semantic retention
separately. Do not promise zero runtime overhead or a compile-time budget
before measurements exist. Default compilation must not allocate or run
ownership-analysis state unnecessarily.

Keep compiler and auto-imported runtime implementation code compatible with
the pinned seed. New syntax is usable in leaf tests after the compiler
supports it. Migrate bootstrap sources only after a release containing that
syntax and an update of every `SEEDS` entry, following the
[release process](../release.md). A local seed promotion is insufficient.

## Verification gates

- Add conventional `*_test.w` hosts and compile-error fixtures with their
  `# wbuild:` and expected-diagnostic directives. Cover both accepted and
  rejected programs rather than testing only diagnostic wording.
- Update `tests/parser_generator/w.pg` whenever surface syntax changes.
- Check compiler edits through `./bin/wv2 check --json w.w`, fixing warnings
  as well as errors. Use `bin/wtest changed` to select focused targets and
  `bin/wtest archs <file> --check` for files used under multiple targets.
- Require self-host fixpoints (`verify` and `verify_x64` for lowering or
  word-size changes), self-host warning checks and the full `./wbuild tests`.
- Exercise at least 80 percent of changed executable compiler lines with
  the coverage workflow. Raise directory coverage floors when tests raise
  measured coverage.
- Include cross-target compilation and available runtime tests. Track
  unsupported targets explicitly until equivalent cleanup and diagnostics
  are verified.
- Compare default-mode behavior and representative emitted binaries against
  the baseline. Differential tests must also confirm that safety checks run
  before optimizations and are not lost through aliases, casts, generic
  specialization or library calls.

The implementation is complete for its declared subset when checked code
cannot bypass ownership rules, cleanup and library contracts work together,
legacy default-mode programs retain their behavior, and the guarantees,
unsafe boundary and measured costs are documented in the language reference.
