# Checked lifetime contracts: implementation decisions

This records the lifetime, descriptor and aggregate decisions in the
[ownership roadmap](safe_mode_roadmap.md). The
[usage guide](safe_mode.md) remains authoritative for supported operations.
Each extension keeps its own delivery gates; these decisions do not
authorize unchecked implementations of later milestones.

## Signature lifetimes

Use the contextual qualifiers `ref[a] T*`, `refmut[a] T*`,
`optref[a] T*` and `optrefmut[a] T*`. Optional forms use zero for absence;
presence refinement is required before dereference or nonoptional use.
Labels are
identifiers bound implicitly by a function signature, not global lifetimes,
runtime values or generic type arguments. Unannotated results retain the
existing exactly-one-borrowed-input inference rule.

For a named result, collect every borrowed input with its label or a label
that transitively outlives it under an explicit `where a > b` clause. Require a
nonempty set. The body may return a view of any member, but may not return
local storage, an owned parameter or a different input. At a call, the result
keeps every member's backing storage borrowed. This computes a conservative
intersection of input lifetimes, even when scalar arguments could predict
which branch the function takes. A mutable result requires all candidate
inputs to supply mutable references.

Names are erased at runtime. A prototype and definition agree if their
types, label equality relationships and transitive outlives relationships
agree across all parameter/result positions. Renaming labels consistently is valid; adding, removing or
regrouping labels is not. Preserve the written result and parameter types
from each declaration together; combining a prototype's result label with a
definition's renamed inputs creates an invalid signature snapshot.
Later prototypes also need independent retained snapshots, even when the
live symbol already points to a definition. Validate declarations that erase
all checked qualifiers against the original checked implementation; validate
every declaration resolving an audited storage function, including private
destructors. An identical redeclaration preserves the existing definition.

Aliases preserve annotations. Local annotations never extend storage
lifetime. Direct and concrete generic signatures can express outlives clauses after the parameter
list (`where a > b, b > c`). Every endpoint must name a borrowed parameter or
result. Normalize to a transitive relation on signature slots, including equal
labels, and retain it with each declaration's independent snapshot. Clause
order and redundant edges do not affect identity. The bounded representation
admits at most ten parameters, matching the raw symbol's parameter-type slots.
The relation is stored in the retained arena, so session destruction and
checkpoint rollback reclaim it with the declaration; it is never published
into a global label namespace. Body return validation and caller provenance
use the same relation. A relation never erases a root or reborrow parent.

Concrete generic signatures own normalized relation rows in their raw function
type; each retained type snapshot copies the rows into its arena. This prevents
raw signatures from referencing rolled-back arena storage during recovery. The call checks that
snapshot against the instantiated declaration before using its origins.
Constrained headers are reparsed from retained source under the concrete type
substitution, so aliases resolve before labels are normalized; unconstrained
headers keep the existing retained-tree fast path. No template label enters a
global lifetime namespace. Multiple independent aggregate lifetime groups
still require their own implementation and rejection tests before admission.

## Universally quantified callable contracts

`type View = fn[a](ref[a] T*) -> ref[a] T*` binds names within one signature.
Use `View*` for a checked code address, and `fn[]` for a checked contract with
no named slots. Bind every named top-level borrowed slot, reject unused or
duplicate binders, and normalize optional outlives clauses exactly as for
direct signatures. Nested callable aliases own independent scopes.

Raw function types own the normalized rows; retained snapshots copy them.
A non-null relation marks the checked contract even when all slots are scalar.
Preliminary ABI matching ignores lifetime spelling. Before publishing code,
the retained pass proves exact recursive contract equivalence and checks the
implementation body, including functions whose addresses are never invoked.
No casts, null values, raw escapes or uninitialized reads can manufacture a
checked callable. Generators, kernels and variadics have different entry
protocols and are excluded explicitly in retained binding metadata.

Evaluate an indirect callee once before reserving its arguments. Apply the
same origin-set, reborrow and move rules used for direct calls; code addresses
have no captured environment. Emission must clear transferred owner slots and
push coerced slice descriptors at their full width. Keep callable recognition
aligned with the emitter's pointer/alias shape; const-qualified forms remain
rejected. Validate nested types with depth 32/work 256 bounds. Captures and
aggregate-stored callback environments require separate ownership contracts.

## Provenance and reborrows

Represent provenance as sets of resolved local binding identities. A call
may produce several backing roots and several immediate reborrow parents.
Do not collapse either set to one representative. For every access:

1. Require all possible roots to be initialized and unmoved.
2. Compare against every overlapping live loan and every reservation made
   by an earlier argument of the same call or an already evaluated storage
   projection.
3. Permit access through a loan's descendant subject to shared/exclusive
   access rules; do not thereby permit access through its suspended parent.
4. Retain all possible roots and ancestry through another call or reborrow.

The initial implementation interns bit sets per checked function, with local
singletons preserving existing binding indices. Union interning avoids
allocating the same set on repeated dataflow passes; function completion
releases the sets. Parent traversal must terminate even for malformed
self-referential initializers that definite-initialization checking rejects.
Nonoptional reference reassignment remains unsupported. Optional-reference
replacement uses flow-sensitive presence states and conservative unions of every
assigned origin and parent. The origin/parent fixed point participates in graph
convergence. Reborrow cycles are rejected; absence removes a copied value's
backing-storage obligation without removing a live child's obligations. A
replacement may release its old loan before RHS evaluation only when no RHS
operand reads that old value.

