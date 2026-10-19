# Unmapped arguments and generic array-like slicing

The unchanged pinned Preact module initialized after shared callable methods
landed, but its exported `h('div', {}, 'one', 'two')` then failed on `arguments`.
Its `Array.prototype.slice.call(arguments, 2)` path now uses the reusable runtime
operations described here; native NodeList-like hosts use the same slice path.

Function entry installs a deferred arguments binding after declaring parameters
and before evaluating defaults. Its owned argument vector is bounded by
`max_properties`, consumes fuel while copying, and is traced by the collector.
Ordinary assignments replace the deferred value without materializing it.
Strict functions and non-simple parameter functions materialize an ordinary
unmapped object on first binding read: independent indexed values, writable
non-enumerable length, and a shared throwing non-configurable `callee` accessor.
Closures and lexical arrows keep the binding/vector alive after return, and
async suspension uses the existing task roots. Parameter/body name shadowing
and `var arguments` reuse preserve the supported declaration semantics.

Mapped sloppy arguments remain an explicit unsupported completion. Non-simple
parameters combined with a body lexical/function declaration named `arguments`
are likewise explicit unsupported: this evaluator does not yet split those
parameter/body environments. Arguments iteration via Symbol.iterator, symbols,
and mapped parameter aliasing are outside this slice. Retaining an unused
arguments vector until its environment is collected is a conservative ownership
tradeoff, bounded by the heap-value and argument-count limits.

`Array.prototype.slice` is generic. It obtains length once, converts start/end
in order with ordinary numeric coercion, then tests HasProperty before each Get.
Inherited elements and native Get/Has hooks work; holes and trailing holes are
preserved. Mutations during getters affect later presence tests. Result indices
are created directly, so inherited setters cannot intercept copying. Array
constructor Get/error ordering is preserved; Symbol.species is outside the
runtime's symbol-free profile. Strings are indexed as UTF-16 code units using a
bounded wrapper; null/undefined throw and other primitive receivers yield empty
arrays. The string wrapper does not add the general boxed-primitive method
unboxing machinery. Length, allocations, index scans, conversion, and copied
entries remain subject to the existing runtime limits.

The normal and eight isolated debug-allocator test groups cover descriptor flags, callee errors,
defaults, shadowing, arguments identity and independence, closure/async GC,
constructor arguments, native getter/presence ordering and mutation, inherited
indices, sparse arrays, UTF-16 units, numeric conversion ordering, and bounds.
The coordinator runs the final integrated full W suite.

Primary specification: [FunctionDeclarationInstantiation](https://tc39.es/ecma262/#sec-functiondeclarationinstantiation),
[CreateUnmappedArgumentsObject](https://tc39.es/ecma262/#sec-createunmappedargumentsobject),
and [Array.prototype.slice](https://tc39.es/ecma262/#sec-array.prototype.slice).
