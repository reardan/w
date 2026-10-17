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
| `ref T*` | A non-null shared borrow; readers may coexist. |
| `refmut T*` | A non-null exclusive borrow; other access to the backing storage is suspended while it is live. |
| `optref T*`, `optrefmut T*` | An optional shared/exclusive borrow; dereference requires a presence check. |
| `ref T[]` | An immutable checked slice with an inline descriptor and a borrowed data lifetime. |
| `ref[a] Record` | An inline struct value whose shared-reference fields borrow for one named lifetime. |
| `refmut[a] Record` | An inline exclusive borrowed struct; copies are reborrows of its one lifetime group. |
| `T*` | A legacy raw pointer; checked code may access it inside an explicit `unsafe:` block. |

Qualifiers are contextual: existing identifiers named `own`, `ref`, `refmut`,
`optref` or `optrefmut`
retain their meaning. Type aliases preserve qualifiers. A checked pointer has
the same size and calling convention as a raw pointer. The pointee must be
sized and contain no references, raw pointers, unions or containers, except
for the explicitly supported aggregate forms below. Partial moves and
checked pointers stored in globals are rejected.

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
The existing generic parameter/result shape restrictions still apply.
Quantified function values and aggregate lifetime groups follow the contracts
described below; generic aggregate signature shapes remain separately gated.
No runtime representation, allocation or destruction order changes.

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
reassignment, descriptor-field addresses, optional fields, mixed owned/borrowed
fields and partial moves remain rejected. Independent groups use the explicit
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
within each group. Borrowed wrapper reassignment, reference-field replacement,
mixed owned/borrowed fields and partial moves remain separate requirements.
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
assignment remain rejected. Recursive ownership type cycles, mixed borrowed
fields and mutable-reference fields are not supported. Allocation failure
and other traps terminate the process; cleanup during termination is not
promised.

Owned type graphs are bounded to depth 32 and at most 256 allocation nodes
per expanded destructor. Larger graphs produce errors instead of unbounded
compiler work.

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
call. Generic syntax does not bypass the checker. Checked slices and inline
borrowed records as generic type arguments remain excluded by the existing
aggregate call limits. Generic method syntax and capturing callbacks remain
unsupported in checked code, as does the existing unsupported `new T`
allocation syntax in generic definitions. Noncapturing function pointers use
the explicit quantified contracts below.

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
escapes, global/aggregate callable storage and const-qualified callable
forms. These contracts describe ordinary W entry points; generators, kernels,
variadic entry points and unaudited foreign functions cannot become checked
function values. Capturing or escaping closure environments remain a separate
workstream. Signatures admit at most ten parameters; nested validation is
bounded to depth 32 and 256 expanded type visits.

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
its body still cannot return a view of local or owned storage. Optional aggregate fields, optional slices,
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

Ordinary `T[]` keeps its legacy pointer-to-descriptor ABI; implicit
mixing with the inline checked representation is rejected. Mutable checked
slices, descriptor construction, metadata borrowing and reassignment remain
unsupported. Slice elements must be pointer-free sized values. To obtain a
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

## Cleanup and unsafe boundaries

Every live owner is destroyed in reverse declaration order at its normal
scope exit. Function exits also destroy owned parameters. Return values are
evaluated and ownership transferred before other owners are destroyed.
Replacement assignment evaluates and transfers the new owner, destroys the
previous live allocation, and installs the replacement. Moving an owner clears
its stack slot; cleanup tests the slot before freeing it. This accounts for
branch-dependent transfers without reference counting or garbage collection.
There is no cleanup promise after process termination or a trap.

Checked `defer` registrations must appear directly in the outer function
block. The return expression is evaluated and transferred first, deferred
expressions run in LIFO order against their exit-time bindings, then remaining
owners are destroyed. Deferred reads keep their backing storage borrowed;
a deferred move cannot consume an owner already transferred by the return.
Returned references remain protected while deferred work runs. Nested loop,
branch or block registrations remain rejected; this extension does not give
W's static registration rules dynamic per-iteration semantics. Nested exits
after an outer registration still execute the registered work at function exit.

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