A projected store reserves its backing roots across right-hand evaluation;
an indexed projection reserves its receiver across index evaluation. Final
initialization state alone is insufficient: moving or replacing an owner may
free an already evaluated address, then restore the binding to a live state.
Use shared reservations so value reads remain possible, and release each
reservation before validating the final access. Plain binding assignment
does not hold a payload address and retains ordinary move/replacement rules.

Detect checked fields through the complete retained type graph using an
iterative queue and generation-marked visited types. Visit each type once
per scan, including cycles and repeated branches. This bounds work by the
actual graph without imposing arbitrary depth or size limits on legacy raw
types. Reuse scratch storage during checking and free it at completion or
session reset.

Test both candidates independently: if `choose(left, right)` returns a view,
later mutation, move or destruction of either candidate must fail while that
view is live. Also test nested choices, repeated arguments, mutable parents,
branch joins, loop backedges, imported declarations and recursive calls.

## Checked slice representation

Legacy `T[]` has a one-word pointer to a descriptor. Range expressions
currently allocate a two-word descriptor; metadata and data have different
lifetimes. Returning its pointer without tracking descriptor ownership does
not establish a safe returned-view contract.

The checked extension uses explicit `ref[a] T[]` (or `ref T[]` for inferred
contracts). Its descriptor is an inline `{data, length}` value, copied using
the existing aggregate calling convention. The caller owns the hidden
result buffer. Copying a descriptor copies a view, never its backing data;
backing provenance is checked independently. Descriptor copies require no
heap allocation, reference counting or destructor. Legacy slice ABI and
raw-pointer behavior remain unchanged.

Convert fixed arrays and other checked slices into checked descriptors.
Ranges whose receiver is already checked produce a two-word stack temporary;
call argument compaction, value copying and lexical stack unwinding account
for its storage. Preserve receiver provenance while evaluating bounds, so a
bound's side effect cannot invalidate an otherwise unnamed intermediate
view. Legacy array/slice ranges retain their existing representation and
cannot initialize a checked descriptor. Reject legacy/checked descriptor
mixing except at an explicitly implemented conversion boundary.

Metadata is opaque in checked code. Allow scalar `.length` reads and
bounds-checked element reads, but neither mutable metadata nor borrowing its
address. Shared elements remain immutable. Returning an element reference
constrains the backing data, not the callee's inline descriptor. Reject raw
descriptor construction, bytewise copying through casts, mutable slice
qualifiers and reference-bearing elements until separately modeled.

## Shared-reference aggregate construction

The bounded aggregate form uses `ref[a] Record`: an inline value whose raw
struct template contains shared pointer or checked-slice fields with one
declared label, plus
plain scalar fields. The outer annotation renames that one group. This
reuses the existing aggregate ABI while allowing independently labeled
parameters of the same nominal struct type.

Require a complete positional or named constructor, with each field supplied
once. Reserve earlier shared arguments while later arguments evaluate. Union
every field's roots and parents; each extracted reference conservatively
inherits the whole union. Copies preserve that union. Taking the address of
a descriptor field is forbidden, even for scalar fields: the inline value's
storage must not inherit the longer lifetime of its borrowed data.

Raw struct storage, zero initialization and mutable fields in the shared form
remain rejected. Nominal identity
includes the declaration location, not just its printed name.

The exclusive inline form `refmut[a] Record` additionally admits mutable
pointer fields in the same one-group template. Its type identity and field
qualifiers remain distinct from the shared form. Constructor reservations
use each field's shared/exclusive kind; later reborrows conservatively reserve
the entire backing group. Copying, passing and returning wrappers preserve
reborrow ancestry and suspend conflicting parent access. Mutable-field
extraction requires a mutable wrapper; shared fields cannot be upgraded.
Scalar metadata remains assignable, but wrapper/reference-field replacement
and descriptor addresses are rejected. Optional fields, mixed owner fields
are not admitted; independent groups use the explicit multi-label extension.

Nested borrowed wrappers recursively rename each inner group into the
containing field's group. Validate every level with a path-cycle check, depth
32 and expanded-work 256 bounds. Shared outer wrappers cannot contain mutable
inner wrappers. Constructors recursively validate completeness and preserve
every root, parent and earlier-argument reservation; field extraction keeps
the complete enclosing union, including siblings. Inline scalar projections
follow the containing place without acquiring a fresh exclusive data borrow.
Returned-value projections evaluate their source once. Addresses of nested
descriptor fields remain forbidden. The ordinary nested record layout and
by-value ABI provide storage; no new runtime representation is introduced.

Independent groups extend the wrapper with a positional label vector, ordered
by first occurrence in the template fields. Nested wrappers contribute their
mapped labels. Require exact arity and explicit multi-group annotations;
duplicate enclosing field labels deliberately union the corresponding inner
components. A projection selects its template group before checking access to
a named mutable wrapper, so unrelated live children do not conflict.

Track component origin/parent sets as well as whole-value unions. Give each
parameter component a distinct abstract root: a whole-parameter root would
incorrectly accept a return from the wrong field. Component joins participate
in fixed-point convergence. Calls evaluate each argument once and propagate
every applicable component through expanded normalized contract slots.
Validate each returned component independently, including optional pointer
results and results from quantified callbacks. Keep at most 32 expanded slots; quantified signatures and explicit outlives
clauses also retain their ten-parameter bound. Raw signatures own their rows and retained
snapshots copy them into the retained arena. Multi-label spelling components
are owned by raw records and copied/interned for retained snapshots.

## Owner-bearing aggregates

