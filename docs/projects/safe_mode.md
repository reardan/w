# Experimental ownership and borrowing checks

The compiler accepts `--safe` on Linux x86/x64 and Windows x64 (`win64`):

```sh
./bin/wv2 --safe app.w -o app
./bin/wv2 check --json --safe app.w
```

This is a bounded, single-threaded subset, tracked by
[issue #644](https://github.com/reardan/w/issues/644). It does not make arbitrary
legacy W code memory-safe. Unsupported operations produce errors. The broader
design, including richer aggregates and broader lifetime contracts, is
tracked in the [ownership and borrowing roadmap](safe_mode_roadmap.md).

## Pointer contracts

| Type | Meaning |
| --- | --- |
| `own T*` | A non-null, uniquely owned allocation; assignment, arguments and return transfer ownership. |
| `optown T*`, `optown[a,b] Record*` | An optional unique owner; zero is absence, and a present value transfers and drops like `own`. |
| `own[a,b] Record*` | A unique allocation carrying borrowed fields; labels bind their external data groups. |
| `ref T*` | A non-null shared borrow; readers may coexist. |
| `refmut T*` | A non-null exclusive borrow; other access to the backing storage is suspended while it is live. |
| `optref T*`, `optrefmut T*` | An optional shared/exclusive borrow; dereference requires a presence check. |
| `ref T[]` | An immutable checked slice with an inline descriptor and a borrowed data lifetime. |
| `refmut T[]` | An exclusive checked slice with writable elements and an inline descriptor. |
| `ref[a] Record` | An inline struct value whose shared-reference fields borrow for one named lifetime. |
| `refmut[a] Record` | An inline exclusive borrowed struct; copies are reborrows of its one lifetime group. |
| `T*` | A legacy raw pointer; checked code may access it inside an explicit `unsafe:` block. |

Qualifiers are contextual: existing identifiers named `own`, `optown`, `ref`, `refmut`,
`optref` or `optrefmut`
retain their meaning. Type aliases preserve qualifiers. A checked pointer has
the same size and calling convention as a raw pointer. The pointee must be
sized and contain no references, raw pointers, unions or containers, except
for the explicitly supported aggregate forms below. Owned-field partial moves follow the initialization rules below; checked
pointers stored in globals remain rejected.

```w
int read_value(ref int* p):
	return *p

own int* make_value(int value):
	own int* p = new int
	*p = value
	return p

int main():
	own int* p = make_value(7)
	ref int* r = p
	int value = read_value(r)
	# r's last use is above; p can now move.
	q := p
	return *q - value
```

`new T` zero-initializes its allocation and traps on allocation failure. It
must initialize an owner in checked code. Owners and references require
initializers. Checked references cannot be null or fabricated by casts, pointer
arithmetic, raw-pointer conversion or an integer. Explicit optional references
use `optref` or `optrefmut`, described below; ordinary references remain non-null.

An owner's declaration, move and destruction have the same meaning without
`--safe`. Any function that uses a checked type is analyzed, together with its
called implementations. Removing the flag does not permit copying an owner,
using a moved owner or mutating a live shared borrow. Unannotated legacy
functions retain their existing behavior by default. Application semantic
records are retained before parsing, so a later imported ownership contract
cannot erase earlier binding identities.

### Optional owners

`optown T*` uses one pointer word and zero for absence. It must be explicitly
initialized with zero, new storage or an ownership transfer. Ordinary `own`
remains non-null. A named optional owner may be tested directly, with `!`,
or against zero; dereference, field access and conversion to non-null `own`
or `ref`/`refmut` require a proven-present value. New storage is known present;
nullable call results require a test. Joins, loops and replacement invalidate
stale presence evidence.

Copy-looking assignment, arguments and returns transfer an optional owner,
including an absent one: the source becomes moved and cannot be read or tested.
The destination retains the value's presence state. Reassignment evaluates the
replacement once, clears a transferred source slot, destroys any previous
payload and installs the replacement. Assigning zero ends ownership and its
external loans; existing independently extracted borrows still prevent a
conflicting destruction. Cleanup skips absent or moved slots on every supported
exit. No tag word, allocation or reference count is added to this representation.

Owned records may contain optional owner fields. Complete constructors must
supply those fields explicitly, including zero for absence. Extract an optional
child into a named owner before testing it; projected fields have no presence
refinement. Nested projection through an unproven optional child is rejected.
Partial moves and replacement use the same tracked field paths and recursive
conditional destruction as non-null owners. `optown[a,b] Record*` carries the
same external lifetime groups as its non-null counterpart. A proven-absent
transfer carries no external loans, even when the binding previously held a
borrowed payload. Imports, concrete generics and quantified callbacks preserve
the optional/required distinction.

Optional inline borrowed-record wrappers and optional checked slices remain
unsupported. Admitting them would require a separate representation and
construction contract; the pointer-sized optional contracts above do not
imply optional inline values.

## Lifetimes and calls

A shared or mutable reference can borrow a named owner, another reference, or
an initialized stack place (`ref int* r = &value`). A reborrow suspends
conflicting access through its parent until the child reference's last use.
Nonoptional reference bindings cannot be reassigned. Optional reference
bindings support replacement as described below.

Reference liveness follows branches and loop backedges. Ownership state must
be valid on every incoming path where a value is used. An early return does
not contaminate the state of a continuing branch. Field and index projections
conservatively borrow their whole backing value; this release does not prove
that different fields or indices are disjoint.

Function parameters express the call contract: `own` consumes an allocation,
`ref` reads it, and `refmut` may mutate it. A function returning an unannotated
`ref` or `refmut` must have exactly one borrowed parameter (`ref`, `refmut`, or a
slice). Its result borrows from that parameter's backing storage. This
signature rule supplies an implicit lifetime contract; scalar and owned
parameters do not contribute a lifetime. A mutable result requires a
`refmut` parameter. The body must return a reference with that provenance on
every normal path: returning a local, an owned parameter, or a fresh owner
is rejected even when its type matches.

```w
ref int* view(ref int* p):
	return p

int main():
	own int* p = new int
	*p = 7
	ref int* r = view(p)
	int value = *r
	# The returned borrow ends at its last use above.
	own int* q = p
	return *q - value
```

Returned references can select fields or array elements, pass through nested
calls, and reborrow references. Callers retain the original backing storage
and reborrow ancestry, so a live result prevents conflicting access, moves,
replacement or destruction. Projections still borrow the whole backing
value. Bind a result before dereferencing it; direct dereference of a call
result remains unsupported. Nonoptional references cannot be reassigned or fabricated
from a temporary owner. Multiple borrowed inputs require the named lifetime
contracts described below. Returned slices use the explicit checked slice
type described under arrays and slices.
Borrow initialization cannot interchange slice and scalar-reference
representations, even when ordinary warnings are nonfatal.
Buffer metadata (`.length` and `.data`) cannot be borrowed: a slice descriptor
can be local even when its elements outlive the function, and mutable access
to length metadata could invalidate bounds checks. Reading `.length` as a
scalar and borrowing slice elements remain supported. Ordinary struct fields
named `length` follow the usual field-borrow rules.

### Named lifetime contracts

Annotate a reference with `ref[a] T*` or `refmut[a] T*` to name its lifetime
relationship within a function signature. Without an outlives clause, the result's label must occur on
at least one borrowed input. The result may borrow from any input with that
label, and the caller conservatively keeps **all** those inputs borrowed
until the result's last use. Inputs with other labels do not contribute to
the result's lifetime.

```w
ref[a] int* choose(ref[a] int* left, ref[a] int* right, int first):
	if first: return left
	return right

int main():
	own int* left = new int
	own int* right = new int
	*left = 7
	*right = 9
	ref int* selected = choose(left, right, 1)
	int value = *selected
	# Both owners can be changed after the selected view's last use.
	*right = 10
	return value - 7
```

Moving, replacing or mutating either owner before `*selected` is read fails,
even when a particular call's scalar argument makes its result predictable.
A named mutable result requires every input sharing its result label to be
`refmut`; a shared input cannot supply exclusive access. A body returning
an input with another label, an owned parameter or local storage fails.

Labels are compile-time contracts and do not change pointer size or calling
convention. They are local to each signature: a forward declaration can
rename labels if it preserves the same relationships between result and
parameters. Aliases preserve labels. Annotating a local reference does not
extend its backing storage's lifetime. Ordinary references stay non-null;
`own` does not take a lifetime label.

### Explicit outlives clauses

Direct and concrete generic function signatures may add `where a > b` after the parameter list.
The clause says lifetime `a` outlives `b`; it permits a result labeled `b`
to borrow from an input labeled `a`. Separate multiple relationships with
commas. Relationships are transitive, and every label must occur on a borrowed
parameter or result. A result-only label is valid when an input outlives it.

```w
ref[shorter] int* shorten(ref[longer] int* value) where longer > shorter:
	return value

ref[c] int* choose_shorter(ref[a] int* left, ref[b] int* right, int first) where a > b, b > c:
	if first: return left
	return right
```

The caller retains **all** possible backing inputs whose labels outlive the
result, including transitive predecessors, until the result's last use.
The body cannot return an unrelated input or local storage. Mutable results
still require every contributing input to be mutable; the clause does not
change pointee types or permit mutation through shared references. Slices,
optional references and the existing single-group borrowed records use the
same result-provenance rule.

Forward declarations may consistently rename labels, reorder clauses and
add redundant transitive edges. The normalized relationship between signature
positions must agree, including on unused and later declarations. Self-edges
are redundant; cycles require both directions and do not extend any actual
storage lifetime. Contracts apply with or without `--safe`.

Direct functions and concrete generic specializations support at most ten
parameters. For example:

```w
ref[b] T* generic_shorten[T](ref[a] T* value) where a > b:
	return value
```

Explicit calls (`generic_shorten[int](input)`) and calls inferred from a typed
checked reference (`generic_shorten(input)`) preserve the same contract. An
untyped address expression alone does not infer `T`; use a named checked
reference or explicit type arguments. Each instantiated body and its retained
call signature must agree, including through aliases, imports and recursion.
Unused generic templates retain the ordinary deferred-instantiation behavior.
Explicit generic specializations also accept borrowed record and slice
arguments/results. Signatures can use `ref[a,b] T`, `refmut[a] T` or
`ref[a] T[]`, and an explicit type argument can itself be a checked aggregate
or an alias. Concrete fields, labels, ownership effects and the ordinary
aggregate calling convention are preserved; the specialized body is checked
against that concrete contract. For example:

```w
ref[a] T[] tail[T](ref[a] T[] values, int start):
	return values[start:]
```

Pass a checked slice for a subrange expression; raw-array slicing retains its
existing restriction. Complete construction, presence checks, lifetime groups,
return reservations and mutable reborrow rules apply as for direct calls.
Inferred whole-parameter calls such as `echo(value)` where `T echo[T](T value)`
now preserve checked aggregate arguments and return their concrete layouts.
The retained emitter reserves the result buffer before evaluating arguments,
compacts nested argument temporaries, and reuses signatures across nested calls.
The streaming emitter retains its explicit-type-argument requirement for aggregate
results. Inference also inverts `ref[a,b] T`, `refmut[a] T` and `ref[a] T[]`
parameters. Borrowed records supply their plain template and checked slices
or fixed arrays supply their element type. The concrete signature rechecks
qualifiers, group arity, outlives relationships and argument conflicts. A bare
`T` parameter retains the entire checked type instead of stripping its wrapper.
Checked generic method calls support both `receiver.function[T](...)` and
`receiver.function(...)`. The receiver is the first argument of the specialized
call, evaluated once before the remaining arguments. Record-prefixed definitions
retain precedence; see [generic methods](generics.md#generic-method-calls).

Check mode keeps its synthetic `int` instantiation for unused scalar, pointer
and slice templates. A bare `ref T` or `refmut T` constraint requires a record,
so an unused template with that constraint waits for concrete specialization
instead of being checked against an invalid `int` substitute. Every used
specialization is checked. Runtime representation, allocation and destruction
order are unchanged.

### Shared-reference structs

A struct may declare scalar fields and shared pointer fields bearing one
common lifetime label. `ref[a] Record` binds that group at each use site;
it is an inline value with the ordinary struct layout, not a pointer to the
record. Complete construction is required:

```w
struct Tagged:
	ref[item] int* value
	int tag

ref[a] Tagged tagged(ref[a] int* value):
	return Tagged(value, 7)

ref[a] int* contents(ref[a] Tagged item):
	return item.value
```

Copies and returned values preserve the borrowed data's lifetime. If several
fields borrow different values, the checker conservatively keeps every value
borrowed for every extracted reference. Earlier constructor arguments remain
borrowed while later arguments evaluate. Positional and named constructors
must initialize each field exactly once; null references and omitted fields
fail.

Shared-reference fields can be extracted from named values or returned
temporaries. Addresses of the inline record's fields cannot escape: its
local storage has a different lifetime from the data its references borrow.
Checked slice fields (`ref[item] T[]`) use the same group and copy their
inline descriptors. Bind an extracted slice before indexing it; direct
`record.values[0]` is not yet supported. Field mutation, wrapper reassignment, unqualified record
storage, heap construction and mutable-reference fields remain unsupported in
this shared form. Nested wrappers and independent groups are described below.

### Mutable-reference structs

`refmut[a] Record` extends the inline record form to mutable-reference fields.
Its template may contain scalars, shared pointers, mutable pointers and shared
checked slices, all reference fields using one common named group:

```w
struct ExclusiveView:
	refmut[field] int* item
	int amount

refmut[a] ExclusiveView exclusive_view(refmut[a] int* value):
	return ExclusiveView(value, 3)

void increase(refmut ExclusiveView view):
	int amount = view.amount
	refmut int* item = view.item
	*item += amount
```

Construction supplies every field and reserves each earlier reference while
later arguments evaluate. Copying, passing or returning the wrapper creates
a reborrow: the parent is suspended while a conflicting child remains live.
The checker conservatively borrows the entire lifetime group, so different
fields do not provide disjoint mutable access. Shared fields cannot become
mutable references. An extracted field view keeps the group's backing values
alive, independently of the wrapper's inline descriptor storage.

Scalar metadata may be changed. Reference-field replacement, wrapper
reassignment, descriptor-field addresses, mixed owned/borrowed
fields and partial moves remain rejected for these borrowed wrappers. Nullable
reference fields follow the explicit construction rules below. Independent groups use the explicit
multi-label form described below.

### Nested borrowed structs

A borrowed field may itself be an inline borrowed record:

```w
struct Cell:
	ref[item] int* value
	int tag

struct View:
	ref[group] Cell cell
	int tag

ref[a] View make_view(ref[a] int* value):
	return View(Cell(value, 3), 5)
```

The nested wrapper renames its inner group into the enclosing group. Here
`Cell` owns the label `item`, its field in `View` uses `group`, and `ref[a] View`
binds that outer group to `a`. Fields sharing a template label remain one
conservative group. Multiple labels introduce independent groups as below.

Construct every field at every level. Copies, imported functions, returned
records and quantified callbacks preserve the complete union of backing roots
and reborrow parents. `view.cell.value` can initialize a reference, and
`view.cell.tag` reads inline scalar metadata. Bind an extracted pointer or
slice before dereferencing or indexing it. Nested descriptor-field addresses
cannot escape, including addresses of scalar metadata.

Shared wrappers admit shared nested wrappers. Mutable wrappers additionally
admit mutable nested wrappers; a shared outer value cannot expose exclusive
inner access. Extracting any view conservatively keeps the whole enclosing
group borrowed, including sibling fields. Mutable scalar metadata projection
uses the containing place; it does not create a new exclusive data borrow
merely to read metadata. Reference-field replacement and wrapper reassignment
remain rejected.

Nested shapes are bounded to depth 32 and 256 expanded record nodes. Cyclic
or larger shapes fail validation. Plain unwrapped nested records, optional
fields and mixed ownership remain unsupported. Layout and calling conventions
are unchanged; nesting introduces no
runtime allocation or destructor.

### Independent aggregate lifetime groups

A borrowed record may declare several groups. Bind them with `ref[a,b] Record`
or `refmut[a,b] Record`, in the order their labels first occur in the template's
fields:

```w
struct Pair:
	refmut[left] int* first
	refmut[right] int* second

refmut[a] int* first(refmut[a,b] Pair pair):
	return pair.first

int main():
	int x = 3
	int y = 4
	refmut[a,b] Pair pair = Pair(&x, &y)
	refmut int* p = first(pair)
	y = 9
	*p = 5
	return x + y - 14
```

The result keeps only the first group's origins alive. Returning `pair.second`
under this contract fails checking. Borrowing both fields through the same
mutable wrapper permits disjoint access; fields with the same template label
still retain their combined origins. Whole-record use reserves all groups.
A wrapper that remains live for later whole-value use can therefore keep every
group borrowed, even after one field has been extracted.

Nested annotations map the inner template's groups into the containing
record. For example, a field `ref[x,y] Pair pair` contributes `x` and `y` to
its enclosing template; `ref[x,x] Pair pair` deliberately combines both into
one enclosing group. Renaming at a use site does not change field layout or
component identity. Repeated labels in a function contract constrain every
corresponding input/output position; the caller retains all possible origins.

Every multi-group wrapper needs exactly one explicit label per template group.
The one-group form retains its existing omitted-label inference. Pointer and
slice types still take one label. Quantified signatures and explicit
outlives clauses retain their ten-parameter limit. Checked contracts allow at
most 32 expanded slots, counting one for each aggregate group and one for each
other parameter or result. Outlives clauses,
forward declarations and quantified callbacks use these expanded positions.
Each borrowed result component must derive from its permitted input components.

Construction evaluates each field once, preserving argument reservations.
Copies, control-flow joins, calls and returns retain every origin and ancestor
within each group. Mixed owners and direct field replacement are described
below. Borrowed wrapper reassignment remains a separate requirement.
There is no new runtime representation or allocation for group metadata.

### Owned structs

An owner can contain other owners. The struct must contain pointer-free
fields and `own T*` fields whose pointees recursively meet the same rule.
Audited buffer and byte-string owners are also permitted as fields.

```w
struct Pair:
	own int* first
	own int* second
	int tag

own Pair* make_pair():
	own int* first = new int
	own int* second = new int
	*first = 7
	*second = 9
	return new Pair(first, second, 3)
```

Each constructor must initialize every field once. Moving an owner argument
clears its source slot immediately; later arguments cannot read the moved
allocation. They may reinitialize the source binding with a new owner. Bare
`new Pair`, missing fields, null owners and raw `Pair` value copies fail.
Whole owners can move through bindings, calls and returns. Replacement
evaluates the new value, destroys the old value, then installs the new one.
Destruction recursively drops owned fields in reverse declaration order,
then frees the containing allocation. Moved source slots are skipped.

Borrowing a child owner borrows the whole containing owner. `ref Pair*` and
`refmut Pair*` parameters can lend child payloads; a shared parent cannot
supply an exclusive child borrow. Partial field moves and owner-field
assignment remain rejected. Recursive ownership type cycles are not supported.
Borrowed fields use the labeled form below. Allocation failure
and other traps terminate the process; cleanup during termination is not
promised.

Owned type graphs are bounded to depth 32 and at most 256 allocation nodes
per expanded destructor. Larger graphs produce errors instead of unbounded
compiler work.

### Owners carrying borrowed fields

`own[a,b] Record*` owns its allocation and retains the borrowed data named by
its field groups. Each label binds one template group, ordered by first
occurrence, just as for borrowed records. Even a one-group mixed owner must
supply its label explicitly. Its fields may be plain values, supported owned
children, shared/exclusive pointers, shared slices or nested borrowed records. An owned
child with borrowed data carries its own mapped labels.

```w
struct StoredView:
	own int* stored
	ref[item] int* item
	ref[data] int[] data

own[a,b] StoredView* store(ref[a] int* item, ref[b] int[] data):
	return new StoredView(new int, item, data)

ref[b] int[] take_data(own[a,b] StoredView* view):
	return view.data
```

Construction initializes every field once, moves owned arguments, and reserves
earlier borrowed data while evaluating later arguments. The owner moves through
bindings, direct/generic/quantified calls and returns; each external component
keeps its origins and reborrow parents. Every returned component must satisfy
the declared input contract. Local data cannot escape inside a returned owner.
A live owner prevents writes or invalidation of its shared data and reserves
exclusive groups against other reads too.

`take_data` consumes and destroys the descriptor and its owned child, but the
returned slice keeps the external data alive. Its inline descriptor is copied
before cleanup. By contrast, borrowing `view.stored` keeps the owner's allocation
alive and cannot be returned under an external-data label. Labels never stand
for the descriptor allocation. The same separation holds through nested owned
children, imports and aliases.

Whole-binding replacement drops the old owner exactly once. The checker joins
old and new borrowed origins conservatively, including across loops; replacing
an owner does not necessarily release its old external loans before its last
use. Borrowing an owned child prevents moves and destruction of its containing
allocation; distinct owned children can be borrowed independently as described
below.
Optional borrowed fields, and whole mixed-owner `refmut Record*` views remain rejected
pending their separate implementation gates. Shared whole-owner views are
described below. Raw/unannotated mixed
owner forms, self-reference and checked globals remain rejected too.

The runtime pointer layout, recursive cleanup order, allocation-failure policy
and depth/work bounds are unchanged. Borrowed fields require no extra allocation
or destruction; their component metadata exists only during compilation.

### Exclusive fields in mixed owners

An owner may carry `refmut[group] T*` or `refmut[group] Record` fields. A group
containing any exclusive field retains exclusive access; other groups can remain
shared. Nested owned children map their access kinds into the enclosing groups.
Borrowed exclusive wrappers retain their existing conservative access rules.

```w
struct Editor:
	own int* scratch
	refmut[item] int* item
	ref[context] int* context

own[a,b] Editor* editor(refmut[a] int* item, ref[b] int* context):
	return new Editor(new int, item, context)

refmut[a] int* take_item(own[a,b] Editor* editor):
	return editor.item
```

Moving this owner transfers its exclusive data loans. The move fails if a child
view of an exclusive group remains live: a callee could mutate that data. A
returned mutable field can outlive destruction of its descriptor, but its
contract must come from an exclusive input group. Shared fields cannot be
upgraded, including through aliases, callbacks and shared whole-owner views.

Constructors and calls reserve shared/exclusive groups separately while evaluating
later arguments. Deferred work cannot read or write an exclusive returned group;
it can still read an unrelated shared group. Whole-owner replacement may release
the overwritten loan before evaluating its replacement only when the right-hand
expression does not read the old binding. Child views still prevent conflicting
replacement. A replacement cannot borrow through the old owner or a view derived
from it: that would create a cycle in borrow ancestry. Provenance joins remain
conservative across replacement and loops.

### Replacing an owned field

A direct owned field of a named unique owner can be replaced:

```w
struct Pair:
	own int* first
	own int* second

int main():
	own Pair* pair = new Pair(new int, new int)
	pair.first = new int
	return 0
```

The destination address and replacement are evaluated once. The old field and
its owned descendants are destroyed before the replacement is installed. The
containing allocation stays reserved throughout evaluation, so an argument
cannot consume it and leave a dangling destination. A live borrow of the replaced child or whole owner prevents replacement.
A borrow of a distinct owned sibling can remain live.

Replacing an owned child that carries external references joins its origins
into the enclosing lifetime groups. A group retained by a sibling field remains
reserved. A group belonging only to the replaced field can release its old loan
during evaluation when the replacement does not read the containing owner.
Origins join conservatively across branches and loops. A replacement cannot
borrow its containing allocation or introduce a cycle through a view derived
from that owner.

Replacement through a borrowed receiver, a temporary, or a nested owned-field
receiver remains rejected; direct partial moves are described below.

### Replacing a borrowed field in an owner

A direct `ref` or `refmut` pointer, slice, or borrowed-record field of a named
unique owner can be replaced. Slice and record descriptors are copied by value;
no allocation or destruction is added. The replacement must match the field's
access kind and every lifetime component. Shared references cannot initialize
an exclusive field.

The containing allocation stays reserved during evaluation. New external origins
join the owner's groups, with the same conservative sibling and loop rules as
owned-field replacement. Replacing a shared external pointer does not invalidate
an existing view of its old backing data; that view retains its own lifetime
obligation. A live view of the containing allocation still prevents mutation.
Replacements cannot borrow their containing allocation or create reborrow cycles.
Returned owners and extracted fields must continue to meet their declared input
contracts, including reservations for deferred work.

A checked field can be rebound through a stable unique owning path, including
the nested paths described below. Borrowed receivers and standalone borrowed
wrapper reassignment remain rejected. This restriction prevents a helper from
silently changing a caller's backing-storage obligations through a borrowed
receiver without an effect contract.

### Disjoint owned-child borrows

Distinct owned children have separate checked allocation identities:

```w
refmut int* first = pair.first
refmut int* second = pair.second
*first = 7
*second = 8
```

A live child view blocks a whole-parent move, replacement, borrow, or destruction
when the accesses conflict. Reborrowing the same child conflicts too. A child can
be replaced while a distinct sibling is borrowed; the containing allocation
remains reserved during replacement evaluation.

Projection preserves all possible roots through aliases, calls, branch joins
and nested named child views. Inside a function, an owned-child projection from
a borrowed parameter can be returned under that parameter's lifetime. At call
sites, the declared result contract remains conservative about which child a
helper selects. A local or consumed owner's child cannot escape under an
unrelated borrowed-input label.

Known owned-child and pointer-free scalar fields have disjoint identities.
Uncertain array indices retain overlap within their containing array. Expansion is
bounded to 32 levels and 256 children per binding; a projection beyond the bound
keeps its containing root. This fallback may reject a disjoint access but never
assumes it is independent. Partial moves require an explicit tracked child
identity and follow the initialization rules below.

### Disjoint scalar fields and plain record values

Known scalar fields, nested pointer-free records and distinct array fields have
separate storage identities too. A borrow of `pair.first` can coexist with a
write or mutable borrow of `pair.second`. Whole-record access still overlaps
both. Two indices into the same array remain conservative even when their
source expressions differ; distinct array fields can be borrowed separately.

Pointer-free record value constructors are checked for complete initialization,
duplicate fields and nominal type agreement. Fields evaluate once in source
order, including named arguments. The same rules cover stack records, nested
record values and returned records. Their ordinary by-value representation is
unchanged. Raw-pointer or borrowed fields require their existing checked wrapper
contracts; this plain-value form cannot bypass those contracts.

Field projection preserves every possible root after aliases and control-flow
joins. Returned field references may use their borrowed parameter's contract;
callers still retain the whole input group unless a more precise contract is
available. Bounded path expansion falls back to the containing root, and partial
moves still apply only to tracked owned fields.

### Partial moves of owned children

A direct owned child of a named unique owner can be transferred:

```w
own int* first = pair.first
refmut int* second = pair.second
*second = 8
pair.first = first
own Pair* complete = pair
```

Moving a child leaves that field uninitialized. Its initialized siblings and
scalar descriptor fields remain usable. Reading or moving that child again
fails until it is replaced. A whole-owner move, return, or borrow requires all
owned descendants to be initialized on every incoming control-flow path.
Reinitializing the moved field restores its subtree; whole-owner replacement
restores all children. Branch and loop joins retain possible moved states.

The emitter clears exactly the transferred child slot while preserving its
value. Recursive cleanup already skips null slots, so scope exit, early return,
break, continue, parent replacement and destruction drop only the remaining
children. No runtime ownership table or allocation is added. Field replacement
reserves the destination allocation while allowing transfers between its child
slots, including self-replacement. Consuming the parent during RHS evaluation
still fails because it would invalidate that saved address.

Transfers retain mixed-child external lifetime groups and access kinds. Reading
external data through a moved child's old path fails, including nested
projections. Whole-owner provenance remains conservative: moving one child does
not discard backing-storage obligations retained by the parent metadata.

Transfers support direct children and stable nested ownership paths rooted in
named unique owners. Borrowed receivers, effectful receivers, uncertain indices
and untracked paths cannot transfer ownership. Broader replacement forms remain
required under #695.

### Nested owned-child transfers

`own int* item = outer.left.first` transfers a nested owned child when every
intermediate receiver is owned and the chain starts at a named unique owner.
The checker tracks the selected path and every ancestor. Initialized siblings
remain usable; moving or borrowing any entire ancestor requires all of its
owned descendants to be initialized. Passing a partially moved child to a
helper is rejected even when the helper would otherwise accept that type.

The emitter preserves the transferred value, recomputes the stable field
address, and clears that slot before cleanup. Only named variables and owned
field projections are admitted in this chain, so address recomputation has no
user effects. Nested constructors, calls, generic transfers, returns and mixed
external lifetime groups preserve the same ownership and cleanup obligations.
A direct replacement of an ancestor restores its subtree. Rebinding a field
through a nested receiver retains its separate replacement gate.

### Shared views of mixed owners

`ref[a] Record*` can borrow a mixed owner whose fields meet the rules above. Helpers can inspect an owner without consuming it:

```w
ref[a] int[] inspect_data(ref[a] StoredView* view):
	return view.data
```

The single view lifetime conservatively retains the descriptor allocation and
all external data groups. Copies, calls, returned views and nested owned-child
projections preserve that union. An extracted field through this shared view
keeps the descriptor alive too, including when the field itself points to
external data. Moving or replacing the owner, or changing any retained backing
data, fails while the extracted view remains live. A direct extraction through
an owning binding can still retain just its external field group.

Shared views cannot lend mutable fields or owned children. Returning the whole
view of a local/consumed owner remains an escape error even if its external data
outlives the call. Mutable and optional whole-owner views follow the rules below. There is no new runtime descriptor,
allocation or cleanup work.

### Mutable views of mixed owners

`refmut[a] Record*` can borrow a mixed owner without consuming it. The view
conservatively retains the descriptor allocation and every external group under
one lifetime. Checked helpers, concrete generics and quantified callbacks may
receive or return that mutable view. Returning a view of a local or consumed
owner remains an escape error.

Scalar fields may be mutated, and owned children or mutable-reference fields
may lend mutable views. Shared fields remain shared even through a mutable
receiver. A shared view cannot be promoted to a mutable view. Shared projections
through nested owned children preserve shared access, so multiple shared views
can coexist; conflicting mutable access remains rejected. Borrowing the whole
mixed owner remains conservative across its external groups.

Field rebinding and partial moves still require a stable unique owning path;
a mutable borrowed receiver does not transfer ownership or replace its stored
lifetime contract. Optional whole-owner views require the presence rules below.
No pointer layout, descriptor, allocation or cleanup representation changes.

### Optional mixed-owner views

`optref Record*` and `optrefmut Record*` use the existing nullable checked-pointer
representation to view a mixed owner. A present view retains the allocation and
all external groups, just like a nonoptional whole-owner view. A proven-absent
view carries no live storage obligation. Copies, assignments, generic calls,
quantified callbacks and returned views preserve the existing optional contract.

A dominating presence check is required before every scalar, owned-child or
borrowed-field projection. Assignments, branch joins and loop edges invalidate
stale presence proofs. Making the optional view absent does not release a field
view that was previously extracted from it; that field view keeps its own
origins and reborrow ancestry. Mutable promotion from shared views, local-owner
escapes and reborrow cycles remain errors.

Optional owners and optional inline borrowed-record wrappers remain rejected.
Nullable reference fields follow the construction rules below. Whole-owner
views reuse the existing nullable pointer and add no allocation, runtime
descriptor or cleanup representation.

### Nullable reference fields

Borrowed records and mixed owners may declare named `optref[group] T*` or
`optrefmut[group] T*` fields with pointer-free pointees. An exclusive field
requires an exclusive borrowed wrapper or an owning record. Every constructor
must still initialize every field explicitly; use `0` to initialize absence.
An absent pointer contributes no backing root. Present pointers preserve the
field's declared lifetime group and ordinary shared/exclusive reservations.

Read a nullable field into a named optional local, then test that local before
dereferencing it. Presence refinement currently tracks named bindings, so a
condition on a projected field does not establish a reusable field proof.
Copies, nested group mapping, checked callbacks and returns retain optionality.
A mutable receiver cannot promote a shared nullable field to exclusive access.

Unique owning paths may replace nullable fields with a compatible view or `0`.
Historical origins remain conservatively joined, and previously extracted views
keep their own backing-storage obligations after replacement. Borrowed-wrapper
field rebinding remains rejected. Optional owners, optional inline record
wrappers and optional slice descriptors require separate representation rules;
this extension uses ordinary nullable pointer fields and adds no drop action.

### Replacement through nested unique owners

A checked field may be replaced through a stable chain of owned fields rooted
in a named unique owner, for example `outer.middle.child = new Child(...)` or
`outer.middle.child.view = data`. Every receiver along the chain must remain
initialized. Calls, indexed receivers and borrowed receivers do not establish
this unique path and remain rejected.

The destination is evaluated once before the right-hand side. Its receiver and
ancestors cannot be moved or destroyed during that evaluation; separate sibling
owners may move. Assigning a moved owned child restores only that child's
initialization state. Siblings that remain moved still prevent a whole-owner
borrow or transfer. Self-assignment transfers and clears the old source slot
before installing the value, with no duplicate destruction.

External lifetime components map through the declared field labels at every
ownership level. Only groups held exclusively by the replaced field may be
suspended during right-hand-side evaluation; siblings at every ancestor retain
their obligations. Incoming and historical origins remain conservatively joined
at the containing owner. Local escapes, incompatible return lifetimes,
self-reference and reborrow cycles remain rejected. This adds no allocation or
new descriptor representation; existing field-assignment lowering handles
recursive and opaque destruction.

### Call checking

Owned returns must transfer an owner on every normal path. Recursion,
forward declarations and imported functions use the same signature contract;
the implementation is checked even without `--safe`. Checked methods and UFCS
calls use the receiver's explicit first-parameter contract and evaluate it
before the remaining arguments. An owned receiver transfers ownership;
shared/mutable receivers borrow with the ordinary call rules.
Forward declarations resolve to a checked implementation and must agree with
its parameter and return contracts.

Direct generic calls check their concrete specialized signature and body.
Scalar and sized-pointer type arguments, including inferred whole-parameter
types, preserve checked qualifiers; an `own` argument transfers exactly once. Pointer-qualified
generic signatures also support named lifetimes:

```w
ref[a] T* generic_view[T](ref[a] T* value):
	return value
```

The result keeps the same backing roots as an ordinary reference-returning
call. Generic syntax does not bypass the checker. Checked slices and borrowed
records retain their concrete layouts and contracts in explicit and inferred
calls, including generic method syntax. Inside a specialization, `new T` and
`new T(arguments)` resolve `T` through its active type substitution. Default
allocation still requires a pointer-free sized value; record construction
checks every concrete field, transfers owners once and preserves borrowed
field lifetimes. Function pointers use explicit quantified contracts; owned
callback objects can pair them with an environment as described below.

### Quantified function pointers

A checked function type binds its lifetime labels explicitly:

```w
type View = fn[a](ref[a] int*) -> ref[a] int*

ref[x] int* view(ref[x] int* value):
	return value

int main():
	View* callback = view
	int value = 7
	ref int* result = callback(&value)
	return *result - 7
```

Each invocation instantiates the contract independently. The result borrows
from the inputs specified by that invocation; storing the function address
does not capture any storage. `fn[]` marks a checked signature without named
lifetimes. Unnamed borrowed results retain sole-input inference. An explicit
`where a > b` clause follows the result type. Every named borrowed slot must
be bound and every binder must be used. Nested function types bind their own
labels independently.

Values use the existing `View*` representation. Locals and parameters may
hold them, ordinary functions may return them, and a returned callable may
be invoked directly. Assignment and argument passing require exact contract
agreement after consistent lifetime renaming, including nested signatures,
mutability, optionality and normalized outlives relations. There is no
function-contract subtyping. The implementation body is checked even when
its address is never called. Forward and imported definitions use the same
rules as direct calls.

Indirect calls preserve argument evaluation order, backing roots, reborrow
parents and owner transfers. An owning argument moves once; owning results
participate in normal replacement and scope cleanup. Checked slices and the
currently supported borrowed records keep their ordinary by-value ABI.

Null, uninitialized, raw or cast-forged callables are rejected, as are raw
escapes, global callable storage and const-qualified callable
forms. These contracts describe ordinary W entry points; generators, kernels,
variadic entry points and unaudited foreign functions cannot become checked
function values. Signatures admit at most ten parameters; nested validation is
bounded to depth 32 and 256 expanded type visits.

### Owned callback environments

An owned record may store quantified function pointers alongside its owned
environment. Construction supplies every field explicitly; default, missing,
null, forged and incompatible callable fields are rejected. A callback object
uses ordinary record syntax rather than an implicit environment or lambda:

```w
struct Environment:
	own int* value

type Invoke = fn[](ref Environment*, int) -> int

struct Callback:
	Invoke* code
	own Environment* environment

int invoke(ref Environment* environment, int extra):
	ref int* value = environment.value
	return *value + extra

own Callback* capture(int number):
	own int* value = new int
	*value = number
	own Environment* environment = new Environment(value)
	return new Callback(invoke, environment)
```

The returned owner can escape its construction scope. Invoke it by borrowing
its environment and passing that borrow to its `code` field. The function
pointer is a static code address and may be copied independently; the
environment remains governed by its own owner or borrow. Lifetime-bearing
results keep the invocation's backing roots, so a live returned view prevents
replacement or destruction of its environment. A shared receiver does not
permit mutation through an incompatible mutable callback contract.

Environment fields may themselves borrow external storage using the existing
named ownership groups. Such a callback cannot outlive those external roots.
Moving a callback transfers its owned environment once; replacing it or leaving
scope, including an early failure return, recursively destroys initialized
owned fields. Moving the environment out leaves the code field readable and
prevents a second destruction of that environment. Replacement of the code
field requires the same quantified contract.

This representation adds no hidden environment allocation or reference count:
the source chooses its ordinary owned records and allocations. Callable fields
do not make a record pointer-free, so zero initialization, unqualified stack
aggregate storage and unchecked copying do not become admissible. Raw function
fields, erased signatures, implicit captures and anonymous lambda syntax are
not part of this storage form.

### Argument effects

Argument evaluation is included in checking: an earlier mutable argument
cannot coexist with a later read of the same storage, including a read or
write hidden inside a nested call. A projected store keeps its destination
borrowed while evaluating the right-hand expression; indexing likewise keeps
the receiver borrowed while evaluating the index. Nested moves, replacement
or mutation of that backing storage are rejected. Reading the same storage
for an update, or replacing an owner in a separate statement, remains valid.

## Optional references

`optref T*` and `optrefmut T*` are nullable shared and mutable references.
They have the same one-pointer representation as `ref T*` and `refmut T*`,
with the integer literal `0` representing absence. Ordinary references remain
non-null. Optional references accept the same named lifetime spelling:
`optref[a] T*` and `optrefmut[a] T*`.

```w
int optional_value(optref int* value):
	if value == 0: return 0
	return *value

optref int* maybe_value(ref int* value, int present):
	if present: return value
	return 0
```

Dereferencing, projecting a field or passing an optional value to a nonoptional
reference parameter requires proof of presence. Initializing with an address or
nonoptional reference establishes that proof. Tests `value`, `!value`,
`value == 0` and `value != 0` refine the appropriate branch, including an early
return and a `while` guard. Short-circuit `&&`/`||` and scalar ternaries preserve
these proofs. Bitwise `&`/`|` do not. Branch joins and loop backedges retain all
possible absence states; an assignment invalidates the previous proof. Compound
tests containing optional assignments conservatively do not establish a final
branch proof.

An initialized optional local can be assigned `0`, a compatible checked pointer,
or a borrowed call result. Origins and reborrow parents conservatively include
all values ever assigned in that function. This can retain a borrow longer than
necessary, but replacement cannot discard a backing-storage obligation. Clearing
a parent does not clear a copied child's borrow. Replacements that create a
reborrow ancestry cycle are rejected. Nonoptional locals, slices and aggregate
wrappers retain their existing reassignment restrictions.

Optional parameters and results use the existing inferred or named lifetime
contracts. Returning `0` is permitted; returning a view of local storage is not.
A returned optional view conservatively borrows every candidate input even when
the callee may choose absence. An unannotated optional result without borrowed inputs may return absence only;
its body still cannot return a view of local or owned storage. Optional slices,
reference fabrication through casts and arbitrary pointer arithmetic remain
unsupported. All these rules apply with or without `--safe`.

## Arrays, slices and control flow

Fixed arrays of pointer-free values are initialized by the existing array
runtime. Array and slice indices retain runtime bounds checks. A slice made
with `array[start:end]` is an immutable shared view in checked code; subviews
retain the original backing storage's lifetime. A slice parameter borrows for
the call. Array storage cannot be copied or returned by value; pass a slice.
Raw `.data` access requires an unsafe boundary.

Use `ref T[]` for a checked slice whose descriptor is stored inline. It can
borrow a fixed array or another checked slice. Functions return these views
using `ref[a] T[]` with the same named lifetime rules as reference returns:

```w
ref[a] int[] view(ref[a] int[] values):
	ref int[] local = values
	return local

int main():
	int[3] values
	values[0] = 7
	ref int[] result = view(values)
	return result[0] - 7
```

Checked descriptors are copied by value into parameters, local storage and
the caller's result buffer. Copying or returning a descriptor does not
allocate or copy the backing elements. The data must outlive every derived
view. Ranges of checked slices also use inline descriptors:
`ref int[] tail = result[1:]`, `result[:]` and `result[0:0]` are supported.
Their bounds are evaluated once, checked at runtime and included in borrow
checking. A bound expression cannot invalidate the data being sliced. Bind
a temporary view before indexing it or reading its length; direct scalar
projections from unnamed temporaries remain rejected.

`refmut T[]` uses the same inline descriptor ABI and borrows the backing
storage exclusively. Its elements may be read and written. A shared reborrow
temporarily freezes mutation until the shared view's last use; a shared slice
cannot be upgraded to a mutable slice. Mutable subranges keep the complete
backing-storage loan, so even nonoverlapping ranges do not establish disjoint
access. Named return contracts, quantified callbacks and explicit/inferred
generic calls preserve the access kind and lifetime. Borrowed mutable records
may contain mutable-slice fields under the existing group rules.

Ordinary `T[]` keeps its legacy pointer-to-descriptor ABI; implicit
mixing with the inline checked representation is rejected. Explicit descriptor
construction, metadata borrowing and reassignment remain unsupported.
Slice elements must be pointer-free sized values. To obtain a
checked subrange of a fixed array, first bind a checked full view; slicing
the array directly still produces the legacy representation.

The supported control flow is blocks, `if`/`else`, `while`, range `for`, scalar
`switch`, `break`, `continue`, returns, short-circuit Boolean expressions and
scalar conditional expressions. Range bounds and step evaluate once in source
order; `continue` reaches the implicit index update. Switch labels retain
their evaluation order and W's no-fallthrough behavior. Container iteration,
generators, arbitrary `goto`, GPU operations and legacy container operations
remain unsupported. The audited concrete storage APIs
below are the supported growable-container interface.
Declarations require a lexical block, including inside conditionals and
loops. Executable assembly bodies are rejected.

## Checked buffers and byte strings

Import `lib.safe_buffer` for two concrete, opaque owner types:
`own WIntBuffer*` holds word-sized integers and `own WByteString*` holds
bytes. These are distinct from legacy `list[T]` and string-builder values.
Metadata, raw allocation, casts and private runtime helpers are unavailable
to checked callers.

| Operation | Integer buffer | Byte string |
| --- | --- | --- |
| Construct empty owner | `int_buffer_new()` | `byte_string_new()` |
| Length | `int_buffer_length(value)` | `byte_string_length(value)` |
| Push an element | `int_buffer_push(value, element)` | `byte_string_push(value, element)` |
| Indexed read | `int_buffer_get(value, index)` | `byte_string_get(value, index)` |
| Indexed replacement | `int_buffer_set(value, index, element)` | `byte_string_set(value, index, element)` |
| Pop by value | `int_buffer_pop(value)` | `byte_string_pop(value)` |
| Clear | `int_buffer_clear(value)` | `byte_string_clear(value)` |
| Shared view | `int_buffer_view(value)` → `ref int[]` | `byte_string_view(value)` → `ref byte[]` |

Read operations borrow shared; every mutation borrows exclusive access to
the whole container, even when spare capacity would avoid relocation. A
live view prevents push, set, pop, clear, replacement, moves and destruction.
Mutation is available again after the view's last use. Views returned from
other functions or stored in borrowed structs preserve this relationship.
Drop is automatic; there is no public manual-free function.

```w
import lib.safe_buffer

int main():
	own WIntBuffer* values = int_buffer_new()
	int_buffer_push(values, 7)
	ref int[] view = int_buffer_view(values)
	int first = view[0]
	# Moving this push before view[0] would fail the borrow check.
	int_buffer_push(values, 9)
	return first - 7
```

`byte_string_from(view)` copies a `ref byte[]` into a new owner.
`byte_string_append(destination, view)` copies a bounded view onto an
existing string. Ordinary self-append is rejected because the shared view
conflicts with the exclusive destination borrow. Strings have explicit
lengths, preserve embedded NUL bytes and impose no UTF-8 or terminator
invariant. Empty strings and empty views are supported.

Negative or out-of-range indices, empty pop, size overflow and allocation
failure trap. Growth checks arithmetic before allocation and reads only the
initialized prefix. The exact library source is pinned by the compiler;
changed implementations do not inherit its audited contract. Generic
buffers, owned-element containers, maps, sets and concurrent access remain
future extensions, except for the concrete owned-element buffer below.

### Buffers of owned integers

`own WOwnedIntBuffer*` owns its `own int*` elements. Construct it with
`owned_int_buffer_new()`. `owned_int_buffer_push(buffer, owner)` consumes an
owner; `owned_int_buffer_set(buffer, index, owner)` consumes the replacement
and destroys the previous element. `owned_int_buffer_pop(buffer)` transfers
the last owner to the caller and traps on an empty buffer.

`owned_int_buffer_get(buffer, index)` returns a shared `ref int*` tied to the
buffer. Every mutation, move, replacement and destruction is forbidden while
that view remains live. After popping an owner, that allocation is independent
of the buffer and survives its clear, replacement or destruction.
`owned_int_buffer_length` reads the length; `owned_int_buffer_clear` destroys
remaining elements in reverse order. Automatic buffer destruction clears the
elements, frees slot storage, then frees metadata. Owned records may contain
this buffer. Metadata and raw slot helpers remain inaccessible.

This concrete API does not yet provide arbitrary element types, generic
collection wrappers, maps, sets or escaping iterators.

### Checked byte arena

`own WByteArena*` is a separate, opaque arena with compiler-checked reset and
destruction lifetimes. `byte_arena_new()` creates an empty owner.
`byte_arena_copy(arena, source)` copies a `ref byte[]` and returns a shared
view whose lifetime is tied to the arena, independently of the source. The
source may therefore be a local array or temporary view. Empty copies and
embedded NUL bytes are supported; no UTF-8 invariant is imposed.

Copying into the arena requires exclusive access, even when no growth would
occur. A live returned view prevents another copy, `byte_arena_reset`,
`byte_arena_release`, owner movement, replacement or destruction. Reset
retains capacity and resets the used length; release also frees storage.
`byte_arena_length` reports the used byte count. The owner remains usable
after reset or release, and normal owner cleanup frees it automatically.

This API uses ordinary lifetime contracts and audited copying; it does not
trust manual borrow-registration counters in the legacy `lib.arena` API.
Typed arena allocation, attached budgets, nonmoving concurrent allocation,
and general raw/foreign-to-checked conversions remain separate work.

## Synchronous foreign byte I/O

`import lib.safe_foreign` exposes two audited entry points:

```w
int foreign_read(int descriptor, refmut byte[] destination)
int foreign_write(int descriptor, ref byte[] source)
```

Both calls borrow initialized storage for the duration of the synchronous OS
operation. `foreign_read` requires exclusive access; `foreign_write` permits
shared reads. The wrappers neither retain a pointer nor transfer ownership.
The descriptor remains the caller's responsibility. Results preserve the
underlying byte count, EOF and error behavior, including partial transfers;
callers must check the returned count. Empty slices return zero without
accessing their data pointer or calling the OS, even for an invalid descriptor.

Checked subslices preserve their bounds and backing lifetime across these
calls. Live shared views reject a write into their backing storage; live
exclusive views reject access through another path. After the last use of a
borrow, the owner can be used again. Element conversions require exactly the
same byte type, including when warnings are nonfatal and without `--safe`.
Quantified callback signatures preserve the same mutable/shared contract.

Trust binds to the resolved implementation and the pinned runtime closure.
A changed or shadowed `safe_foreign.w` fails the runtime audit; a user wrapper
with the same spelling receives no special privilege. General foreign
adoption, ownership transfer, assembly contracts and typed arenas retain their
separate acceptance gates in #698.

## Cleanup and unsafe boundaries

Every live owner is destroyed in reverse declaration order at its normal
scope exit. Function exits also destroy owned parameters. Return values are
evaluated and ownership transferred before other owners are destroyed.
Replacement assignment evaluates and transfers the new owner, destroys the
previous live allocation, and installs the replacement. Moving an owner clears
its stack slot; cleanup tests the slot before freeing it. This accounts for
branch-dependent transfers without reference counting or garbage collection.
There is no cleanup promise after process termination or a trap.

Checked `defer expression` registrations remain restricted to the outer
function block. `defer: expression` is an explicit checked, lexical registration:
it runs on departure from its enclosing block, including fall-through,
`return`, `break` and `continue`. A conditional block registers work only on the
path entering that block; a loop body runs its cleanup on each iteration.
Both forms accept one simple expression on the same source line and evaluate
it against exit-time bindings, including later declarations and shadowing.
They do not capture argument values at registration.

Deferred expressions run in reverse registration order before automatic owner
destruction. A return evaluates and transfers its result first; scoped defers
in exited inner blocks and outer function defers then execute in LIFO order.
A loop jump runs only scoped defers in the blocks it exits (`continue` crosses
an intervening switch); it does not run outer function defers. Deferred reads
extend borrow liveness, deferred moves cannot reuse transferred owners, and
returned references remain protected while deferred work runs.

The colon form selects checked analysis even without `--safe` and requires the
default retained emitter. It does not admit raw operations, unsafe-block
registration, `goto`, generators, multi-statement defer bodies or deferred
control transfer. Legacy unqualified function-scoped registration semantics
are unchanged. There is no guarantee of cleanup after a trap or process exit.

An explicit boundary permits raw operations:

```w
int main():
	unsafe:
		int value = 1
		int* raw = &value
		*raw = 2
	return 0
```

Unsafe code is responsible for valid pointers, aliasing, foreign-call contracts
and all raw memory operations it performs. It must not invalidate storage
used by checked code. An unsafe block cannot manipulate checked pointers,
call checked-pointer contracts, transfer control out of the block or defer
work. Raw interoperation therefore does not bypass the compiler's owner
transfer and cleanup rules. It also cannot establish that a previously
uninitialized checked binding is initialized.

The audited runtime exposes scalar `put_char`, `put_error` and `exit` calls,
the concrete storage APIs above, and compiler-generated allocation,
destruction and bounds operations. Import
`lib.safe` for checked `safe_print_int` and `safe_println_int` formatting.
Other runtime calls need an unsafe boundary. Source
hashes in `compiler/safe_runtime.w` bind these contracts to their resolved
implementations. A changed runtime or shadow import fails checking until its
contract is reviewed and its pin updated. Merely importing a library does not
grant permission to call arbitrary raw interfaces.

## Linux ARM64 runtime contract

Linux `arm64` accepts the same checked contracts as x86/x64 and win64.
Sized references remain one pointer word; checked slices retain their inline
pointer/length descriptor. Owner transfers clear source slots, and normal
exits use the same conditional recursive cleanup as the other targets.

The audited runtime pins the ARM64 architecture shims, Linux syscall and
stat implementations, AArch64 context layout and filesystem flags. The
syscall boundary uses Linux AArch64 argument/result registers and signed
error returns. Allocation uses the existing page-size discovery and guard
allocator; page size is not assumed to be 4 KiB. These pins do not expose
additional raw calls to checked application code. Modified or shadowed
runtime implementations fail the audit.

`safe_arm64_contract_test` checks and cross-compiles accepted/rejected
programs with and without `--safe`, validates ELF machine headers, and
checks unsupported targets and runtime-pin invalidation. The ordinary suite
also cross-compiles the cleanup/lifetime runtime corpus in three optimization
modes. `./wbuild tests_arm64` executes the accepted matrix and runtime corpus
through `wrun` under QEMU, including guard-allocator runs. Runtime execution
is a required target-admission gate. Android, Darwin, iOS and WebAssembly
checked applications remain rejected.

## Entry points, diagnostics and costs

`--bounds=off` and the streaming frontend are incompatible with checked
pointers, with or without `--safe`. Targets other than Linux x86/x64/arm64 and win64,
and in-process REPL/debugger
execution reject checked pointers. A requested `--safe` is also rejected by
in-process entry points. Compilation and structured checking run the same
analysis before an output file is published.

Ownership errors use diagnostic family `W0413`, with source spans and related
ownership/borrow locations. Safety errors do not depend on `--strict`.
Compiler sessions reset mode state; incremental option fingerprints include
`safe_mode`. Existing source closures and compiler-content hashes invalidate
build results when a contract, implementation or compiler changes.

Ownership graphs and borrow state are allocated only when checking is needed.
Application semantic retention also runs in ordinary retained compilation to
support flag-independent qualifier semantics. Runtime costs include
allocation, bounds checks and conditional destruction; moved slots are
cleared. Checked pointers add no reference counts or extra pointer words.
Functions with checked pointer parameters, results or locals are excluded
from the current inliner so optimization cannot erase a transfer or cleanup.

### Measured costs

Measurements on a Linux x86_64 development host compare fixed-point x86
compilers from main `0ccebf65` and this implementation, using the same current
input sources and default optimization. Compile figures are medians of 11
alternating runs after warmup; wall time includes process startup and output
writing, and peak RSS comes from `/usr/bin/time`.

| Ordinary compilation | Main time | This branch time | Main peak RSS | This branch peak RSS |
| --- | ---: | ---: | ---: | ---: |
| `tests/safe_cost_manual_fixture.w` | 38.56 ms | 38.29 ms | 4,416 KiB | 4,896 KiB |
| `w.w` | 871.39 ms | 1,078.03 ms | 77,216 KiB | 106,592 KiB |

The larger corpus shows a real default-compilation cost: about 24% more time
and 38% more peak memory. Retaining application bindings before discovering
later contracts is necessary for the current flag-independent implementation;
reducing that retention cost is future work. The small legacy fixture's
executable is byte-identical between the two compilers.

On this branch, compiling the manual fixture took 38.69 ms / 4,672 KiB;
compiling `tests/safe_cost_fixture.w` with `--safe` took 48.56 ms / 6,464 KiB.
These equivalent programs allocate, use and destroy one integer a million
times and verify the same accumulated result. Median runtime over 21
alternating runs was 28.88 ms manual / 28.87 ms checked on x86, and
31.33 ms / 31.82 ms on x64. These small differences are host-sensitive, not
a general performance guarantee. Both reported 264 KiB peak RSS at the
measurement tool's resolution. Checked cleanup adds 26 bytes to `.text` on
x86 and 32 on x64; alignment leaves total ELF sizes unchanged at 114,952 and
135,696 bytes respectively.

The committed fixtures make the corpus repeatable:

```sh
bin/wv3 --quiet w.w -o bin/safe_measure_compiler
bin/wv3 --quiet tests/safe_cost_manual_fixture.w -o bin/safe_cost_manual
bin/wv3 --quiet --safe tests/safe_cost_fixture.w -o bin/safe_cost
bin/safe_cost_manual
bin/safe_cost
```

Use a fixed-point compiler from main for the baseline, from this same source
directory. Add `x64` for the 64-bit runtime comparison. The ordinary
`./wbuild wbench_compare` gate also passes without changing its baseline.

The returned-reference extension was also compared against main `4b3d7fbd`
on the same current sources, using fixed-point x86 compilers. The following
are medians of seven alternating runs after warmup on a shared Linux host;
wall time includes startup and output, and RSS comes from `/usr/bin/time`.

| Existing corpus | Main time | Extended time | Main peak RSS | Extended peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Manual cost fixture | 37.26 ms | 40.01 ms | 4,992 KiB | 4,896 KiB |
| Checked cost fixture (`--safe`) | 47.50 ms | 50.24 ms | 6,784 KiB | 6,464 KiB |
| `w.w` | 1,080.19 ms | 1,079.44 ms | 106,704 KiB | 106,816 KiB |

Both existing cost fixtures produce byte-identical executables before and
after the extension on x86 (114,952 bytes) and x64 (135,696 bytes), and all
four binaries execute successfully. The benchmark regression gate also
passes. These measurements cover the existing corpus; broader returned-view
workloads still need measurement.

### Named lifetimes, aggregates and storage

The following measurement compares the fixed-point x86 `wv3` compiler from
`origin/main` at `e44be9c7` with the implementation at `b28642e4`. Both compiled
the same current source corpus with default optimization. After one warmup,
five alternating baseline/current runs supplied the medians below. Elapsed
time includes process-launch measurement overhead; `/usr/bin/time` supplied
peak RSS. No team builds or tests ran during this measurement window;
unrelated shared-host load remained possible.

| Corpus / emitted target | Baseline time | Current time | Baseline peak RSS | Current peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Manual cleanup / x86 | 64.23 ms | 81.37 ms | 5,120 KiB | 5,120 KiB |
| Manual cleanup / x64 | 73.61 ms | 75.18 ms | 5,120 KiB | 5,120 KiB |
| Checked cleanup / x86 | 108.36 ms | 96.57 ms | 6,912 KiB | 6,912 KiB |
| Checked cleanup / x64 | 123.21 ms | 120.91 ms | 6,912 KiB | 6,912 KiB |
| `w.w` / x86 | 2,117.76 ms | 2,198.00 ms | 107,712 KiB | 108,832 KiB |

On `w.w`, this sample is about 3.8% slower with 1.0% more peak memory.
Short-fixture timing remains noisy and does not establish a general overhead
bound. Both manual and checked fixtures produce byte-identical executables
across the two compilers on each architecture: 123,200 bytes on x86 and
144,000 bytes on x64. All eight binaries execute successfully. The plain
owner cleanup path preserves its previous instruction sequence; aggregate
destruction and growable storage incur their explicit allocation/drop costs.
These existing fixtures do not characterize every new aggregate or
collection workload.

## Validation

`safe_mode_test` exercises accepted and rejected programs on x86 and x64,
with and without the flag. `safe_runtime_test` uses the guard allocator to
observe leaks and duplicate destruction across transfer, replacement,
parameters, return, break, continue and fall-through cleanup.
`safe_cli_test` covers option order, structured conflicts and in-process
rejection. The parser-generator grammar includes the contextual qualifiers
and unsafe blocks. Self-host fixpoints, the full suite, cross-architecture
compiler checks and changed-line coverage remain the release gates.

Returned-reference regressions additionally cover shared and mutable views,
nested calls and reborrows, field and array-element views, recursion, aliases,
imports and forward declarations. Negative cases cover local/owner escapes,
ambiguous signatures, mutable upgrades, live-borrow mutation and moves,
branch and loop paths, conflicts during argument evaluation, pointer/slice
representation confusion with nonfatal warnings, and buffer-metadata
borrows that could escape or corrupt bounds. The guard
allocator also checks destruction after a returned mutable borrow ends.

The original implementation passed all 1,193 full-suite targets, both
self-host fixpoints, 43 architecture/root checks and the performance gate.
Coverage completed the same 1,193 targets and reached 835 of 862 changed
executable compiler lines (96%, above the 80% floor). Compiler line/branch
coverage reached 95.1% / 84.9%; coverage floors were raised to retain the gain.

The returned-reference extension adds 59 regression cases and passes all
1,205 full-suite targets, both self-host fixpoints, 46 architecture/root
checks and the benchmark gate. The instrumented suite also passes all
1,205 targets and reaches 46 of 46 changed executable compiler lines (100%).
Compiler line/branch coverage is 95.1% / 85.0%; the compiler branch floor
was raised from 84.2% to 84.3%. These are regression measurements, not a proof
of soundness or Rust-level language coverage.

The lifetime/aggregate/storage extension adds matrices for 84 named-lifetime
programs (including 24 deterministically generated interactions), 61 slice
programs, 65 borrowed-aggregate programs, 63 owning-aggregate programs and
69 collection programs. They run on x86 and x64 through compilation and
structured checking, with and without `--safe`; rejected cases must leave
no output artifact. Additional tests cover runtime source pins, erased or
mismatched declarations, large raw type graphs and allocation arithmetic.

The runtime fixtures include 100,000 repeated view/record copies, returned
and nested views, empty views, byte strings with embedded NULs, constructor
argument ordering, reverse field destruction and replacement/exit paths.
Twenty-six guard-allocator runs cover default, inline and register-disabled
configurations where applicable. Ten Memcheck runs cover the five runtime
fixtures on both architectures: zero errors, zero outstanding blocks, and
130 allocations matched by 130 frees. Slice descriptor stress performs no
heap allocations. The
[collection example](../../tests/safe_collection_runtime_fixture.w) combines
growable storage, returned views, borrowed slice fields, whole-owner moves
and recursive destruction in one program.

The pre-CI-fix implementation at `b28642e4` passed all 1,237 targets from
`./wbuild -j 6 tests verify_x64 wbench_compare`, including both self-host
fixpoints and the benchmark gate. Its instrumented full suite passed all
1,236 of its targets and reaches 636 of 653 changed executable compiler
lines (97%). Compiler line/branch coverage is 95.3% / 85.5%; code-generator
coverage is 97.0% / 88.5%. Coverage floors retain the measured gains.
Compiler checks pass for x86, x64, win64, arm64 and arm64_darwin, along with
six manifest-selected architecture/root checks. These checked compiler
portability; that release supported checked applications only on Linux
x86/x64. The follow-on implementation adds win64 as described above.
Independent review found an evaluation-order lifetime hole in
projected stores and indices; temporary backing-storage reservations and
15 positive/negative regression cases cover the fix. These results remain
regression evidence, not a proof of soundness or Rust-level maturity.

The separate required-AST CI suite exposed missing parsing for checked-pointer
casts and legacy slice-descriptor casts in the audited runtime. The AST parser
now handles these types transactionally, including lifetime-label storage.
Buffer and collection runtime tests explicitly compile with `--ast-required`
in the ordinary suite too. Parser regressions cover both compiler hosts and
target architectures, contextual qualifier names, nested aliases, lifetime
arena growth, and unsafe casts that must still reach the safe-mode checker.

### Follow-on extension validation

The combined optional-reference, control-flow, defer, method, generic,
mutable-record, owned-buffer, arena and win64 changes passed 1,288 targets
from `tests`, `verify_x64`, `wbench_compare` and the six explicit safe-mode
win64 runtime targets. This includes both self-host fixpoints and the
performance regression gate. All 48 manifest-selected architecture/root
checks passed, along with direct win64 and ARM64 compiler checks. Compiler
portability checks do not admit checked applications on unsupported targets.
The separate `tests_win64` suite also passed all 20 targets under Wine,
including its self-host fixpoint.

The isolated instrumented `tests` suite passed all 1,281 targets and every
compiler/API harness, with a COMPLETE receipt. Changed executable compiler
coverage from the follow-on baseline `666ccd52` was 477/497 lines (95%, above
the 80% gate); the complete branch diff against `origin/main` reached
521/541 lines (96%). Compiler line/branch
coverage reached 95.4% / 85.8%, code-generator coverage 97.1% / 88.7%, and
diagnostic-site coverage 51.5%. Coverage floors were raised to retain those
gains. The ordinary 1,288-target run additionally includes the performance
gate and six win64 runtime targets, accounting for the count difference.

The new source matrices exercise compilation and structured checking on
x86/x64 with and without `--safe`; accepted cases execute, and rejected cases
must leave no output artifact. The mutable-record matrix includes 43 cases,
the generic matrix 20 cases, and a separate 12-case generic interaction
matrix checks aliasing, argument order, recursive calls and optional results.
Required-AST and optimization variants cover the admitted paths.

Independent review found two interaction defects during implementation:
`break` could bypass checker scope invalidation, and a new loop iteration
could revive a stale reference by reinitializing its backing binding. Jump
paths now invalidate every exited lexical scope, and ending a backing
lifetime invalidates surviving borrowed values before that binding can be
reused. Permanent tests cover copied references, helper returns, nested
switches, range/while loops, mutable reborrows and valid cleared-reference
controls.

Eight rebuilt runtime fixtures ran on both Linux architectures through
`wgrind --native` with explicit leak reports and through Memcheck: 32 runs,
zero errors or outstanding blocks, and 1,894 allocations matched by 1,894
frees in the 16 Memcheck runs. Win64 guard-allocator tests run under Wine
with default, register-disabled/inlining-disabled and inline modes where
applicable. These results cover the documented bounded subset; issue #644
remains open for the remaining roadmap.

#### Follow-on measured costs

Fixed-point x86 compilers from baseline `666ccd52` and the implementation
at `aac4ceaf` were compared after one warmup using seven alternating measured
runs. No team builds or tests ran during the measurement window; unrelated
shared-host load was still possible. Times include process startup/output,
and peak RSS is from `/usr/bin/time`.

| Input / emitted target | Baseline time | Current time | Baseline peak RSS | Current peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Manual cleanup / x86 | 40.52 ms | 39.11 ms | 4,896 KiB | 5,120 KiB |
| Manual cleanup / x64 | 47.04 ms | 44.90 ms | 5,120 KiB | 4,896 KiB |
| Checked cleanup / x86 | 50.80 ms | 51.68 ms | 6,892 KiB | 6,688 KiB |
| Checked cleanup / x64 | 58.71 ms | 56.65 ms | 6,688 KiB | 6,688 KiB |
| `w.w` / x86 | 1,119.48 ms | 1,117.04 ms | 110,400 KiB | 110,624 KiB |

Manual cleanup and `w.w` use the same current source corpus. The checked
fixture source is unchanged, but each compiler uses its own checkout's
audited runtime: the baseline correctly rejects the updated guard allocator
because its implementation hash differs. Consequently the checked columns
are not a byte-equivalence comparison. Both manual executables are identical
across compilers, at 123,200 bytes on x86 and 144,000 on x64. Checked binaries
have those same file sizes, and all eight fixture executables run correctly.

The compiler input shows about 0.2% less elapsed time and 0.2% more peak
memory in this sample; this does not establish a general performance bound.
These existing cost fixtures measure compatibility and basic owner cleanup,
not the throughput of every new container or generic workload.

### Direct outlives contracts (Wave 1)

The first step of [#695](https://github.com/reardan/w/issues/695) adds 35
accepted/rejected cases to the lifetime matrix, checked and compiled on
x86/x64 with and without `--safe`. Accepted programs execute; rejected
programs leave no executable. Cases cover transitive constraints, cycles,
result-only labels, aliases, renamed/reordered/redundant forward contracts,
unused and later declarations, imports, recursion, optional/mutable results,
loop liveness and conflicting mutations or moves.

The ordinary suite, Linux x86/x64 self-host checks, Windows runtime fixture
and benchmark gate passed together: 1,330 targets. The inherited `NO_COLOR`
setting was removed for color-diagnostic tests; Windows execution used an
isolated Wine prefix because the host's shared prefix lacked a repository
drive mapping. All 48 manifest-selected architecture/root checks passed.

The instrumented full suite passed 1,328 targets and every compiler/API
harness, with a COMPLETE receipt. Tests reached 54/56 changed executable
compiler lines (96%); existing directory coverage floors passed unchanged.

The new aggregate/slice runtime fixture preserves owner replacement and
cleanup across 100 iterations. Native guard checks and Memcheck passed on
both Linux architectures with explicit leak reports; each Memcheck run
observed three allocations and three frees, zero outstanding blocks and
zero errors. The same fixture passed under Wine.

Seven alternating runs compared the pinned-seed-built baseline compiler at
`46b096f1` with the updated compiler, both compiling that baseline's `w.w`
from the same checkout. Median elapsed time was 1.62 s before and 1.63 s
after; median peak RSS was 111,504 KiB before and 111,584 KiB after. Emitted
binaries were byte-identical. These `/usr/bin/time` measurements include
startup/output and overlapped shared-host test activity; they establish
neither a speedup nor a general performance bound. Outlives clauses add
compiler metadata only, with no new runtime allocation or representation.

This step does not complete #695 or the broader #644 roadmap. Higher-ranked
contracts and richer aggregate ownership retain their separate implementation
gates. The following step extends these clauses through concrete generics.

### Generic outlives contracts (Wave 1)

Concrete specialization extends the direct contract rules through explicit,
inferred, imported, nested and recursive generic calls. Nineteen additional
accepted/rejected lifetime cases exercise these paths on x86/x64, checking and
compiling with and without `--safe`. A metadata regression checks independent
snapshots after raw-contract changes and retained-arena rollback/reuse.
The imported generic runtime fixture also preserves replacement and cleanup
under default, disabled and enabled optimization, including Windows execution.

Native guards and Memcheck pass on both Linux architectures. Each Memcheck
run observes three allocations and three frees, no outstanding blocks and
zero errors. This uses `wgrind` to expose W allocator operations to Memcheck.

Seven alternating compiles of baseline `d35422c7` produced byte-identical
binaries with the baseline and current compilers. Median elapsed time was
3.57 s before and 3.01 s after; median peak RSS was 111,584 KiB for both.
These runs overlapped other shared-host workloads, so the timing difference
is not evidence of a speedup. Raw and retained type descriptors each gain a
metadata pointer; constrained signatures additionally own their normalized
rows, and retained snapshots copy them. Constrained generic headers use the
retained-source reparse path. Application ABI, allocation and cleanup are
unchanged. Higher-ranked contracts and the remaining #695 deliverables are
still required.

### Quantified callable contracts (Wave 1)

The callable extension adds 47 accepted/rejected programs. The matrix checks
and compiles each with and without `--safe` on x86/x64, executes accepted
programs and verifies rejected programs leave no executable. It covers
independent nested scopes, alpha-equivalent aliases and forwards, imported
factories, outlives bounds, initialization, raw escapes, conflicting arguments,
owner transfers and checked slice/record calling conventions.

Ordinary validation passed 1,340 targets: the full suite, both Linux fixpoints,
the Windows runtime fixture and the CI compiler benchmark gate. All 48
manifest-selected architecture/root checks passed. The runtime fixture also
passes default, disabled and enabled optimization modes. Native heap guards
and Memcheck pass on x86/x64 with 153 allocations/frees, no outstanding blocks
and zero errors; the fixture also executes under Wine.

Seven alternating compiles of baseline `792fefbb` produced byte-identical
binaries with both compilers. Median elapsed time was 1.65 s before and 1.71 s
after; median peak RSS was 111,360 and 111,584 KiB. Shared-host timing is
diagnostic, not a general performance bound.

The additional program benchmark's self-compile rows exceed its older
`tests/bench/baseline.txt` limits on both baseline main and this change. Main's
x86/x64 self compiles measured 17,142,654/9,237,500 kIr and emitted
2,867,908/3,376,520 bytes; this change measured 17,766,652/9,591,969 kIr and
2,876,100/3,384,712 bytes. Thus this step adds about 3.6%/3.8% instructions and
0.3%/0.2% output size to that workload. Every application workload passed.
The separate CI compiler benchmark (`wbench_compare`) passed its committed
limits. The older program baseline remains unchanged; its existing self
regression still needs investigation in the performance workstream.

A raw callable signature and each retained snapshot store normalized relation
rows; retained binding metadata gains an entry-protocol flag. Function values
remain ordinary code pointers, with no closure environment, reference counting
or per-call allocation. Owners use the existing move/drop protocol, and
checked slices and records keep their inline ABI. Capturing environments and
the remaining aggregate work retain separate gates under #695/#696/#644.

Instrumented validation passed 1,338 targets and every compiler/API harness
with a COMPLETE receipt. Tests reached 172/176 changed executable compiler
lines (97%). Compiler branch coverage increased from 85.8% to 86.0%; its
floor rose from 85.1% to 85.3%, preserving the existing margin. Other
directory floors remain unchanged.


### Callable compatibility fast paths (#714)

Quantified-callable alias matching now follows the existing equal-type,
scalar, pointer-depth, GPU-domain and ordinary pointer-name fast paths.
Distinct checked callable aliases still reach contract-aware matching;
the retained safety pass still proves the exact normalized contract before
publishing code. This changes compiler work, not application semantics.

A fixed corpus at `89bf96d2` compares the original compiler with this change.
Both compilers emit byte-identical `w.w` binaries: 2,876,100 bytes on x86 and
3,384,712 on x64. Fresh paired Callgrind runs measured 17,753,467 versus
17,053,777 kIr on x86 and 9,588,565 versus 9,224,395 kIr on x64, reductions
of about 3.9% and 3.8%. Seven alternating native compiles measured median
elapsed time of 1.67 s versus 1.66 s and median peak RSS of 112,256 KiB for
both. Shared-host wall time does not establish a general speedup.

The checked/manual allocation corpus and callable owner/slice/record fixture
also emit byte-identical binaries for both Linux architectures under default,
`--no-regs --no-inline`, and `--inline` modes: 18 before/after comparisons.
Every binary executes successfully. Five alternating default-mode runs give
these median times; identical machine code makes the small differences noise,
not an application optimization claim:

| Fixture | x86 before/after (ms) | x64 before/after (ms) |
| --- | --- | --- |
| Checked allocation | 33.23 / 32.34 | 32.94 / 31.30 |
| Manual allocation | 32.30 / 32.47 | 31.80 / 31.30 |
| Callable runtime | 0.23 / 0.26 | 0.18 / 0.17 |

This is one bounded step under #714/#700. Retention costs, the accumulated
self-compile baseline gap and broader ownership-preserving optimization
remain required. No benchmark baseline is refreshed by this change.

The full suite, both Linux fixpoints, Windows runtime and CI compiler benchmark
passed together: 1,340 targets. All 48 architecture/root checks and the
existing 47-case callable matrix pass. Native guards and Memcheck pass on
x86/x64 with 153 allocations/frees and zero leaks/errors. Focused compiler
instrumentation runs both callable matrices and reaches the single changed
executable line (1/1, 100%); full aggregate coverage remains a CI gate.

### Nested borrowed records (Wave 1)

Twenty-seven accepted/rejected programs exercise nested construction, aliases,
imports, renamed forward contracts, returned records, checked callbacks,
shared/mutable projections, sibling origins, branch-selected returns, local
escapes, descriptor addresses and shape bounds. Every case is checked and
compiled on x86/x64 with and without `--safe`; accepted programs execute and
rejections leave no executable.

The full suite, both Linux fixpoints, Windows runtime and CI compiler benchmark
passed together: 1,343 targets. All 48 manifest-selected architecture/root
checks passed. The runtime fixture covers nested records and slices across
returned temporaries, callback copying, stack clobbers, owner replacement and
mutable loop reborrows. It passes the Linux optimization variants and Wine.
Native guards and Memcheck pass on both Linux architectures with 102
allocations/frees, no outstanding blocks and zero errors.

Seven alternating compiles of the callable baseline `89bf96d2` produced
byte-identical compiler output. Median elapsed time was 1.66 s for both
compilers; median peak RSS was 112,032 KiB before and 112,256 KiB after.
The existing checked callable runtime fixture also produced byte-identical
x86/x64 executables, and both versions execute successfully. These shared-host
measurements do not establish a general performance bound. Nested validation
uses bounded compile-time recursion; application layout, allocation and
cleanup are unchanged.

This step implements nested single-group support. Multiple independent groups,
mixed ownership, replacement and partial moves remain required under #695;
this step does not close #695 or #644.

Instrumented validation passed all 1,341 targets and every compiler/API harness
with a COMPLETE receipt. Tests reached all 24/24 changed executable compiler
lines (100%). The measured directory percentages and existing floors remain
unchanged from the callable baseline.

### Independent borrowed-record groups (Wave 1)

Forty accepted/rejected programs exercise positional groups, disjoint mutable
fields, shared extraction through mutable wrappers, named-result selection,
wrong-group returns, nested/repeated mappings, aliases, forwards, quantified
callbacks, optional results, branch joins, loops and expanded-slot bounds.
Each is checked and compiled with and without `--safe` on x86/x64; accepted
programs run and rejected programs leave no executable. A compiler API test
mutates the last expanded relation row, rolls back and reuses the retained
arena, and verifies that raw labels/rows and prior snapshots stay independent.

Validation passed 1,346 ordinary targets (full suite, both Linux fixpoints,
Windows runtime and compiler benchmark), all 48 architecture/root checks, and
1,344 instrumented targets plus all six compiler/API harnesses. The receipt is
COMPLETE; 320/321 changed executable compiler lines are reached (99%). Compiler
line/branch coverage rises to 95.5/86.1%, with floors raised to 94.7/85.4%.

The runtime fixture covers imported factories, multi-group callback copies,
owned allocation replacement and nested disjoint mutable access across Linux
optimization modes and Wine. Native guards and Memcheck on both Linux targets
report 103 allocations/frees, zero outstanding blocks and zero errors.

Seven alternating compiles of the same `c74f3152` corpus produce byte-identical
compiler output. Median time is 1.67/1.70 s and median peak RSS is
112,224/112,400 KiB before/after; shared-host timing is not a general bound.
Existing callable runtime fixture binaries are also byte-identical on x86/x64
and execute successfully. Lifetime-group metadata is compile-time only.
Mixed owned/borrowed fields, replacement and partial moves remain required
under #695/#644; this step closes neither issue.

### Owners carrying shared borrowed groups (Wave 1)

Forty-two accepted/rejected cases exercise explicit owner lifetime groups,
construction, aliases, forwards, direct/generic/quantified calls, nested owned
children, shared borrowed records, replacement joins, scope exit, deferred return
reservations and escape rejection. The matrix checks and compiles each program
with and without `--safe` on x86/x64, runs accepted programs, and requires no
artifact after rejection. Fresh multi-label generic arguments force speculative
type storage to grow. A metadata test verifies independent owning labels after
retained rollback and arena reuse.

Validation passed 1,349 ordinary targets (full suite, both Linux fixpoints,
Windows runtime and compiler benchmark), all 48 architecture/root checks,
pinned-seed bootstrap and parser generation. Instrumented validation passed
1,347 targets and all six compiler/API harnesses, with a COMPLETE receipt.
Changed compiler-line coverage is 242/246 (98%). Compiler line coverage reaches
95.6%; its floor rises to 94.8%. Existing branch floors remain unchanged.

The runtime fixture covers imported factories, owner and slice callbacks,
nested extraction, whole replacement and return/break/continue cleanup. It
passes Linux optimization variants and Wine. Native guards and Memcheck on
x86/x64 report 337 allocations/frees, no outstanding blocks and zero errors.

Seven alternating compiles of the fixed `8abe5b62` corpus measure 1.69/1.68 s
median and 113,152/113,376 KiB median peak RSS for baseline/new compilers. Compiler
output is byte-identical, as are the prior callable runtime fixtures on x86/x64;
all fixture binaries execute. These shared-host timings do not establish a
general performance bound. No runtime layout or allocation changes are needed
for external lifetime metadata.

This step covers shared fields. Exclusive fields, whole-owner views, field
replacement and partial moves retain their separate required gates under #695;
#695 and #644 remain open.

### Shared mixed-owner views (Wave 1)

Twenty-three additional accepted/rejected cases validate nonconsuming mixed-owner
views, direct/generic/quantified calls, nested owned children, multi-group inline
records, loop liveness and descriptor/data escape rejection on x86/x64 with and
without `--safe`. Moving or replacing a viewed owner, mutating retained backing
data, or upgrading shared access is rejected without producing an executable.

Validation passed 1,352 ordinary targets (full suite, both Linux fixpoints,
Windows runtime and compiler benchmark), all 48 architecture/root checks,
pinned-seed bootstrap and parser generation. Instrumented validation passed
1,350 targets and all six compiler/API harnesses with a COMPLETE receipt.
Changed compiler-line coverage is 29/29 (100%). Directory coverage and floors
remain unchanged, including the inherited 94.8% compiler line floor.

The runtime fixture checks imported shared helpers, callbacks, once-only
receiver evaluation, nested extraction and replacement after views expire. Linux
optimization variants and Wine pass. Native guards and Memcheck on x86/x64
report 406 allocations/frees, zero errors and no outstanding blocks.

Seven alternating compiles of the fixed `c5d27a6f` source corpus measure 1.68 s
median and 113,824 KiB median peak RSS for both compilers. Compiler output and
prior callable/mixed-owner runtime fixtures are byte-identical on x86/x64;
all fixture binaries execute. These shared-host measurements do not establish
a general performance bound. Shared views add no runtime allocation or layout.

### Exclusive mixed-owner fields (Wave 1)

Thirty-four accepted/rejected programs exercise per-group shared/exclusive
access, nested owned children, mutable return contracts, callbacks, deferred
work, moves, replacement, scope exits and reborrow-cycle rejection. Every case
is checked and compiled on x86/x64 with and without `--safe`; accepted programs
execute and rejected programs leave no executable. A type-table API regression
reuses retained type IDs with changed field access kinds and verifies cache reset.

The full suite, both Linux fixpoints, Windows runtime and compiler benchmark
pass 1,355 targets. All 48 architecture/root checks pass. Instrumented validation
passes 1,353 targets and all six compiler/API harnesses with a COMPLETE receipt;
85/86 changed executable compiler lines are reached (98%). Compiler coverage is
95.6/86.0% line/branch, preserving the existing 94.8/85.4% floors.

Linux optimization variants and Wine pass. Native guards and Memcheck on both
Linux architectures report 232 allocations/frees, no outstanding blocks and
zero errors. Seven alternating compiles of the fixed shared-view baseline
sources produce byte-identical compiler output, with median time 1.94 s and
peak RSS 113,824 KiB for both compilers. Previous callable and mixed-owner runtime
fixtures are byte-identical on x86/x64 and execute successfully. Shared-host
measurements do not establish a general performance bound.

Field replacement, disjoint child borrowing and partial moves retain separate
required gates under #695/#644; this step closes neither issue.

### Direct owned-field replacement (Wave 1)

Thirty-one accepted/rejected programs exercise direct replacement, named owner
requirements, child borrows, callbacks, generics, mixed-child group mapping,
loops, local escapes, containing-owner self-reference and reborrow cycles.
Every case is checked and compiled on x86/x64 with and without `--safe`;
accepted programs execute and rejected programs leave no executable.

The full suite, both Linux fixpoints, Windows runtime and compiler benchmark
pass 1,358 targets. All 48 architecture/root checks pass. Instrumented validation
passes 1,356 targets plus all six compiler/API harnesses with a COMPLETE receipt;
85/86 changed executable compiler lines are reached (98%). Existing compiler
and code-generator line/branch floors remain satisfied, with unchanged rounded
directory percentages from the exclusive-owner baseline.

The imported runtime fixture covers repeated recursive and opaque-buffer drops,
once-only factories, callback results, source-owner transfers, shared/exclusive
mixed children, return, break and continue. Linux optimization variants and
Wine pass. Native guards and Memcheck on both Linux architectures report 537
allocations/frees, no outstanding blocks and zero errors.

Seven alternating compiles of the fixed `69d5ed0a` compiler sources produce
byte-identical output. Median elapsed time is 1.72/1.68 s and peak RSS is
113,728/114,048 KiB before/after. Previous callable and mixed-owner runtime
fixtures are byte-identical on x86/x64 and execute successfully. Shared-host
measurements do not establish a general performance bound. Borrowed-field
replacement, disjoint borrowing and partial moves retain separate required
gates; this step closes neither #695 nor #644.

### Borrowed-field replacement through unique owners (Wave 1)

Thirty-three accepted/rejected programs cover shared/exclusive pointers, slices,
inline borrowed records, independent and repeated groups, aliases, generic and
indirect calls, branches, loops, deferred returns, local escapes, parent moves,
sibling obligations and reborrow cycles. Each case is checked and compiled on
x86/x64 with and without `--safe`; accepted programs execute and rejected ones
leave no executable. Older mixed-owner and borrowed-wrapper tests assert the
new acceptance boundary and retained unique-owner requirement.

Validation passes 1,361 ordinary targets (full suite, both Linux fixpoints,
Windows runtime and compiler benchmark), all 48 architecture/root checks, and
1,359 instrumented targets plus all six compiler/API harnesses. The coverage
receipt is COMPLETE; 10/11 changed executable compiler lines are reached (90%).
Compiler coverage remains 95.6/86.0% line/branch and existing floors pass.

Linux optimization variants and Wine pass. Native guards and Memcheck on both
Linux architectures report six allocations/frees, no outstanding blocks and
zero errors. Seven alternating compiles of fixed `2d1e82d3` sources produce
byte-identical compiler output; previous callable and mixed-owner runtime
fixtures are also byte-identical and execute on x86/x64. Median time is
2.18/1.87 s and peak RSS is 113,824/114,048 KiB before/after. These shared-host
measurements are not a general performance bound. Disjoint borrowing and partial
moves retain separate required gates; this step closes neither #695 nor #644.

### Disjoint owned-child paths (Wave 1)

Twenty-six accepted/rejected cases cover sibling child borrows and replacement,
ancestor conflicts, shared and exclusive views, callbacks, loops, cleanup,
opaque collection siblings and conservative fallback. Every case is checked
and compiled on x86/x64 with and without `--safe`; accepted programs execute
and rejected programs leave no executable.

Validation passes 1,364 ordinary targets, both Linux fixpoints, Wine and the
compiler benchmark, all 48 architecture/root checks, and 1,362 instrumented
targets plus six compiler/API harnesses. The coverage receipt is COMPLETE;
76/76 changed executable compiler lines are reached (100%). Compiler branch
coverage rises to 86.1%; its floor rises from 85.4% to 85.5% to preserve the gain.

Linux optimization variants and Wine pass. Native guards and Memcheck report
119 allocations/frees with zero errors or outstanding blocks on both Linux
architectures. Seven alternating compiles of fixed `4dcda820` sources produce
byte-identical compiler output; prior callable and mixed-owner fixtures are
byte-identical and execute on x86/x64. Median time is 3.79/3.56 s and peak RSS
114,048/113,888 KiB before/after on the shared host. These measurements do not
establish a general performance bound. Partial moves and scalar field paths
retain separate gates; neither #695 nor #644 closes.

### Direct owned-child partial moves (Wave 1)

Forty-three accepted/rejected programs cover direct child extraction, missing
children, branches, loops, callbacks, generic calls, replacement, parent borrows
and moves, mixed-group provenance and cleanup exits. Every case is checked and
compiled on x86/x64 with and without `--safe`; accepted programs execute and
rejections leave no executable. The emitted move clears its source slot before
cleanup can observe it; initialized siblings retain their separate state.

Validation passes 1,367 ordinary targets, both Linux fixpoints, Windows runtime
and compiler benchmark, all 48 architecture/root checks, and 1,365 instrumented
targets plus six compiler/API harnesses. The coverage receipt is COMPLETE;
61/62 changed executable compiler lines are reached (98%). Rounded directory
coverage is unchanged from the disjoint-field prerequisite and retains its
raised compiler branch floor.

Linux optimization variants and Wine pass. Native guards and Memcheck report
21 allocations/frees with zero errors or outstanding blocks on both Linux
architectures. Seven alternating compiles of fixed `37477e19` sources produce
byte-identical compiler output; prior callable and mixed-owner fixtures are
byte-identical and execute on x86/x64. Median time is 3.26/3.19 s and peak RSS
113,888/113,984 KiB before/after on the shared host. These measurements do not
establish a general performance bound. Scalar disjointness and nested moves
retain separate gates; neither #695 nor #644 closes.

### Disjoint scalar fields and plain construction (Wave 1)

Twenty-seven accepted/rejected programs plus an explicit nonfatal-warning
nominal-type rejection cover scalar and inline-record siblings, arrays,
ancestors, mutable borrows, callbacks, loops and complete pointer-free record
construction. Every matrix case is checked and compiled on x86/x64 with and
without `--safe`; accepted programs execute and rejections leave no executable.

Validation passes 1,370 ordinary targets, both Linux fixpoints, Windows runtime
and compiler benchmark, all 48 architecture/root checks, and 1,368 instrumented
targets plus six compiler/API harnesses. The coverage receipt is COMPLETE;
29/30 changed executable compiler lines are reached (96%). Compiler branch
coverage rises to 86.2%; the floor rises to 85.6%, preserving the prior margin.

Linux optimization variants and Wine pass. Native guards and Memcheck report
six allocations/frees with zero errors or outstanding blocks on both Linux
architectures. Seven alternating compiles of fixed `ada3ddb9` sources produce
byte-identical compiler output; prior callable and mixed-owner fixtures are
byte-identical and execute on x86/x64. Median time is 1.73/1.72 s and peak RSS
114,208 KiB for both compilers on the shared host. These measurements do not
establish a general performance bound. Nested moves and replacement retain
separate gates; neither #695 nor #644 closes.

### Nested owned-child partial moves (Wave 1)

Twenty-three accepted/rejected programs cover stable nested extraction,
initialized siblings, whole-child and parent borrows, callbacks, generics,
external groups, branches, loops and cleanup exits. Each case is checked and
compiled on x86/x64 with and without `--safe`; accepted programs execute and
rejections leave no executable. Whole-child borrowing verifies all descendants,
so a missing grandchild cannot be hidden behind a borrowed child pointer.

Validation passes 1,373 ordinary targets, both Linux fixpoints, Windows runtime
and compiler benchmark, all 48 architecture/root checks, and 1,371 instrumented
targets plus six compiler/API harnesses. The coverage receipt is COMPLETE;
21/23 changed executable compiler lines are reached (91%). Existing coverage
floors pass, including the preceding 85.6% compiler branch floor.

Linux optimization variants and Wine pass. Native guards and Memcheck report
332 allocations/frees with zero errors or outstanding blocks on both Linux
architectures. Seven alternating compiles of fixed `9200791f` sources produce
byte-identical compiler output; prior callable and mixed-owner fixtures are
byte-identical and execute on x86/x64. Median time is 2.90/2.96 s and peak RSS
114,208 KiB for both compilers on the shared host. These measurements do not
establish a general performance bound. Nested replacement and broader views
retain separate gates; neither #695 nor #644 closes.

### Nested checked-field replacement (Wave 1)

Thirty-one accepted/rejected programs cover nested owned and borrowed fields,
restored grandchildren, sibling borrows and moves, receiver invalidation,
reordered lifetime labels, ancestor sibling obligations, local escapes,
return contracts, loops and defer. Every case is checked and compiled on
x86/x64 with and without `--safe`; accepted programs execute and rejections
leave no executable.

Validation passes 1,376 ordinary targets, both Linux fixpoints, Windows runtime
and compiler benchmark, all 48 architecture/root checks, and 1,374 instrumented
targets plus six compiler/API harnesses. The coverage receipt is COMPLETE;
56/59 changed executable compiler lines are reached (94%). Existing directory
line/branch floors pass.

Linux optimization variants and Wine pass. Native guards and Memcheck report
242 allocations/frees with zero errors or outstanding blocks on both Linux
architectures. Seven alternating compiles of fixed `de24c72e` sources produce
byte-identical compiler output; prior callable and mixed-owner fixtures are
byte-identical and execute on x86/x64. Median time is 1.70/1.71 s and peak RSS
114,208/114,432 KiB before/after on the shared host. These measurements do not
establish a general performance bound. Broader mixed-owner views and optional
fields retain separate gates; neither #695 nor #644 closes.

### Mutable mixed-owner views (Wave 1)

Thirty-one accepted/rejected programs cover mutable whole-owner views, shared
and exclusive fields, nested child projections, alias conflicts, escaped
allocations, generic and quantified calls, returned references, loops and defer.
Every case is checked and compiled on x86/x64 with and without `--safe`;
accepted programs execute and rejected programs leave no executable. A nested
shared-projection regression ensures provenance lookup preserves shared access
instead of reacquiring an exclusive receiver borrow.

Validation passes 1,379 ordinary targets, both Linux fixpoints, Windows runtime
and compiler benchmark, all 48 architecture/root checks, and 1,377 instrumented
targets plus six compiler/API harnesses. The coverage receipt is COMPLETE;
15/15 changed executable compiler lines are reached (100%). Existing directory
line/branch floors pass.

Linux optimization variants and Wine pass. Native guards and Memcheck report
nine allocations/frees with zero errors or outstanding blocks on both Linux
architectures. Seven alternating compiles of fixed `3dc9c312` sources produce
byte-identical compiler output; prior callable and mixed-owner fixtures are
byte-identical and execute on x86/x64. Median time is 2.11/1.71 s and peak RSS
114,656/114,432 KiB before/after on the shared host. These measurements do not
establish a general performance bound. Optional whole-owner views and nullable
fields retain separate gates; neither #695 nor #644 closes.


### Optional mixed-owner view validation

Validation: 27 accepted/rejected cases on x86/x64, check/compile with and without `--safe`, accepted execution and rejected-artifact suppression. The ordinary suite, both Linux fixpoints, Wine and benchmark passed 1,382 targets; all 48 architecture/root checks passed. Instrumented validation passed 1,380 targets and all six API harnesses with a COMPLETE receipt; changed compiler coverage is 2/2 lines (100%), and existing floors pass. Linux optimization variants and Wine passed. Native guards/Memcheck reported six allocations/frees and zero errors/leaks per Linux architecture. Seven alternating compiles of the fixed `80828260` source corpus measured 1.72/1.72 s and 114,432 KiB peak RSS before/after. Compiler output and prior checked runtime fixture binaries were byte-identical. The implementation rebased unchanged onto the prerequisite validation commit.


### Optional reference-field validation

Validation: 32 accepted/rejected cases on x86/x64 with and without `--safe`, check/compile parity, accepted execution and rejected-artifact suppression. The full suite, both Linux fixpoints, Wine and benchmark passed 1,385 targets; all 48 architecture/root checks passed. Instrumented validation passed 1,383 targets and all six API harnesses with a COMPLETE receipt, reaching 2/2 changed compiler lines (100%). Compiler line/branch coverage remains 95.6/86.2%, preserving existing floors. Linux optimization variants and Wine passed. Native guards/Memcheck reported 12 allocations/frees and zero errors/leaks per Linux target. Seven alternating compiles of fixed `9f4bead3` measured 1.70/1.70 s and 114,432 KiB median peak RSS before/after; compiler and prior checked fixture binaries were byte-identical. The implementation rebased unchanged onto the optional-view validation commit.


### Optional unique-owner validation

Optional unique owners use pointer-sized zero for absence. `optown T*` supports presence-checked access, transfer into required owners, complete optional owned-field construction and recursive cleanup. Move state remains separate from presence, including for known-zero transfers. Mixed optional owners retain every external lifetime group; known-absent transfers do not retain former loans. Nullable inline records and slices remain outside this pointer representation contract.

Speculative optional-owner type names now preserve their qualifier and lifetime labels through commit. A type-table regression compares generic argument identities before and after commit, preventing optional owners from colliding with required owners.

Validation: 52 accepted/rejected cases on x86/x64 with and without `--safe`, check/compile parity, accepted execution and rejected-artifact suppression. Final full ordinary validation passed 1,410 targets, both Linux fixpoints, Wine and the benchmark gate. Architecture validation passed all 48 root/target checks. Selected integration passed 19 targets, including three ARM64 runtime cross-compiles. The final instrumented run passed 1,408 targets and six API harnesses with a COMPLETE receipt, reaching 24/24 changed compiler lines (100%). Compiler line/branch coverage is 95.6/86.2%; the branch floor rises to 85.7%.

An earlier instrumented run failed the existing VM socket-close cancellation test (guest exit status 1). Its isolated rerun and subsequent complete instrumented runs passed; the final complete run supplies the coverage evidence.

Linux optimization variants and Wine pass. Native guards/Memcheck report 113 allocations/frees and zero errors/leaks per Linux target. Seven alternating compiles of fixed `ac74928d` sources measured 1.65/1.64 s and 114,464/114,688 KiB median peak RSS before/after. Compiler and prior callable/mixed-owner fixture binaries are byte-identical. These measurements describe that corpus on the shared host, not a general performance guarantee.

This implements the optional-owner representation step under #695/#644. The issues remain open until their required PRs merge. No listed capability is deferred.


### Checked lexical defer validation

Checked `defer: expression` registers one lexical deferred expression. Conditional and nested registrations run in LIFO order on the exits that leave their scope, including break, continue and return. Return values are evaluated and transferred before deferred expressions, then automatic owner cleanup runs. Deferred expressions use exit-time bindings, and their reads/moves participate in liveness checks. Legacy `defer expression` retains its existing behavior. The new form requires the retained emitter and selects checked semantics without `--safe`.

The 36-case contract matrix covers nested/conditional scopes, loops, switch exits, returned values, owner cleanup, conflicting loans/moves, generic deferred calls, later declarations and shadowing. Compile/check outcomes agree on x86/x64 with and without `--safe`, and rejected programs leave no executable. The parser-generator grammar includes the lexical form.

Validation passed 1,413 ordinary targets including both Linux fixpoints, Wine runtime and benchmark, all 48 architecture/root checks, and 1,411 instrumented targets plus six compiler/API harnesses. The coverage receipt is COMPLETE; tests reach 74/76 changed executable compiler lines (97%). Compiler line/branch coverage is 95.7/86.3%; their floors rise to 94.9/85.8%.

Linux optimization variants and Wine execute the runtime fixture; three ARM64 variants cross-compile and have required guard-allocator execution gates in CI. Native guards and Memcheck report 17 allocations/frees and zero errors/leaks on both Linux architectures. Seven alternating compiles of fixed `b4588eb0` sources measure 1.65/1.65 seconds and 114,688/115,136 KiB median peak RSS before/after. Compiler output and prior callable/mixed-owner fixture bytes are identical. The measurements describe this corpus on the shared host, not a general performance guarantee.

Depends on #780. Part of #696 under #644; those issues remain open for broader generic and capturing-callback work. No listed capability is deferred.


### Explicit generic borrowed-shape validation

Explicit specialization preserves borrowed-record and checked-slice layouts,
qualifiers and lifetime groups. Speculative derived records live in the
expression arena until commit; metadata survives arena growth and is rebuilt
with independent ownership when committed. Pointer alias requalification keeps
its existing behavior, including `sizeof(ref Alias)` when Alias is already a
checked pointer alias.

Validation passed 33 contract cases on x86/x64 with and without `--safe`,
transactional metadata growth/commit/rollback API regressions, all 48
architecture/root checks and 1,416 ordinary targets including both Linux
fixpoints, Wine runtime and benchmark. The instrumented run passed 1,414
targets plus six API harnesses with a COMPLETE receipt; 168/171 changed
executable lines were reached (98%). Grammar branch coverage rises from
85.2% to 85.3%, retained by raising its floor to 84.7%. No floor is lowered.

Linux optimization variants and Wine execute the runtime fixture; three ARM64
variants cross-compile and have guard-allocator execution gates in CI. Native
guards and Memcheck report 30 allocations/frees and zero errors/leaks on both
Linux architectures. Seven alternating compiles of fixed `1aac2c8e` sources
measure 1.68/1.68 seconds and 114,880/114,912 KiB median peak RSS before/after.
Compiler output and prior callable/mixed-owner fixture bytes are identical.
These measurements describe that corpus on the shared host.

Depends on #782. This completes the explicit borrowed-shape step of #696;
inferred results, qualified inference, generic methods and capturing callback
storage have separate implementation and merge gates. #696/#644 remain open.


### Inferred aggregate result validation

Inferred generic calls reserve aggregate result storage before evaluating their
arguments, copy expanded arguments without overwriting an enclosing call's
state, and return the caller-owned descriptor or record. Completed signatures
are shared across nested explicit/inferred calls regardless of tree order.
Checked qualifiers, lifetime groups and owner transfers remain intact.

Validation passed 27 contract cases on x86/x64, both compile/check modes with
and without `--safe`, all 48 architecture/root checks and 1,419 ordinary targets
including both Linux fixpoints, Wine and benchmark. Retained AST modes 2/3/4
also check, compile and execute ignored and nested aggregate results with both
compiler host widths; the streaming emitter still explicitly rejects them.
The instrumented run passed 1,417 targets plus six API harnesses with a COMPLETE
receipt. Tests reach 9/9 changed executable lines (100%); existing coverage
floors pass without changes.

Linux optimization variants and Wine pass. Three ARM64 variants cross-compile
and have guard-allocator execution gates in CI. Native guards and Memcheck
report 30 allocations/frees with zero errors/leaks on both Linux widths. Seven
alternating compiles of fixed `a407a1f4` sources measure 1.68/1.68 seconds and
116,256 KiB median peak RSS for both compilers; compiler and prior callable/
mixed-owner fixture output is byte-identical. These measurements describe
that corpus on the shared host.

Depends on #783. Part of #696/#644; qualified inference, generic methods,
capturing callback storage and later work remain separately gated.


### Qualified generic inference validation

Generic parameters under `ref T`, `refmut T` and checked-slice wrappers infer
the underlying record or element type. Whole `T` inference retains the full
qualifier. The resolved concrete signature then checks access and lifetime
effects; array arguments lower to inline descriptors using the inferred
parameter representation.

Validation passed 35 contract cases on x86/x64 with and without `--safe`,
all 48 architecture/root checks and 1,422 ordinary targets including both
Linux fixpoints, Wine runtime and benchmark. Instrumented validation passed
1,420 targets plus six API harnesses with a COMPLETE receipt, reaching 24/25
changed executable lines (96%). Existing coverage floors pass unchanged.
Native guards and Memcheck report 30 allocations/frees and no errors/leaks
per Linux architecture. Optimization variants and Wine execute, with three
ARM64 variants cross-compiled and runtime-gated in CI.

Seven alternating compiles of the fixed #784 parent corpus measured
1.68/1.69 seconds and 116,256/115,944 KiB median peak RSS before/after.
Compiler and prior checked fixture output bytes are identical. Measurements
are specific to that corpus on the shared host. The implementation rebased
unchanged onto the prerequisite validation commit. #696/#644 remain open
for subsequent generic-method, callback-storage and remaining gates.


### Checked generic method validation

Explicit and inferred generic methods pass the checked receiver before explicit
arguments. Borrowed nominal wrappers resolve against their underlying record;
completed signatures enforce the same lifetime and ownership contracts as free
calls. Resolution preserves existing ordinary-method and UFCS precedence.

Validation passed 78 contract cases on both Linux widths with and without
`--safe`, all 48 architecture/root checks and 1,425 ordinary targets including
both fixpoints, Wine runtime and benchmark. Instrumented validation passed
1,423 targets plus six API harnesses with a COMPLETE receipt and reached all
66 changed executable lines. Existing coverage floors pass unchanged. Native
guards and Memcheck report 30 allocations/frees and zero errors/leaks on each
Linux width. Optimization variants and Wine execute; three ARM64 variants
cross-compile with runtime gates in CI.

Seven alternating compiles of the fixed #786 parent corpus measured
1.68/1.69 seconds and 116,160/116,032 KiB median peak RSS before/after.
Compiler and prior checked fixture output bytes are identical. Measurements
are specific to that corpus on the shared host. The implementation rebased
unchanged onto the prerequisite validation commit. #696/#644 remain open
for capturing callback storage and subsequent gates.


### Captured callback storage validation

An owned record can store quantified callable fields beside its owned or
borrowed environment. Code and environment retain distinct field identities;
projection, replacement, partial environment moves and invocation preserve
the callable signature and captured lifetimes. Complete construction and
recursive owner cleanup govern escaping owned captures. Borrowed captures
cannot outlive their backing roots. This representation uses explicit records
and callable fields; it does not introduce closure-expression syntax.

Validation passed 33 contract cases on x86/x64 with and without `--safe`, all
48 architecture/root checks and 1,428 ordinary targets including both Linux
fixpoints, Wine runtime and benchmark. Instrumented validation passed 1,426
targets plus six API harnesses with a COMPLETE receipt and reached all six
changed executable lines. Existing coverage floors pass unchanged. Linux
guard allocation and Memcheck report 360 allocations/frees and zero errors
or leaks on each width. Optimization variants and Wine execute; ARM64
variants cross-compile with runtime execution gates in CI.

Seven alternating compiles of the fixed #787 parent corpus measured
1.70/1.69 seconds and 116,032/116,256 KiB median peak RSS before/after.
Compiler and prior checked fixture bytes are identical. Measurements are
specific to that corpus on the shared host. The implementation rebased
unchanged onto the prerequisite validation commit. #696/#644 remain open
until the dependent merges and integrated completion gates pass.


### Generic allocation validation

`new T` resolves the active template substitution before ordinary type lookup
in both compiler paths. The resulting concrete allocation retains sized-value,
initialization and checked-owner requirements. This does not admit construction
of opaque runtime metadata or add a `new Generic[T]` application form.

Validation passed 20 contract cases on both Linux widths with and without
`--safe`, all 48 architecture/root checks and 1,431 ordinary targets including
both fixpoints, Wine runtime and benchmark. Instrumented validation passed
1,429 targets plus six API harnesses with a COMPLETE receipt and reached all
four changed executable lines. Existing floors pass unchanged. Linux guard
allocation and Memcheck report 180 allocations/frees and zero errors/leaks
per width. Optimization variants and Wine execute, with ARM64 runtime gates
in CI.

Seven alternating compiles of the fixed #788 parent corpus measured
1.68/1.68 seconds and 116,480/116,160 KiB median peak RSS before/after.
Compiler and prior checked fixture bytes are identical. Measurements describe
that corpus on the shared host. The implementation rebased unchanged onto
the prerequisite validation commit; #696/#644 retain their completion gates.


### Checked mutable-slice validation

`refmut T[]` retains exclusive access and its backing lifetime through local
bindings, subranges, generic calls, methods and quantified callbacks. Shared
reborrowing uses `ref T[]`; shared input cannot become mutable. The inline
pointer/length representation stays distinct from legacy slices. Incompatible
element or descriptor conversions are fatal even when warnings are nonfatal.

Validation passed 44 accepted/rejected contract cases on x86/x64 with and
without `--safe`, 1,435 ordinary targets including both Linux fixpoints,
Windows runtime and benchmark, and all 60 distinct architecture/root checks
selected by the complete change. Instrumented validation passed 1,433 targets
plus six compiler/API harnesses with a COMPLETE receipt; all 47 changed
executable compiler lines were reached. Existing coverage floors pass.

Linux optimization variants and Wine execute the runtime fixture; three ARM64
variants cross-compile locally and have required runtime CI gates. Native guards
and Memcheck report 30 allocations/frees and zero errors/leaks on each Linux
target. Seven alternating compiles of fixed parent `53c6fe88` sources measured
1.66/1.66 seconds and 116,384/116,480 KiB median peak RSS before/after. Compiler
output and prior callable/mixed-owner fixture binaries are byte-identical and
execute. These measurements describe this corpus on the shared host.

The first full run exposed one stale diagnostic assertion after slice conversion
errors moved earlier; its updated rejection test and the subsequent complete
ordinary/instrumented runs pass. Every tracked W source is identical before
and after rebasing onto the prerequisite's final validation commit. This step
supports #697/#698 under #644; their remaining deliverables stay open.
