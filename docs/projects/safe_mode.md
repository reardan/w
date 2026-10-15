# Experimental ownership and borrowing checks

The compiler accepts `--safe` on Linux x86 and x64:

```sh
./bin/wv2 --safe app.w -o app
./bin/wv2 check --json --safe app.w
```

This is a bounded, single-threaded subset, tracked by
[issue #644](https://github.com/reardan/w/issues/644). It does not make arbitrary
legacy W code memory-safe. Unsupported operations produce errors. The broader
design, including optional references and escaping lifetime contracts, remains
in [PR #645](https://github.com/reardan/w/pull/645).

## Pointer contracts

| Type | Meaning |
| --- | --- |
| `own T*` | A non-null, uniquely owned allocation; assignment, arguments and return transfer ownership. |
| `ref T*` | A non-null shared borrow; readers may coexist. |
| `refmut T*` | A non-null exclusive borrow; other access to the backing storage is suspended while it is live. |
| `T*` | A legacy raw pointer; checked code may access it inside an explicit `unsafe:` block. |

Qualifiers are contextual: existing identifiers named `own`, `ref` or `refmut`
retain their meaning. Type aliases preserve qualifiers. A checked pointer has
the same size and calling convention as a raw pointer. The pointee must be
sized and contain no references, raw pointers, unions or containers. Partial
moves and checked pointers stored in aggregates or globals are rejected.

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
`ref` reads it, and `refmut` may mutate it. Borrowed arguments may not escape
from a checked function. Returning references or slices requires lifetime
contracts that are not yet supported and is rejected. Owned returns must
transfer an owner on every normal path. Recursion and imported functions use
the same contracts. Indirect calls, callbacks, methods and unmodeled generic
operations are rejected rather than treated as ordinary scalar calls.
Forward declarations resolve to a checked implementation and must agree with
its parameter and return contracts.

Argument evaluation is included in checking: an earlier mutable argument
cannot coexist with a later read of the same storage, including a read or
write hidden inside a nested call.

## Arrays, slices and control flow

Fixed arrays of pointer-free values are initialized by the existing array
runtime. Array and slice indices retain runtime bounds checks. A slice made
with `array[start:end]` is an immutable shared view in checked code; subviews
retain the original backing storage's lifetime. A slice parameter borrows for
the call. Array storage cannot be copied or returned by value; pass a slice.
Raw `.data` access requires an unsafe boundary.

The supported control flow is blocks, `if`/`else`, `while`, `break`, `continue`,
returns, short-circuit Boolean expressions and scalar conditional expressions.
`for`, `switch`, generators, arbitrary `goto`, GPU operations and container
operations remain unsupported. This restriction includes container growth,
clear and removal: these cannot silently invalidate a checked reference.
Declarations require a lexical block, including inside conditionals and
loops. Executable assembly bodies are rejected.

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

The audited runtime exposes scalar `put_char`, `put_error` and `exit` calls
and compiler-generated allocation, destruction and bounds operations. Import
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

## Validation

`safe_mode_test` exercises accepted and rejected programs on x86 and x64,
with and without the flag. `safe_runtime_test` uses the guard allocator to
observe leaks and duplicate destruction across transfer, replacement,
parameters, return, break, continue and fall-through cleanup.
`safe_cli_test` covers option order, structured conflicts and in-process
rejection. The parser-generator grammar includes the contextual qualifiers
and unsafe blocks. Self-host fixpoints, the full suite, cross-architecture
compiler checks and changed-line coverage remain the release gates.