Use the existing `own Record*` representation: one uniquely owned allocation
containing plain fields and owned pointers to acyclic supported pointees.
Complete `new Record(...)` construction consumes arguments in source order.
Each successfully stored owner clears its source slot before evaluating the
next argument. No normal continuation can observe a partially initialized
owner; omitted, duplicate, null or incompatible fields reject the program.
Allocation failure terminates, without an unwinding guarantee.

Whole moves preserve the pointer ABI. Replacement evaluates its right-hand
side before dropping the old allocation. Destruction visits owned fields in
reverse declaration order, recursively destroys their allocations, and then
frees the parent. A depth-32 bound rejects cyclic or excessively deep
destructor graphs; a 256-node work budget bounds expansion of repeated child
types in an acyclic graph. Checker traversal and emission both enforce this
budget. Parent references preserve
whole-root borrows when lending child payloads. Partial moves, field owner
replacement remain unsupported. Mixed owners use the explicit contract below.

### Mixed owner provenance

`own[a,b] Record*` binds the external-data groups of its pointee. Require
an explicit label vector of exact arity, including for a single group. Admit
shared/exclusive pointer and borrowed-record fields, shared slices, and
recursively supported owned children; reject optional borrowed fields. Keep ordinary
`own Record*` shape validation unchanged; shared whole-owner views use the
combined contract below.

Separate the allocation root from every external component, including component
zero. Synthetic external roots for parameters must follow real local binding
indices, never replace them. Moves preserve component origins/parents while
consuming only the allocation binding. A labeled owner retains shared or exclusive loans of its external groups
for access/liveness analysis, while retaining unique ownership of its allocation. Scope exit invalidates an owner whose borrowed data expires.

Constructors evaluate fields once, preserve group mappings, consume owned fields
and reserve prior shared origins during later arguments. Calls propagate external
components through the normalized contract slots and reserve them independently
of moved allocations. Return checks validate every external component, and defer
keeps those returned components reserved until exit. Whole-binding replacement
joins old/new provenance conservatively; it does not claim precise loan release.

Projecting a borrowed field uses its external group. Projecting owned storage
uses the containing allocation root. Never accept returning owned-child storage
under an external-data contract. Returning an inline slice copies its descriptor
before recursive owner cleanup. Nested annotated owned children recursively map
their external groups, without moving the child to read a borrowed field.

Raw type records own their label vectors. Speculative generic type records store
label strings and their pointer vector in the expression type-name slab; slab
growth rebases both levels. Committed types clone the labels, and retained
snapshots own independent arena metadata. Keep this bookkeeping compile-time
only: no runtime layout or cleanup changes are needed for shared borrowed fields.

Exclusive whole mixed-owner borrowing, optional fields, field replacement
and partial moves retain separate required gates. Do not infer completion of A2/A3
from this shared-field step.

### Exclusive mixed-owner groups

Cache an access-kind mask for each retained owner type, with bounded recursive
mapping through owned children. A group is exclusive when any mapped field is
exclusive; unrelated shared groups retain shared access. Reset the cache with
compiler safety state so retained type identities reused by another compilation
cannot inherit old access kinds.

Reads conflict only with live exclusive component origins; writes conflict with
all live origins. Moving an owner must also check its exclusive external roots
before consuming the allocation, since live child views cannot survive a move
that could grant a callee mutable access. A mutable returned component requires
an exclusive input component as well as the normalized outlives relation.

Reserve shared and exclusive sets separately through constructor/call argument
evaluation and deferred return processing. Keep the returned exclusive roots on
the return flow node; deferred reads of independent shared groups stay valid.
Whole replacement can suspend the old owner's loan while evaluating its RHS only
when the expression contains no other use of that binding. Existing child loans
still constrain access, and old/new component origins continue to join.

### Shared mixed-owner views

Admit a nonoptional shared pointer to a mixed owner by folding its allocation
root and all external component origins into one conservative borrow. Never use
only the owner's external components: that would allow replacement/destruction
while a pointer into its descriptor remains live. Each field extracted through
this view inherits the complete union, including every component of a nested
borrowed record. Retain the shared parent so no projection can upgrade access.

For an annotated owned child reached through a shared view, its external
provenance inherits the parent's whole union. For a child reached through an
owning binding, combine the containing allocation and mapped external roots when
creating a shared whole-child view. Calls and returns use ordinary single-group
reference contracts over this combined set. No new runtime representation or
emission path is required. Mutable and optional mixed-owner views remain gated.

## Audited concrete storage

`lib.safe_buffer` is a separately imported library, outside the bootstrap
compiler closure. Its public signatures expose owned integer buffers and
byte strings with shared/exclusive operations and inline returned views.
The compiler admits its opaque pointees only through resolved nominal
identity and the exact audited source hash. Checked callers cannot construct
metadata, project fields or call private raw helpers. Public declarations
must match their resolved implementations.

Only the exact pinned runtime bodies bypass ordinary body checking. They
explicitly initialize every metadata field, check growth arithmetic and
allocation failure, validate indexed accesses and expose only initialized
elements. A view copies a local raw descriptor into the caller's checked
result buffer; neither the temporary descriptor address nor heap ownership
escapes. This conversion remains rejected in application code.

Compiler-generated destructors select the matching private drop function
from the same resolved source and verify its definition and signature before
emitting a call. Each frees payload storage, then the metadata allocation.
Borrowed views constrain the whole owner, so every mutation is exclusive,
including operations that would not move storage in a particular execution.
Byte strings preserve arbitrary bytes, including NULs; UTF-8 validation is
outside this contract. Empty pop traps and self-append is rejected.

