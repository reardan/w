# Experimental ownership and borrowing checks

The compiler accepts `--safe` on Linux x86 and x64:

```sh
./bin/wv2 --safe app.w -o app
./bin/wv2 check --json --safe app.w
```

This is a bounded, single-threaded subset, tracked by
[issue #644](https://github.com/reardan/w/issues/644). It does not make arbitrary
legacy W code memory-safe. Unsupported operations produce errors. The broader
design, including optional references and broader lifetime contracts, is
tracked in the [ownership and borrowing roadmap](safe_mode_roadmap.md).

## Pointer contracts

| Type | Meaning |
| --- | --- |
| `own T*` | A non-null, uniquely owned allocation; assignment, arguments and return transfer ownership. |
| `ref T*` | A non-null shared borrow; readers may coexist. |
| `refmut T*` | A non-null exclusive borrow; other access to the backing storage is suspended while it is live. |
| `ref T[]` | An immutable checked slice with an inline descriptor and a borrowed data lifetime. |
| `ref[a] Record` | An inline struct value whose shared-reference fields borrow for one named lifetime. |
| `T*` | A legacy raw pointer; checked code may access it inside an explicit `unsafe:` block. |

Qualifiers are contextual: existing identifiers named `own`, `ref` or `refmut`
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
arithmetic, raw-pointer conversion or an integer. Optional references are not
part of this subset; use ordinary control flow instead of a nullable reference.

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
Reference bindings cannot be reassigned in this release.

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
result remains unsupported. References cannot be reassigned or fabricated
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
relationship within a function signature. The result's label must occur on
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
`own` does not take a lifetime label. General outlives clauses remain a
future extension.

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
storage, heap construction, mutable-reference fields, nested aggregates and
multiple independent field-lifetime groups remain unsupported in this form.

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
the implementation is checked even without `--safe`. Indirect calls,
callbacks, methods and unmodeled generic
operations are rejected rather than treated as ordinary scalar calls.
Forward declarations resolve to a checked implementation and must agree with
its parameter and return contracts.

Argument evaluation is included in checking: an earlier mutable argument
cannot coexist with a later read of the same storage, including a read or
write hidden inside a nested call. A projected store keeps its destination
borrowed while evaluating the right-hand expression; indexing likewise keeps
the receiver borrowed while evaluating the index. Nested moves, replacement
or mutation of that backing storage are rejected. Reading the same storage
for an update, or replacing an owner in a separate statement, remains valid.

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

The supported control flow is blocks, `if`/`else`, `while`, `break`, `continue`,
returns, short-circuit Boolean expressions and scalar conditional expressions.
`for`, `switch`, generators, arbitrary `goto`, GPU operations and legacy
container operations remain unsupported. The audited concrete storage APIs
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
future extensions.

## Cleanup and unsafe boundaries

Every live owner is destroyed in reverse declaration order at its normal
scope exit. Function exits also destroy owned parameters. Return values are
evaluated and ownership transferred before other owners are destroyed.
Replacement assignment evaluates and transfers the new owner, destroys the
previous live allocation, and installs the replacement. Moving an owner clears
its stack slot; cleanup tests the slot before freeing it. This accounts for
branch-dependent transfers without reference counting or garbage collection.
There is no cleanup promise after process termination or a trap.

Exit-time `defer` is rejected in checked functions. Its existing deferred
reads and arbitrary control flow have not been integrated into borrow
liveness, and it cannot be used to manually free an owner a second time.

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

## Entry points, diagnostics and costs

`--bounds=off` and the streaming frontend are incompatible with checked
pointers, with or without `--safe`. Other targets and in-process REPL/debugger
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

The final merged implementation passes all 1,237 targets from
`./wbuild -j 6 tests verify_x64 wbench_compare`, including both self-host
fixpoints and the benchmark gate. The instrumented full suite passes all
1,236 of its targets and reaches 636 of 653 changed executable compiler
lines (97%). Compiler line/branch coverage is 95.3% / 85.5%; code-generator
coverage is 97.0% / 88.5%. Coverage floors retain the measured gains.
Compiler checks pass for x86, x64, win64, arm64 and arm64_darwin, along with
six manifest-selected architecture/root checks. These check compiler
portability; checked application support remains Linux x86/x64.
Independent review found an evaluation-order lifetime hole in
projected stores and indices; temporary backing-storage reservations and
15 positive/negative regression cases cover the fix. These results remain
regression evidence, not a proof of soundness or Rust-level maturity.
