# Ownership and borrowing roadmap

Status: the experimental Linux x86/x64 subset was implemented in
[PR #648](https://github.com/reardan/w/pull/648), and reference returns tied
to a sole borrowed input landed in [PR #663](https://github.com/reardan/w/pull/663).
The broader work remains tracked by
[issue #644](https://github.com/reardan/w/issues/644).
The [safe-mode reference](safe_mode.md) describes the supported syntax,
guarantees, restrictions and measured costs. This document preserves the
remaining design from [PR #645](https://github.com/reardan/w/pull/645) and
turns it into the implementation plan below. The bounded first delivery is
implemented as described below. The follow-on implementation adds bounded
optional references, range loops and scalar switches, outer-function
deferred expressions, single-group mutable-reference records,
checked methods and concrete generic calls,
owned-integer buffers, byte arenas
and win64 support. The remaining requirements below are not all delivered.

The goal remains to prevent dangling references, use after move or
destruction, double destruction and conflicting reference access in checked
code. That guarantee depends on compiler correctness and audited runtime
contracts. It does not make arbitrary legacy W code memory-safe.

`--safe` does not ban pointers: `own T*`, `ref T*` and `refmut T*` are the
checked pointer forms. Raw `T*` operations require the documented unsafe
boundary. Extending the safe subset must preserve that distinction and
continue to reject constructs whose effects the checker cannot model.

## Implemented foundation

The original option, analysis, cleanup and bounded-release milestones have
been delivered for the documented subset. Further work should extend this
implementation rather than introduce a second ownership model.

| Area | Available behavior | Remaining scope |
| --- | --- | --- |
| Compiler interface | `--safe`, structured diagnostics, deterministic option conflicts, unsupported-target errors | More targets and in-process execution |
| Pointer contracts | Contextual ownership qualifiers, named reference lifetimes, optional references with presence refinement, aliases and explicit contracts without `--safe` | General outlives clauses and higher-ranked contracts |
| Analysis | Resolved identities, initialization/moves, sets of backing roots and reborrow parents, last-use liveness, branch joins, range loops and scalar switches | Container iteration and more precise projections |
| Calls | Direct/imported/recursive calls, checked methods and concrete generic calls, alpha-equivalent forward contracts, owned returns and checked reference/slice/borrowed-record returns | Indirect calls, callbacks and unmodeled generic operations |
| Cleanup | Reverse-order destruction on supported exits, replacement, parameters, owner moves, recursive owner-bearing struct destruction and outer-function `defer` | Nested defer registration, partial moves and mixed borrowed/owned aggregate fields |
| Storage and libraries | Fixed arrays, inline checked slices, single-group shared/exclusive borrowed structs, owned structs, opaque integer/owned-integer buffers, byte strings and byte arenas | Generic containers, maps/sets, general arenas and richer raw interoperation |
| Tooling | Compiler-session resets, safety-option fingerprints, source/contract invalidation, compile/check consistency | Persistent REPL/debugger bindings and cross-entry lifetimes |

The checker in [compiler/safe.w](../../compiler/safe.w) uses resolved
[retained semantic records](../../compiler/retained_semantic.w). Application
records are retained before later imported contracts can be discovered;
ownership graphs are allocated only when checking is needed. Analysis runs
before an output artifact is published. Future emission changes must preserve
that gate and every transfer, cleanup and diagnostic obligation.

## Implementation sequence and parallel agents

The first implementation follows D0, L1–L3, a bounded A1/A2, and concrete
C1/C2. [Contract decisions](safe_mode_contracts.md) record the chosen
representations and trust boundaries. The [usage guide](safe_mode.md) records
the accepted syntax and validation evidence. In particular:

- Named labels express shared result/input lifetime relationships; general
  outlives clauses remain unimplemented.
- Borrowed structs carry one lifetime group across shared or mutable pointer
  fields and shared checked-slice fields. Mutable-reference fields require
  an exclusive `refmut Record` wrapper; copies are reborrows. Multiple
  independent groups and nested borrowed structs
  remain rejected.
- Owned structs use `own Record*`, complete heap constructors and acyclic
  recursive destruction. Mixed lifetime-bearing owner fields, partial field
  moves and unwinding remain outside this stage.
- C1 exposes a concrete integer buffer; C2 exposes arbitrary byte strings.
  Both use direct functions, opaque metadata and shared views. General
  element types, UTF-8 invariants, optional pop and self-append are not added.

The remaining A2/A3/F2/F3/C3/U1/T1/P1 scope retains the gates below.
The parallel agents implemented syntax/emission, analysis and independent
adversarial tests in isolated worktrees; the integrator combined them and
added the concrete runtime, arithmetic checks, documentation and release
gates. This does not establish Rust-equivalent coverage or prove soundness.

The first delivery target is useful **single-threaded** checked programming:
functions with explicit lifetime contracts, borrowed fields, owned aggregate
cleanup, a growable buffer of pointer-free elements, and owned byte strings
with borrowed views. It is not a Rust-equivalence or soundness certification.
Thread safety, general callbacks and additional targets have separate gates.

Each row below is a proposed PR boundary. Split a row further if its parser,
checker and lowering work cannot be reviewed together; do not enable its
surface syntax until body checking, caller checking and emission agree.
Dependencies mean merged prerequisites, not concurrent edits against an
unreviewed interface. The detailed milestone sections below remain the
design requirements for these PRs.

| ID | Deliverable | Depends on | Required evidence before merge |
| --- | --- | --- | --- |
| D0 | Contract design and adversarial baseline: specify lifetime syntax, normalized signatures, provenance, descriptor ownership, aggregate initialization and library effects | Current subset | Reviewed examples of accepted/rejected programs; regression fixtures for current behavior; no new constructs accepted |
| L1 | Internal lifetime/provenance representation supporting multiple possible backing roots and reborrow ancestry; retain sole-input inference | D0 | Existing behavior unchanged; branch/loop joins retain every possible root; imported, recursive and forward-declared contracts agree |
| L2 | Named lifetime parameters and result/outlives relationships for direct reference-returning functions | L1 | Body and call-site constraints tested across aliases, multiple inputs, nested calls, recursion and declaration mismatches |
| L3 | Returned slices with explicit descriptor storage, ownership and cleanup rules | L2 | Nested slice returns and empty views execute on x86/x64; neither data nor descriptor escapes its lifetime; no descriptor leaks or double frees |
| A1 | Shared-reference-bearing structs with explicit construction and lifetime parameters; conservative whole-value borrowing | L2; L3 before slice fields | Borrowed field cannot outlive its backing value; moves and copies preserve all field lifetimes; invalid zero initialization rejected |
| A2 | Owner and mutable-reference fields with whole-value moves, construction state and recursive destruction | A1 | Exactly-once cleanup on every supported exit and replacement, including partially initialized construction; copying owners or exclusive references rejected |
| A3 | Proven-disjoint field borrowing and partial moves | A2 | Per-field move/init state agrees with emitted cleanup across replacement, branches and parent moves; uncertain index overlap stays conservative |
| O1 | Optional references with explicit absence and flow-sensitive presence checks | L2 | Dereference requires a dominating valid check; reassignment, branch joins and loops invalidate stale refinements |
| C1 | Audited owned growable buffer/list for pointer-free elements, exposed initially through sealed concrete types and direct functions | A2, L3 | Checked size arithmetic, initialization and bounds; live views block mutation that can invalidate them; moves and destruction tested |
| C2 | Owned byte strings and borrowed string views over the C1 storage contract | C1 | Append/growth, conversion, empty values and embedded NULs preserve ownership and bounds; borrowed views block invalidation |
| F1 | Checked `for` and `switch`, one construct per PR | L1 | Every implicit access and control-flow edge modeled; cleanup and liveness checked across exits, loop backedges and switch paths |
| F2 | Checked `defer` with exit-time liveness and defined cleanup ordering | A2, F1 | Return evaluation, deferred accesses, nested exits and destruction have the specified runtime order |
| F3 | Checked methods and generic specialization, followed by indirect calls/callbacks in separate PRs | L2, A2 | Receiver/argument effects and lifetime contracts survive desugaring, type identity and instantiation; incompatible function values rejected |
| C3 | Owned-element containers, then maps/sets, each as a separate extension | C1, O1, F3 | Element moves/drop, replacement, removal, hashing/equality calls and iteration invalidation covered; no byte-copy duplication of owners |
| U1 | Explicit audited raw/foreign boundaries and arena reset/drop contracts | L2, A2 | Boundary establishes validity and provenance; arena reset cannot invalidate live views; raw escape cannot bypass checking |
| T1 | Transfer/share type rules and an audited concurrency subset, in separate rule/runtime PRs | A2, F3, U1 | Cross-thread ownership and shared access validated; unsupported payloads rejected; runtime synchronization and cleanup reviewed |
| P1 | Additional targets, persistent compiler sessions and ownership-preserving optimizations, each independently gated | Required feature contracts above | Target/runtime parity, failed-entry rollback, cache invalidation and optimized/unoptimized differential tests |

O1, F1 and adversarial testing can progress while aggregate work proceeds.
The first delivery target requires D0, L1–L3, A1–A2 and C1–C2; it can use
direct calls, existing `while` loops and trapping bounds/allocation failures.
Optional returns, generic collection wrappers and callbacks are not hidden
prerequisites for that bounded release. C3 should not delay that release.

### Agent ownership and integration order

Use one integrating agent and up to three implementation subagents. Start
each wave from the same reviewed base, with separate worktrees and separate
`bin/` outputs. Agents return commits, assumptions, test commands/results and
remaining restrictions. The integrator merges prerequisites in dependency
order and runs the combined gates; passing isolated branches is insufficient.

| Wave | Subagent A: contracts and analysis | Subagent B: storage and libraries | Subagent C: adversarial validation | Integrator |
| --- | --- | --- | --- | --- |
| 0 | D0 lifetime/provenance proposal | D0 descriptor, construction and library-effect proposal | Audit current rejects; assemble interaction matrix and minimized fixtures | Resolve representation/syntax decisions; merge D0 |
| 1 | L1, then L2 | Audit slice allocation/return paths for L3; prototype runtime contracts without enabling calls | Extend import, branch, loop, alias and reborrow cases | Merge schema changes first; review every new accepted path |
| 2 | A1, then A2 | L3, then C1 runtime work against agreed interfaces | Slice/aggregate destruction and invalidation tests; prepare F1 graph cases | Serialize shared checker/emitter edits and integrate L3 before C1 |
| 3 | O1 or F1/F2, one checker owner at a time | C1, then C2 public APIs and fixtures | End-to-end examples, heap checks, differential and mutation tests | Publish the bounded release after its complete acceptance matrix |
| Later | A3/F3, then transfer/share rules | C3, U1 and concurrency runtime after prerequisites | Boundary, concurrency, target and session audits | Schedule T1/P1 as separate feature releases |

The integrating agent assigns a single writer for shared
`compiler/safe.w`, `compiler/retained_semantic.w`, `compiler/type_table.w`,
grammar and cleanup-emission changes in each wave. Library work can proceed
in `lib/` and `structures/`, and tests in distinct fixture files, once the
contract interface is agreed. A second agent needing a shared-file change
submits an interface request or patch to its owner instead of racing it.
Runtime allowlist/hash changes in `compiler/safe_runtime.w` follow the same
rule. Do not rebuild a shared compiler/test binary while another agent uses
it; worktree isolation includes generated manifests and caches.

### Decisions that D0 must settle

- Define lifetime syntax and normalized parameter identities before parser
  work. Keep the current sole-borrowed-input rule as an inferred shorthand;
  require explicit contracts for ambiguous inputs. Specify outlives checks,
  declaration/definition equivalence under parameter renaming, and invariant
  mutable access before permitting lifetime substitution. Contracts must
  survive imports, aliases, specialization and cache invalidation.
- Replace single-root assumptions with provenance that can constrain every
  possible backing value. A function choosing between two inputs must keep
  both lifetimes constrained at its caller; a branch join cannot silently
  choose one root. Preserve reborrow ancestry as well as root identity.
- Audit array, slice and returned-view layouts. Slice creation currently
  allocates a descriptor in `grammar/postfix_expr.w`; data lifetime and
  descriptor lifetime are separate obligations. Choose descriptor copying,
  transfer and cleanup rules without allowing metadata borrows to escape or
  expose mutable bounds. Preserve the legacy ABI or explicitly isolate a
  new checked representation with verified lowering at every boundary.
- Require valid construction of reference-bearing values; today's
  zero-filled `new T` cannot initialize non-null reference fields. Define
  initialized-field state, construction failure and destruction order.
  Start with whole-value moves and whole-root borrows. Partial moves,
  disjoint-field precision, self-referential values and checked globals
  remain rejected until separately modeled.
- Specify checked container identity, move/copy behavior, element validity,
  borrowed-view effects and destructor obligations. Existing `list[T]`
  assignment aliases a runtime pointer; do not silently change legacy
  semantics or accept that aliasing as unique ownership. Decide the checked
  type/API surface before implementing a public library.

## Detailed milestone requirements

### 1. Optional references and escaping lifetime contracts

`optref[a] T*` and `optrefmut[a] T*` use pointer-sized zero for absence.
Flow-sensitive presence checks are required before access; joins, loop
backedges, reassignment and lexical exits invalidate stale evidence.
Replacement conservatively retains possible origins and reborrow ancestry.
Optional aggregate fields and optional owned values are not supported.
Ordinary `ref` and `refmut`
remain initialized, aligned, non-null references to valid values. Do not
make null a valid value of an existing checked reference type.

Unannotated reference returns use a bounded signature contract: exactly one
borrowed input supplies the result's backing-storage lifetime. Bodies must return a
reference derived from that input; callers preserve provenance and reborrow
ancestry through nested, recursive and imported calls. Mutable results require
a mutable borrowed input. This rule applies with or without `--safe` and
supports references into pointer-free structs and array/slice elements.

Named lifetime relationships between multiple borrowed inputs and results
and explicit inline slice returns are now implemented. Unannotated ambiguous
reference-return signatures remain rejected. A returned reference
must not outlive a stack local, owner or temporary that backs it; admitting
additional contracts must preserve body and caller checks against the same
signature, including recursion and imported declarations.

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

The legacy [arena API](../../lib/arena.w) relies on callers registering
borrows. The separate checked `WByteArena` in `lib.safe_buffer` now ties
copied byte views to its owner and requires exclusive access for copy,
reset and release. General arena allocation, typed objects and attached
budgets still require contracts; runtime registration alone is not a
compiler lifetime proof.

Extend the existing allocation, destruction, bounds and output interfaces
incrementally. Keep audited contracts tied to their resolved implementations
and invalidate cached results on either kind of change. Importing a module,
using a library path or suppressing diagnostics must never grant trust.
Checked allocation must initialize storage, validate size arithmetic and
return a valid owner or report/trap allocation failure.

For C1, specify construct, move, destroy, length, push, indexed read/write,
shared view, pop-by-value and clear. Start with exclusive access to the whole
container for mutation, even when spare capacity would avoid relocation.
Mutation becomes legal again after the last live view use. Define empty-pop
behavior explicitly; the initial API may trap, with optional results added
after O1. Each operation's contract must identify its borrows, moves,
destruction, invalidation and returned view's backing resource. Metadata
stays opaque to checked callers. C1 extends narrowly audited compiler/runtime
interfaces; it does not depend on opening general U1 raw-to-checked conversions.

Existing list removal and insertion use raw byte copies, and clear changes
the length without recursively dropping owned elements. Existing map cleanup
does not recursively destroy owned values. C3 therefore needs generated or
audited element move/drop operations, including valid ownership state after
failed insertion, before it can accept owners as elements. Start maps with
a closed set of key/value operations; user hashing/equality and escaping
iterators need their own checked contracts. The bounded C3 implementation
uses a separate opaque `WOwnedIntBuffer`: push and replacement consume an
`own int*`, pop transfers it, shared element views constrain the whole
buffer, and clear/destruction drop every retained element. This does not
change the legacy containers or implement generic element operations.

For C2, define byte indexing and embedded-NUL behavior; UTF-8 validity is a
separate invariant unless the API explicitly enforces it. Append takes a
bounded view. Reject self-append under ordinary exclusive borrowing until
an overlap-safe operation is separately audited. In
`structures/string.w`, `string_builder_to_string` aliases the builder's
storage through a new descriptor, whereas `__w_template_finish` transfers
storage ownership. Neither operation becomes safe merely by adding its
source hash to the trusted list: descriptor and storage cleanup must agree
with the exposed contract.

Split U1 into raw-boundary and arena PRs. Arena views must constrain reset,
release and destruction, and attached budgets must outlive their use. Begin
with conservative exclusive allocation; permitting allocation alongside live
views requires proof of nonmoving storage and disjoint initialization.

Acceptance: valid container/view programs execute; invalidation during a
live borrow fails at compile time. Shadowed or changed runtime implementations
cannot inherit an old audited contract.

### 4. Additional control flow, deferred work and call forms

Extend the resolved analysis graph for each new construct, including its
implicit reads, writes, calls, transfers and cleanup edges. Complete analysis
coverage is required for every admitted function. Container iteration,
generators and arbitrary `goto` paths must continue to fail until their
rules are implemented. Range loops and scalar switches are implemented.

Bound F1 initially to range `for` and scalar `switch`; container iteration
comes with container invalidation contracts. Check that range arguments and
switch scrutinees evaluate once, loop `continue` reaches the increment,
switch `break` exits the switch and nested `continue` reaches its enclosing
loop. Preserve W's no-fallthrough switch behavior.

Integrate W's [defer semantics](defer.md) explicitly: deferred expressions
observe values at exit, and return expressions are evaluated before deferred
work. Specify ordering relative to automatic destruction and include deferred
reads in borrow liveness. Do not assume dynamic defer registration when the
existing emitter behaves differently. Reject a deferred free that would
duplicate automatic cleanup. Cleanup is still not promised after termination
or a trap.

Methods and concrete generic specialization now use the same checked call
contracts after resolution and instantiation. Indirect calls and callbacks
still need explicit contracts. Generator suspension, GPU memory,
shared mutable globals and cross-thread ownership transfer each need their
own lifetime and aliasing rules; support for one does not imply the others.

Split F3 into methods with explicit receiver effects, generic specialization,
and typed noncapturing indirect calls/callbacks. Keep capturing or escaping
callbacks rejected until capture storage, environment destruction and
lifetimes are modeled. Lifetime-erasing function conversions must fail.

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

### 7. Thread safety and shared state

T1 must first specify structural eligibility for transferring an owned value
between threads and sharing a reference across threads: the obligations
served by Rust's `Send` and `Sync`, without assuming W already has equivalent
traits. Eligibility must account for fields, borrowed lifetimes, interior
mutation, runtime resources and explicitly nontransferable types. A unique
owner alone does not prove its payload is safe to transfer.

Then expose a small audited spawn/join and synchronization API. Specify
ownership on spawn failure, child completion and join; define atomics and
lock-protected access before permitting shared mutation. Detached work cannot
retain a borrowed stack value. Scoped borrowing requires a proven join before
the backing storage expires. Existing raw threading APIs and a serialized
allocator are not sufficient to admit checked concurrency.

Acceptance: compile-fail cases cover nontransferable payloads, escaping stack
borrows, invalid shared mutation and locks/views used outside their guard
lifetime. Runtime tests cover transfer, failure cleanup, join and lock release;
independent review covers the synchronization and memory-ordering contract.
Stress tests supplement that review rather than prove race freedom. GPU
memory, generator suspension and shared mutable globals retain separate gates.

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
width for references to sized values and the legacy slice ABI. If D0 chooses
a distinct checked descriptor representation, review and measure every
conversion boundary explicitly. Do not add reference counting or garbage
collection implicitly. Do not promise zero overhead or a fixed compilation
budget without measurements.

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
- Run rebuilt accepted fixtures under `bin/wgrind --native` and, where
  installed, `bin/wgrind` Memcheck, following the
  [heap-checking guide](../testing.md#heap-checking-with-wgrind). Use explicit
  leak reports in native mode. Record absent Memcheck coverage as skipped;
  require a run on a provisioned host before claiming that validation.
  Neither tool proves aliasing correctness or detects every stale pointer
  after address reuse. Execute on every target for which support is claimed.
- Preserve stable diagnostic codes and related locations. Extend diagnostics
  to show the later use keeping a borrow live where that context is needed.
- Compare legacy behavior and representative emitted binaries with the
  baseline, run the performance gate, and publish measured costs.

Preserve the safe-mode fixture matrix: x86/x64, compile/structured-check,
with/without `--safe`, execution of accepted programs, and rejected programs
leaving no output artifact. Add warning-relaxed and optimization variants
where they could expose a contract bypass. Prioritize interactions between
multiple origins, descriptor/data lifetimes, reborrow ancestry, aliases/casts,
branches/loops, partial initialization, replacement, overflow, callback escape
and changed/shadowed trusted implementations. Session tests must include
success–failure–success sequences as well as mode and imported-contract edits.

The validation agent owns independently written positive/negative pairs and
a bounded generator of small ownership programs. Mutate operation order and
control-flow placement, retain reproducible seeds, minimize failures and add
them as permanent fixtures. Differential checks can share the same bug;
another agent must trace each newly accepted operation through parsing,
retained semantics, dataflow, lowering, cleanup and audited runtime.

For the first delivery target, add a complete checked example that constructs
and grows storage, obtains and returns views, stores a view in an aggregate,
moves an owned aggregate, and drops every owner exactly once. Pair it with
rejected mutations that grow/drop the backing storage while its view is still
live, return a local view, duplicate an owner, or forge descriptor bounds.
Exercise the same example through imports and both supported architectures.
Publish its restrictions and measured costs with the feature release.

Each extension is complete only when its documented subset works end to
end, unsupported cases still fail explicitly, cleanup and library contracts
agree, and the usage reference records its guarantees and limitations.
Issue #644 remains open for the broader roadmap.