`WOwnedIntBuffer` stores uniquely owned integer allocations. Push and indexed
replacement consume the argument, clear its checked parameter home, and
store its pointer in raw owned storage. Replacement destroys the old element
after argument evaluation. Pop removes and clears the last raw slot before
returning its owner; clear destroys elements in reverse order. Growth moves
pointer slots without duplicating ownership. An element view borrows the
whole buffer; all mutation requires exclusive access. Generic owner elements
and legacy containers are outside this contract.

`WByteArena` copies initialized byte views into opaque growable storage.
Its result lifetime names only the mutable arena input, not the source view.
The runtime checks size addition and growth, then returns an inline checked
descriptor. Empty views may have zero data addresses but cannot be indexed.
Copy, reset and release require exclusive access, including copies that fit
existing capacity. Reset retains capacity; release frees payload storage and
zeros all storage metadata. Final destruction releases the payload and
metadata. General typed allocations and attached budgets are not admitted.

## Control flow and deferred cleanup

Range loops model their bounds, induction binding and backedge. Scalar
switches model case alternatives and the default path. Every `break` or
`continue` invalidates all exited lexical bindings before joining its
destination; `continue` crosses a switch to reach the enclosing loop.
The range induction binding remains initialized inside its loop. Emitted
cleanup and analysis must agree even when a reference is stored in an outer
optional binding before jumping out of its owner's scope.

Legacy `defer expression` may be registered only in the outer function block
of a checked function. Explicit `defer: expression` is a lexical checked
registration, with one expression on the same line. The retained registration
records its enclosing block identity. Normal block departure retires only that
block's registrations; return emits all active entries in reverse order;
loop jumps emit scoped entries only for the lexical blocks they leave.
`continue` crosses switches, and block identity distinguishes empty scopes
that share a stack depth. No runtime registration allocation is needed.

Return expressions are evaluated and transferred before deferred work;
deferred expressions precede automatic destruction. The emitted exit nodes
participate in liveness and move analysis, including return-value borrow
reservations and jump cleanup. Names and arguments retain exit-time binding,
so later declarations and shadowing are observed and missing exit bindings
are rejected. The colon form opts its function into checking without
`--safe`, requires retained emission, and rejects unsafe registration,
generators, goto and deferred control-flow statements. Legacy raw defer
semantics do not change.

Checked methods normalize into direct calls with an explicit receiver.
Receiver evaluation occurs before argument evaluation; synthesized receiver
addresses retain the original binding and lifetime. Owner receivers and
arguments use the same transfer clearing as direct calls. Method syntax
does not grant an unsafe or unchecked boundary.

Queued generic calls retain their concrete mangled callee identity, not only
the template name. At checking, resolve it to the specialized function,
compare the concrete signature (including normalized lifetime relationships),
and analyze that implementation. Explicit and inferred arguments use the
ordinary call's ownership reservations and owner-slot clearing. Retained
emission recovers the template identity from the concrete name without
changing the published ownership contract. Qualified generic pointer
signatures preserve their qualifier and optional lifetime label during
capture and instantiation. Quantified noncapturing indirect calls follow the
callable rules above; capturing and escaping environments remain excluded.

## Target admission

Checked programs are supported on Linux x86/x64/arm64, win64, arm64_darwin
and wasm. The win64
audited runtime includes its own pinned allocation/syscall implementations;
the guard allocator protects holes with `mprotect` because Windows cannot
release a suffix of an allocation. Entrypoint selection requires a defined
symbol, not a nonzero unresolved-prototype backpatch chain. Other targets
remain rejected until runtime and cleanup parity are validated.

Linux ARM64 admission pins the architecture wrappers, Linux syscall/stat
implementations, filesystem flags and AArch64 context code. Review covers
Linux syscall argument/result registers and signed errors, mmap/munmap/
mprotect behavior, context register slots (including the W stack register),
and the existing runtime page-size discovery. No raw-call allowlist expands.
The target matrix checks flag-independent contracts, rejected-program
artifact suppression, unsupported neighboring targets and changed runtime
pins. The runtime corpus exercises ownership, slices, aggregates, optional
references, control flow, generic/method/callback calls, buffers and arenas
under default, unallocated-register and inline compilation. QEMU execution
and guard allocation in `tests_arm64` are required in addition to host-side
cross-compilation.

WebAssembly admission (`wasm`, wasm32 + WASI) reuses the 32-bit x86 checked
representation and pins the wasm android, context and syscall modules.
Review covers the WASI import wrappers and their fixed low-page scratch,
`brk` failure forcing `mmap`, `mmap` as a `memory.grow` bump allocator,
no-op `munmap`, failing `mprotect`, `proc_exit` and the absence of a raw-call
allowlist expansion (the `wasi_*` stubs stay uncallable from checked code).
Because linear memory cannot be protected, the guard allocator is replaced by
a documented substitute: resident canary guard pages and poisoned freed
payloads checked at free, realloc, quarantine release and leak reports.
Overruns and writes after free are detected late, and reads after free are
not detected. The same accepted/rejected matrix runs with x86 diagnostic
parity, artifact suppression, neighbouring-target rejection and changed-pin
cases. The full runtime fixture corpus runs in three compilation modes. Node
(or wasmtime) execution in `tests_wasm` is required in addition to
compilation.

## Integration and review

