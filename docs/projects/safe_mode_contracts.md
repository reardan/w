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

Raw struct storage, zero initialization, mutable fields, nested aggregates
and multiple independent field groups remain rejected. Nominal identity
includes the declaration location, not just its printed name.

The exclusive inline form `refmut[a] Record` additionally admits mutable
pointer fields in the same one-group template. Its type identity and field
qualifiers remain distinct from the shared form. Constructor reservations
use each field's shared/exclusive kind; later reborrows conservatively reserve
the entire backing group. Copying, passing and returning wrappers preserve
reborrow ancestry and suspend conflicting parent access. Mutable-field
extraction requires a mutable wrapper; shared fields cannot be upgraded.
Scalar metadata remains assignable, but wrapper/reference-field replacement
and descriptor addresses are rejected. Optional fields, nested records,
mixed owner fields and independent groups are not admitted.

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
replacement and mixed borrowed/owned field lifetimes remain unsupported.

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

Deferred expressions may be registered only in the outer function block.
Each is evaluated at function exit in reverse registration order, after
return-expression evaluation and before automatic destruction. Their uses
participate in exit liveness, including return-value borrow reservations.
Conditional/nested registrations and deferred control-flow statements remain
rejected until a matching registration-state model is implemented.

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
capture and instantiation. Indirect calls and callbacks remain excluded.

## Target admission

Checked programs are supported on Linux x86/x64 and win64. The win64
audited runtime includes its own pinned allocation/syscall implementations;
the guard allocator protects holes with `mprotect` because Windows cannot
release a suffix of an allocation. Entrypoint selection requires a defined
symbol, not a nonzero unresolved-prototype backpatch chain. Other targets
remain rejected until runtime and cleanup parity are validated.

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
