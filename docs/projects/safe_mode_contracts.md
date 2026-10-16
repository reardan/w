# Checked lifetime contracts: implementation decisions

This records the lifetime, descriptor and aggregate decisions in the
[ownership roadmap](safe_mode_roadmap.md). The
[usage guide](safe_mode.md) remains authoritative for supported operations.
Each extension keeps its own delivery gates; these decisions do not
authorize unchecked implementations of later milestones.

## Signature lifetimes

Use the contextual qualifiers `ref[a] T*` and `refmut[a] T*`. Labels are
identifiers bound implicitly by a function signature, not global lifetimes,
runtime values or generic type arguments. Unannotated results retain the
existing exactly-one-borrowed-input inference rule.

For a named result, collect every borrowed input with its label. Require a
nonempty set. The body may return a view of any member, but may not return
local storage, an owned parameter or a different input. At a call, the result
keeps every member's backing storage borrowed. This computes a conservative
intersection of input lifetimes, even when scalar arguments could predict
which branch the function takes. A mutable result requires all candidate
inputs to supply mutable references.

Names are erased at runtime. A prototype and definition agree if their
types and label equality relationships agree across all parameter/result
positions. Renaming labels consistently is valid; adding, removing or
regrouping labels is not. Preserve the written result and parameter types
from each declaration together; combining a prototype's result label with a
definition's renamed inputs creates an invalid signature snapshot.
Later prototypes also need independent retained snapshots, even when the
live symbol already points to a definition. Validate declarations that erase
all checked qualifiers against the original checked implementation; validate
every declaration resolving an audited storage function, including private
destructors. An identical redeclaration preserves the existing definition.

Aliases preserve annotations. Local annotations never extend storage
lifetime. General outlives clauses, higher-ranked function contracts and
multiple independent aggregate lifetime groups are not inferred from this
syntax; they need separate implementation and rejection tests.

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
Reference reassignment stays unsupported, so accepted reborrow dependencies
remain acyclic. Reassignment would require flow-sensitive provenance joins.

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