Keep the parser, retained type records, function declarations and caller/body
checker on the same contract. Initialize added metadata explicitly in both
ordinary type allocation and speculative AST arenas. Compiler-session reset,
rollback and source invalidation must not reuse another signature's labels.
If expression parsing falls back to an unmodeled path, mark the enclosing
statement or function as unsupported for checking. Retaining a nested
argument is not evidence that the outer expression was modeled; the checker
must reject the incomplete expression instead of validating that fragment.
The implementation remains compatible with the pinned bootstrap seed; only
leaf fixtures use new source syntax before a seed release.

The validation lane supplies accepted/rejected pairs independently from the
implementation, with x86/x64 execution, compile/check agreement and explicit
contracts checked without `--safe`. Descriptor tests include nested returns,
stack clobbering, argument positions, different element widths, empty views,
reference-to-element returns, and attempts to forge bounds. The full suite,
both self-host fixpoints, changed-line coverage and measured costs are gates,
not evidence of a formal soundness proof.

Persistent REPL and debugger sessions (#713) keep this single contract by
construction: each entry is checked as the continuation of one transcript
function in which every earlier checked declaration is a renamed local, so
binding identity, initialization and move state, backing roots and reborrow
parents are the ordinary per-function analysis rather than a second,
session-level model. The checker exposes one read-only callback
(`safe_function_end_hook`) for reading flow states before the graph is
released. Only the state at the end of the transcript is published, and only
after the entry ran to completion; a failed or faulting entry publishes
nothing, and a fault discards (leaks) exactly the owners the entry could
have changed. A redefinition may not change a checked function contract
that existing callers were checked against. Debugger stops reuse the same
analysis of the stopped function: a local is presented only when it is
definitely initialized at the stop and, for a borrow, still live in the
program (so its loan is one the checker already validated), and only as a
shared borrow that cannot be moved or written back. Session-end destruction
mirrors scope cleanup, so each held owner is destroyed exactly once.

## Optional owner representation and construction

`optown T*` is a distinct canonical qualifier over the existing pointer ABI.
Zero is absence; `own` remains non-null. Named bindings carry a separate
presence lattice while initialization/move state continues to reject reading
or testing a transferred source. Transfer preserves presence for the receiving
binding and clears the source runtime slot. Present-only access and narrowing
to `own`/required references use the existing identity-preserving refinements.
Replacement and scope cleanup reuse the conditional owner destructor, including
recursive optional owned fields and audited opaque payloads.

Every optional owned field must be supplied in a complete constructor. Field
presence is conservatively unknown until extraction into a named optional
owner. This prevents accessing a nullable child through an unchecked projection.
External lifetime groups on `optown[a,b]` follow the same contract as `own[a,b]`;
a known-absent transfer does not carry conservative former external loans.
Optional inline records and slices retain a separate representation gate.


## Explicit generic borrowed aggregate shapes

Borrowed records and checked slice descriptors retain their concrete layouts
and lifetime mappings in explicit generic signatures and type arguments.
Speculative expression types carry immutable field descriptors in the scratch
name slab; growth relocates both descriptor and item pointers. Nested mapped
field types are staged before their enclosing wrapper, matching committed
registration order. Rollback discards borrowed table entries, and commitment
reconstructs independently owned metadata before scratch reuse.

Generic definition scanning recognizes unlabeled `ref T` / `ref T[]` shapes
without consuming a template parameter named `ref`. Existing ordinary header
reparse remains available when a captured signature cannot be resolved by the
retained header walker. Check mode does not fabricate an `int` witness for an
unused template whose bare borrowed parameter/result requires a record;
concrete specializations still check every body and contract. Other unused
templates keep their existing scalar witness. The inferred result and method
contracts are described below.


## Inferred aggregate result buffers

A retained inferred call binds its concrete signature before emission. Aggregate
results reserve the ordinary caller-owned return buffer before arguments and
pass its address as the hidden first argument. Nested argument temporaries are
compacted after their value is copied, preserving evaluation order and the
callee layout. Inference shares a completed signature with a nested call even
when the nested node has a later arena index. Whole-parameter inference retains
checked qualifiers and lifetime groups in specialization identity; owner moves
and result provenance use the same retained contract as explicit calls.


## Inferring borrowed shapes

A qualified borrowed-record parameter binds its template parameter to the
argument wrapper's plain record template; a qualified slice parameter binds
its element from a checked slice or fixed array. Whole-parameter inference
continues to retain the entire argument type. Repeated bindings must agree,
then every inverted shape is checked against its concrete specialized
signature. Array-to-slice coercion runs at the argument's evaluation position
and pushes the checked descriptor layout. No raw pointer gains a slice length,
no shared input gains exclusive access, and inferred labels do not extend
backing storage lifetimes. Generic struct applications retain their subsequent
implementation gate under #696.


## Checked generic receivers

Explicit and inferred generic method calls lower to the same retained call
nodes and signatures as their direct equivalents. The receiver is the first
argument and is evaluated once. A record's address is synthesized only for a
pointer parameter; borrowed wrappers otherwise retain their inline layout.
Owned receivers move once, and result loans retain the receiver's backing roots.
Concrete pointer types used in captured signatures can be staged without
committing metadata during probing. Record-prefixed definitions take precedence;
ordinary definitions retain precedence for inferred syntax, while explicit type
arguments select generic definitions. Built-in operations and fields keep their
existing lookup rules. Unsupported streaming forms still fail explicitly.


## Thread transfer and share eligibility

Eligibility is a structural predicate over retained types
(`safe_thread_reason` in `compiler/safe.w`). It is not a declared trait.
It has two modes. **Detached** checks a value going to a thread that no
borrow scope encloses. Any borrowed component at any depth is rejected,
including `ref`/`refmut` pointers, slices, inline borrowed records and
labeled owners. **Scoped** checks a value lent to a thread that is joined
within the lending call. A shared reference crosses only if its target is
shareable. An exclusive reference crosses only if its target is
transferable. A sharing flag records whether the walk has passed through a
shared reference; it then remains set, so `ref` to `refmut` to `T` still
requires shareable `T`. Owners, arrays and record fields recurse in the same
mode. Callable fields are static code addresses. Audited opaque storage is
transferable and shareable: it is uniquely owned, any thread may free it
(`lib/thread_heap.w` remote frees), and no audited operation mutates it
through a shared reference. The synchronized types are the exceptions; see
[Synchronization and memory ordering](#synchronization-and-memory-ordering).
Anything else is rejected, including raw
pointers, unions, containers and unknown resources.

Explicit opt-outs are nominal records defined in the pinned
`lib/safe_thread.w`. `WThreadAffine` forbids both transfer and sharing;
`WThreadUnshared` forbids only sharing. A user record with the same name
from another source has no effect. Markers are plain values, so they do not
change a record's checked layout or construction rules. Diagnostics give
the dotted field path to the first offending component. The walk is bounded
at depth 32 and 256 expanded records or arrays. Scalars are checked before
the budget is charged, so wide records are accepted.

The predicate runs at audited thread boundaries, not on ordinary calls.
These boundaries are the generic specializations `safe_thread_spawn$...` and
`safe_thread_fork_join$...`, recognized only when their implementation comes
from the trusted, digest-matched `lib/safe_thread.w`. The check applies to
the concrete specialized parameter type at each call. Wrapper functions and
generic wrappers therefore cannot bypass it: the inner call is checked with
the wrapper's concrete types. The check runs before the ordinary argument
contract, so its message takes precedence. Ordinary ownership and borrow
checking still applies to the same arguments. The payload is moved, a
fork-join left/right pair cannot conflict, and live views exclude lending.
The entry's quantified signature must be exactly
`fn[](own T*) -> int` for spawn, or `fn[](T) -> int` with a sized
non-optional `ref`/`refmut` `T` for fork-join. Owners are rejected as
fork-join arguments because the runtime would not drop them.

Inferring `own T*` from a shared-reference argument used to push a `const`
pointee record during the speculative probe. That shifted the reserved
signature slot and tripped an assertion in `ast_expression_commit_generic`.
Inference now steps through the checked target without creating that
record. Such a call now reaches the ordinary "owner requires new storage"
diagnostic.


## Audited thread runtime

`lib/safe_thread.w` is pinned in `compiler/safe_runtime.w` together with its
closure beyond the existing pins: `lib/thread.w`, `lib/thread_heap.w`,
`lib/signal.w` and `lib/assert.w`. Checked callers can reach
`safe_thread_spawn`, `safe_thread_join` and `safe_thread_fork_join`, nothing
else. `WSafeThread` is opaque, like the buffer types. Its compiler-emitted
destructor (`grammar/safe_cleanup.w`) is `__w_safe_thread_drop`, which joins
the child before freeing the handle. Every owner-drop path therefore waits for
the child: scope exit, replacement, early return and optional-owner cleanup.

A live-thread counter is updated with `atomic_add`. It refuses a spawn when
64 checked threads are unjoined, which bounds the address space taken by 4 MB
stacks and gives refusal a deterministic test. Refusal and `clone` failure
both return before the child exists. The generic `safe_thread_spawn` body
then returns without clearing its `own T*` parameter. The ordinary recursive
owner cleanup therefore destroys the payload. On success the parameter's slot
is cleared, as in `owned_int_buffer_push`, and the child's entry consumes the
payload. The child copies the payload pointer out of the handle and clears
the field before calling the entry.

Memory ordering follows `lib/thread.w`. The child writes `result` before the
worker stores `done = 1`. `thread_join` waits for `done` and then for the
kernel's exit-time CLEARTID store before the joiner reads `result` and frees
the handle. On x86-TSO, with the futex syscalls, the result and every write
the child made to lent `refmut` storage are visible to the joiner. No other
memory is shared. A detached payload's owned graph is reachable only from the
child. Fork-join borrows are shared read-only, or exclusive to one side. This
contract is an argument from the existing `lib/thread.w` review, not a
formal proof. Independent review of the memory-ordering argument is still an
acceptance gate of #699. Stress tests would add evidence, not prove the
absence of races.


## Synchronization and memory ordering

This section is the reviewable argument for #699 deliverable 4. It covers
the lifetime rules that keep the mutex payload inside critical sections and
the x86/x64 lowering of each admitted atomic ordering. The runtime tests in
`tests/safe_sync_runtime_test.w` add evidence; they are not a substitute for
reviewing this argument. Like the rest of the thread runtime it applies to
Linux x86 and x64 only, where hardware follows x86-TSO.

### Guard lifetimes in the checker

The mutex and guard are generic records `WSafeMutex[T]` and `WSafeGuard[T]`
of the pinned `lib/safe_thread.w`; the atomic is the plain record
`WSafeAtomic`. `safe_sync_record` recognizes every instance by the pinned
source and the mangled name (`WSafeMutex$...`, `WSafeGuard$...`; a user
definition with the same spelling elsewhere is not trusted). They are opaque
in the same way as `WSafeThread`. Field projections, partial moves, field
replacement, `new` and plain construction are all rejected, so checked code
reaches the payload only through `safe_guard_value`. The audited runtime is
a fixed set of calls (`safe_runtime_call`, the `safe_mutex_*$` and
`safe_guard_*$` specializations).

Every `WSafeMutex[T]` has the same layout, a `wmutex` followed by one owner
word, so the runtime allocates them all through one untyped storage record
(`__w_safe_mutex_storage`, itself not a checked owner shape) and casts. The
type argument only fixes what the guard's view returns. `T` is whatever a
lifetime-free `own T*` admits: a sized plain value or an owned record graph
with no borrowed fields. A borrowed record payload would need `own[a] T*`,
which the parameter does not carry, so it is rejected; a guard payload is
rejected for the same reason (guards always carry their mutex lifetime).

`safe_mutex_lock(ref[a] WSafeMutex[T]*) -> own[a] WSafeGuard[T]*` reuses
mixed owner provenance. `WSafeGuard[T]` declares a single `ref[held]` group,
so the
returned owner retains the mutex's shared borrow through moves, owner fields
and returns, exactly as other mixed owners do. Two rules close the gaps that
ordinary mixed owners do not need, because dropping an ordinary mixed owner
never reads its borrowed data:

1. **A guard's drop is a use.** `safe_guard_drop` marks every local whose
   owned graph reaches a guard. Liveness adds a use of each such local at
   every block cleanup event of a block that contains it, at every return
   capture and at the function end. A move, consumption, replacement or
   destruction of the mutex root while the guard may still be dropped is then
   a write that conflicts with a live borrow. `safe_access` normally skips
   borrowers that might already have been moved. For guard locals it
   considers any state that is possibly initialized, because a guard
   released on one path is still dropped on another.
2. **A mutex scope cannot end under an outliving guard.** When a block's
   cleanup ends a root, the ordinary rule kills borrowers of that root.
   For a possibly initialized guard local declared outside the block, that is
   instead an error (`lock guard outlives the mutex it borrows`). Its later
   drop would otherwise unlock freed memory. Cleanup drops one block's
   owners in reverse declaration order, so the same error applies to a
   guard declared *before* the mutex root it borrows, in the same block, at
   that block's end and at every `return` (`safe_guard_order_check`); a
   loop body left by `break` or `continue` reaches the same block-end event.
   A guard of a parameter, or of a root declared before it, is dropped
   first and is accepted. The guard-bearing walk fails closed: an owner
   graph past its depth or node bound counts as holding a guard.

Guard owners must be labeled. The owned-shape walk stops treating a guard as
plain opaque storage, and `safe_type_check` rejects `own WSafeGuard[T]*`.
Otherwise an unlabeled owner would carry no borrow. The view
`safe_guard_value(refmut[a] WSafeGuard[T]*) -> refmut[a] T*` uses the existing
returned-reference contract: the view borrows the guard, so the guard
cannot be unlocked, moved or dropped while the view is live. Rule 1 makes the
guard's scope-exit drop an access too. Thread eligibility rejects a guard in
both detached and scoped modes, at any depth. Unlocking therefore always
happens on the locking thread, as `lib/thread.w`'s mutex requires. A mutex
is examined in detached mode with sharing cleared, through its `own T*
value` field: it is shareable whenever its payload is transferable (Rust's
`Mutex<T>: Sync` when `T: Send`). Atomics stay sealed opaque storage that is both
transferable and shareable.

The mutex payload is consumed by `safe_mutex_new`, which clears the
parameter slot as `safe_thread_spawn` does. The ordinary recursive owner
drop of the concrete instance frees it once, with `T`'s own owned fields,
before the mutex allocation. A guard owner is the mutex's own address, never
a separate allocation, and its audited destructor `__w_safe_guard_drop`
only unlocks. It takes the mutex's leading `wmutex*`, so one helper serves
every `WSafeGuard[T]` (`safe_owner_drop_helper` checks that parameter type
for guard instances). `safe_guard_unlock` is an empty function;
its own parameter cleanup is the unlock.

### Mutex: exclusion and happens-before

`WSafeMutex.lock` is `lib/thread.w`'s three-state futex `wmutex` (Drepper,
"Futexes Are Tricky"). Every state change is a `lock cmpxchg` or `lock xadd`,
except the contended unlock's plain `word = 0` store, which follows its
`lock xadd` in program order. Exclusion: a thread holds the lock only after a
`cmpxchg` that observed 0, and locked instructions have a single total order.
`safe_mutex_try_lock` is the same `0 -> 1` `cmpxchg` without waiting.

Happens-before between holders: the critical section's payload stores
precede the unlock's `lock xadd`, a full barrier, in program order. Under
TSO, stores become visible in program order, so they are visible before
the `0` that the next holder's `lock cmpxchg` observes. That observation
comes either from the `xadd` (`1 -> 0`) or from the later plain store
(`2 -> 1 -> 0`). The `lock cmpxchg` is itself a full barrier, so the new
holder's later loads cannot be satisfied early. Payload accesses therefore
form a total order consistent with the lock order, and the payload has no
data race.

Each payload access is inside a critical section. Accesses go only through
a view. A view is live only while its guard is (checker rule above), and a
guard exists only between its `mutex_lock` and its unlock on one thread.
The compiler keeps payload accesses on the correct side of lock and unlock.
They are loads and stores through a `refmut T*`, not promoted locals.
Lock and unlock are out-of-line calls in the pinned runtime. Under
`--inline`, the atomic intrinsics still spill parked values and clear
folding notes (`atomic_notes_reset`). Any future optimizer must treat these
calls as acquire/release boundaries.

Destruction and the final wake: the contended unlock calls `futex_wake` on
the mutex word after releasing it. The mutex cannot be freed in between.
Only its owner can drop it. Another thread reaches it only through a
fork-join borrow, which lasts until that thread's entry returns, after its
guard drop has finished. A detached thread reaches it only by owning it.

Deadlock (re-locking on one thread, lock-order inversion) is possible and is
not a memory-safety violation.

### Atomics: x86-TSO lowering

`WSafeAtomic.value` is a heap word at offset 0. All allocators (free-list,
per-thread heaps, `W_DEBUG_ALLOC`) return 8-byte-aligned blocks, so the word
is naturally aligned and every full-width `mov` and locked operation on it is
single-copy atomic. Checked code cannot address the word except through the
calls below, so every access to a given atomic uses this mapping. The
mapping is the standard C++11 mapping for x86 with a trailing fence. Its
correctness for x86-TSO is established in the literature: Batty, Owens,
Sarkar, Sewell and Weber, *Mathematizing C++ Concurrency*, POPL 2011, and the
Cambridge "C/C++11 mappings to processors" table.

| Operation and order | x86/x64 code |
| --- | --- |
| load `relaxed` | `mov` (`atomic_load_relaxed`) |
| load `acquire`, `seq_cst` | `mov` (`atomic_load`) |
| store `relaxed` | `mov` (`atomic_store_relaxed`) |
| store `release` | `mov` (`atomic_store`) |
| store `seq_cst` | `mov`, then `lock or [esp/rsp], 0` (`atomic_fence`) |
| fetch_add, any order | `lock xadd` |
| compare_exchange, any admitted pair | `lock cmpxchg` |

Why each row is sufficient under TSO:

- **Relaxed.** It needs only atomicity and per-location coherence. An
  aligned word `mov` is atomic, and TSO is coherent per location.
- **Release store.** TSO never reorders a store with earlier loads or
  stores, so all prior accesses are visible before the `mov`. No fence is
  needed.
- **Acquire load.** TSO never reorders a load with later loads or stores,
  so no later access can be satisfied before the `mov`. If it reads a
  release store's value, the writer's earlier stores are already visible
  (TSO stores are seen in one global order). The pair synchronizes.
- **Read-modify-writes.** Locked instructions are atomic and act as full
  barriers, which is at least `acq_rel` and `seq_cst` for every order. A
  failed `cmpxchg` is still a locked full barrier, so every admitted failure
  order holds. `release` and `acq_rel` failure orders are rejected
  statically, because a failure performs no store. A failure order
  stronger than the success order is admitted: that is the C++17 rule
  (C++11 forbade it); it costs nothing on x86, where both are the same
  locked instruction, and a weaker-ISA port must lower the stronger of
  the two.
- **Sequential consistency.** TSO's only relaxation is that a later load may
  complete before an earlier store to another address is visible. A
  `seq_cst` store is followed by a full fence, and every RMW is one, so no
  `seq_cst` load can be reordered before a preceding `seq_cst` store.
  `seq_cst` operations then take effect in program order within each thread
  and in the single global store order across threads. Together these give
  the one total order that `seq_cst` requires. `seq_cst` loads can stay
  plain `mov`s only because every `seq_cst` store carries the fence. That
  holds because the store code is fixed in the pinned runtime.
- **Statically invalid orders.** A `release`/`acq_rel` load and an
  `acquire`/`acq_rel` store have no C++ meaning and are rejected. The order
  argument must name a `memory_order_*` constant from the pinned file
  (`safe_memory_order`), so the checker sees the order of every call. The
  runtime repeats the check and exits with an error for unchecked callers
  that pass an invalid value.

Compiler ordering: each intrinsic is emitted as its own instruction, after
spilling parked expression values (`atomic_notes_reset`). It is never
folded or treated as a constant, and the word is reached through a pointer
argument, not a register-promoted local (`docs/projects/threads.md`,
"Memory-order contract"). Calls into the runtime are further barriers to
the current single-pass code generator.

Not covered: ARM64, Windows and wasm targets (no checked thread runtime
exists there), fences as a separate operation, atomics wider or narrower
than the word, and shared ownership of an atomic or mutex between detached
threads.

### Validation

`tests/safe_sync_test.w` checks each rule above as an accepted or rejected
program, with and without `--safe`, on x86 and x64. The rejections cover:

- views after unlock or scope end, and two live views;
- shared-guard views and escaping views;
- returned and owner-wrapped guards of local mutexes;
- moving, consuming or replacing a mutex under a guard, including after a
  conditional unlock;
- an inner-block mutex under an outer guard, and unlabeled guard owners;
- guards in spawn payloads, fork-join arguments and nested fields;
- payload, guard and atomic field access, and fabricated mutexes and atomics;
- every invalid or non-constant ordering, and raw helpers.

`tests/safe_sync_runtime_test.w` runs in the default, `--safe`, `--no-regs
--no-inline` and `--inline` modes on both widths. It covers:

- lock release on return, `break`, `continue`, a `while` exit, early unlock,
  replacement, absent try-lock and owner-held guards;
- 8-thread fork-join mutex contention and 4-thread atomic contention (both
  `fetch_add` and compare-exchange retry loops) with exact counts;
- two spawned threads that each own a mutex and an atomic and run their own
  contention trees while the parent contends on its own mutex;
- release/acquire publication between two threads;
- a second measured round under `W_DEBUG_ALLOC=1` that must leak nothing.

Independent review of this section remains the #699 acceptance gate for
deliverable 4. The tests cannot show that races are absent.
