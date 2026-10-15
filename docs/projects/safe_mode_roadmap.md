# Ownership and borrowing roadmap

Status: the experimental Linux x86/x64 subset was implemented in
[PR #648](https://github.com/reardan/w/pull/648). The broader work remains
tracked by [issue #644](https://github.com/reardan/w/issues/644).
The [safe-mode reference](safe_mode.md) describes the supported syntax,
guarantees, restrictions and measured costs. This document preserves the
remaining design from [PR #645](https://github.com/reardan/w/pull/645);
proposals below are not additional supported features.

The goal remains to prevent dangling references, use after move or
destruction, double destruction and conflicting reference access in checked
code. That guarantee depends on compiler correctness and audited runtime
contracts. It does not make arbitrary legacy W code memory-safe.

## Implemented foundation

The original option, analysis, cleanup and bounded-release milestones have
been delivered for the documented subset. Further work should extend this
implementation rather than introduce a second ownership model.

| Area | Available behavior | Remaining scope |
| --- | --- | --- |
| Compiler interface | `--safe`, structured diagnostics, deterministic option conflicts, unsupported-target errors | More targets and in-process execution |
| Pointer contracts | Contextual `own T*`, `ref T*`, `refmut T*`; qualifiers survive aliases; ownership semantics also apply without `--safe` | Optional references, escaping lifetime contracts and reference-bearing aggregates |
| Analysis | Resolved binding identities, initialization/move state, borrow provenance, last-use liveness, reborrows, branch joins and loop backedges | More control-flow forms and more precise projections |
| Calls | Direct, imported and recursive calls; forward declarations checked against implementations; owned returns | Borrowed returns, indirect calls, callbacks, methods and unmodeled generic operations |
| Cleanup | Reverse-order destruction on scope exit, return, break and continue; replacement, parameters and inferred owner moves | Deferred expressions, partial construction and aggregate destruction rules |
| Storage and libraries | Pointer-free values, fixed arrays, immutable slices, audited allocation/destruction/bounds operations and scalar output | Safe containers, strings, arena lifetimes and richer raw interoperation |
| Tooling | Compiler-session resets, safety-option fingerprints, source/contract invalidation, compile/check consistency | Persistent REPL/debugger bindings and cross-entry lifetimes |

The checker in [compiler/safe.w](../../compiler/safe.w) uses resolved
[retained semantic records](../../compiler/retained_semantic.w). Application
records are retained before later imported contracts can be discovered;
ownership graphs are allocated only when checking is needed. Analysis runs
before an output artifact is published. Future emission changes must preserve
that gate and every transfer, cleanup and diagnostic obligation.

## Remaining milestones

### 1. Optional references and escaping lifetime contracts

Specify an explicit absence representation and require a presence check
before dereferencing an optional reference. Ordinary `ref` and `refmut`
remain initialized, aligned, non-null references to valid values. Do not
make null a valid value of an existing checked reference type.

Define how a function signature relates a returned reference to arguments
or other permitted backing storage. Verify bodies and callers against the
same contract, including recursion and imported declarations. A returned
reference must not outlive a stack local, owner or temporary that backs it.
The current implementation rejects borrowed returns and slice returns.

Acceptance: positive and negative fixtures cover presence checks, returned
views, nested reborrows, branch joins and loop backedges. Removing `--safe`
must not weaken an explicit ownership or lifetime contract.

### 2. Aggregate ownership and more precise storage projections

Specify construction, field destruction order and partially initialized
state before admitting reference-bearing aggregates. Preserve qualifiers
through aliases, conversions and signatures. Integer casts, unions,
bytewise copies and implicit conversions must not fabricate references or
duplicate owners.

Track fields separately where disjointness is proven. Keep possibly
overlapping indexed accesses conservative. Partial moves require both
per-field move state and matching destruction behavior; they remain
unsupported until both are implemented. Reference-bearing globals need
explicit lifetime and mutation rules rather than an exemption from checking.

Acceptance: tests cover disjoint and overlapping projections, partial
construction and destruction, aliasing conversions, and every aggregate
copy/move path admitted by the extension.

### 3. Containers, strings and audited library interfaces

Model invalidation before adding checked container operations: growth,
clear, removal, replacement and destruction can invalidate references into
storage. Strings and views need backing-storage provenance even when their
runtime representation already carries a length. Raw `.data` fields must
not bypass these rules.

The [arena API](../../lib/arena.w) currently relies on callers registering
borrows. Design a checked contract connecting those borrows to reset and
destruction; runtime registration alone is not a compiler lifetime proof.

Extend the existing allocation, destruction, bounds and output interfaces
incrementally. Keep audited contracts tied to their resolved implementations
and invalidate cached results on either kind of change. Importing a module,
using a library path or suppressing diagnostics must never grant trust.
Checked allocation must initialize storage, validate size arithmetic and
return a valid owner or report/trap allocation failure.

Acceptance: valid container/view programs execute; invalidation during a
live borrow fails at compile time. Shadowed or changed runtime implementations
cannot inherit an old audited contract.

### 4. Additional control flow, deferred work and call forms

Extend the resolved analysis graph for each new construct, including its
implicit reads, writes, calls, transfers and cleanup edges. Complete analysis
coverage is required for every admitted function. Unsupported `for`,
`switch`, generators and arbitrary `goto` paths must continue to fail until
their rules are implemented.

Integrate W's [defer semantics](defer.md) explicitly: deferred expressions
observe values at exit, and return expressions are evaluated before deferred
work. Specify ordering relative to automatic destruction and include deferred
reads in borrow liveness. Do not assume dynamic defer registration when the
existing emitter behaves differently. Reject a deferred free that would
duplicate automatic cleanup. Cleanup is still not promised after termination
or a trap.

Indirect calls, callbacks, methods and generic specialization need contracts
that survive resolution and instantiation. Generator suspension, GPU memory,
shared mutable globals and cross-thread ownership transfer each need their
own lifetime and aliasing rules; support for one does not imply the others.

Acceptance: inspect event order and control-flow edges, test both accepted
and rejected cases, and observe destruction at runtime across every newly
admitted exit or suspension path.

### 5. Richer unsafe interoperation

The current `unsafe:` block permits raw operations but cannot manipulate
checked pointers, call checked-pointer contracts, transfer control out of
the block or defer work. Keep this restriction until richer interfaces have
specified and tested ownership and lifetime obligations.

Design audited transitions for foreign calls, raw storage, assembly and
conversion from raw pointers to checked references. Such a transition must
establish alignment, initialization, lifetime and aliasing requirements;
the boundary cannot make invalid accesses well-defined. Unsafe code must
continue to uphold the contracts of any checked storage it can affect.

Acceptance: explicit interoperation works without enabling a cast, foreign
call or generated helper to bypass transfer or cleanup rules.

### 6. More targets, compiler sessions and optimization

Verify equivalent cleanup and diagnostics before admitting another target.
Keep unsupported target and frontend combinations explicit. In-process REPL
and debugger execution remain rejected until persistent bindings,
replacement, cleanup, cross-entry borrows and failed-entry rollback are
modeled together.

Audit cache keys and dependency hashes when introducing public lifetime
contracts or new session state. Mode, target, compiler identity and relevant
source/contract changes must invalidate checked answers. Toggling options,
editing imported contracts or recovering from an error must not reuse stale
results or corrupt subsequent checks.

The current inliner excludes functions with checked pointer parameters,
results or locals. Relax that restriction only when transformations preserve
ownership operations and their ordering. Use differential tests for aliases,
casts, specialization and library calls; optimization must not erase checks.

Acceptance: compilation and structured checking agree, cross-target runtime
tests observe the same destruction behavior, and session rollback and cache
invalidation tests cover the new state.

## Cost, compatibility and bootstrap discipline

Use the [existing measurements and fixtures](safe_mode.md#measured-costs)
as the starting point. Ordinary compilation currently retains application
semantic records even without `--safe`; on the measured compiler corpus that
cost about 24% more time and 38% more peak memory. Reducing that retention cost
is remaining work. Any optimization must still discover a later imported
contract without losing earlier binding identities.

Measure compile time, peak memory, emitted code size and runtime on a fixed
corpus. Compare checked programs with equivalent manual cleanup, and isolate
retention costs from ownership-analysis costs. Preserve ordinary pointer
width for references to sized values and existing slice layouts; do not add
reference counting or garbage collection implicitly. Do not promise zero
overhead or a fixed compilation budget without measurements.

Keep legacy raw-pointer behavior compatible. Explicit ownership types must
retain their transfer and destruction semantics with or without `--safe`.
Keep compiler and auto-imported runtime implementation code compatible with
the pinned seed. New syntax may be used in leaf tests once supported, but
bootstrap sources may adopt it only after a release and an update of every
`SEEDS` entry under the [release process](../release.md). A local seed
promotion is insufficient.

## Verification and completion gates

- Add conventional `*_test.w` hosts and diagnostic fixtures covering
  accepted programs, rejected programs and actual runtime behavior.
- Extend `tests/parser_generator/w.pg` for every new surface syntax form.
- Check compiler edits with `bin/wv2 check --json w.w`, fixing warnings too.
  Select tests with `bin/wtest changed` and check each compiled architecture
  with `bin/wtest archs <file> --check`.
- Require self-host fixpoints, `verify_x64` for lowering or word-size changes,
  warning checks and the full `./wbuild tests` suite.
- Exercise at least 80% of changed executable compiler lines; raise coverage
  floors when tests improve coverage.
- Use guard-allocator/runtime checks for leaks and duplicate destruction,
  and cross-target execution wherever support is claimed.
- Preserve stable diagnostic codes and related locations. Extend diagnostics
  to show the later use keeping a borrow live where that context is needed.
- Compare legacy behavior and representative emitted binaries with the
  baseline, run the performance gate, and publish measured costs.

Each extension is complete only when its documented subset works end to
end, unsupported cases still fail explicitly, cleanup and library contracts
agree, and the usage reference records its guarantees and limitations.
Issue #644 remains open for the broader roadmap.
