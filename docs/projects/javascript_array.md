# Bounded Array construction

The unchanged Preact 10.27.2 production module initially failed evaluation at
`w=Array.isArray` because only internal array prototypes/methods existed. The
runtime now installs callable/constructable `Array` and noncoercing `Array.isArray`.
The implementation follows the supported branches of the
[ECMA-262 Array constructor](https://tc39.es/ecma262/#sec-array-constructor).

`Array()` and `new Array()` create distinct empty arrays. One numeric argument
sets a sparse length without creating index properties; negative, fractional,
non-finite and values above 2^32-1 throw RangeError. A valid length exceeding
`max_properties` instead fails with the runtime resource-limit completion. A
single non-number is an element, including strings, BigInts, null and objects;
no object coercion runs. Two or more arguments become elements in order.
Creation defines own writable/enumerable/configurable index properties and does
not invoke inherited index setters.

`Array.prototype` is itself an empty array with the existing shared methods.
New arrays and literals retain it as their prototype, and its nonenumerable
`constructor` refers back to Array. Constructor name/length/prototype and isArray
name/length have explicit descriptors. IsArray checks the internal array kind;
changing prototypes or copying `constructor` does not forge the brand. Typed
arrays and array-like ordinary objects are false. No Symbol, Proxy, species,
Array.from/of or native-class-subclass support is added by this slice.

Argument lists and resulting lengths use `max_properties`; element work consumes
execution fuel, and all allocation uses the existing heap/value bounds. Prototype
and constructor cycles are retained by existing ordinary GC traversal. Tests cover
call/new identity, sparse versus undefined elements, numeric errors, descriptors,
receiver-independent branding, prototype mutation, inherited setters, collection,
and resource exhaustion. All tests run normally and in three allocator-debug
groups with zero-leak assertions.

## Callback iteration

`every`, `forEach`, `map`, `filter`, `find`, `findIndex`, `findLast`,
`findLastIndex`, `reduce`, and `reduceRight` are generic methods accepting arrays,
strings and bounded array-like receivers. They read/coerce length once before
validating the callback. Values and property presence remain live during iteration:
appends beyond the initial length are ignored, updates are observed, and the
presence-based methods skip missing properties while including inherited ones.
The four `find` methods instead visit holes as `undefined`. Reverse operations
visit descending indices. `map` preserves holes and `filter` creates dense own
data properties without invoking inherited index setters.

Callbacks receive value/index/object and the optional `thisArg`; reductions
receive accumulator/value/index/object with undefined `this`. Reductions without
an initial value start at the first present element and throw TypeError if none
exists. An explicitly supplied undefined initial value is preserved. Ordinary
sloppy receiver substitution/boxing remains outside the runtime profile.

Work charges shared fuel, length/arguments obey `max_properties`, and recursive
native forwarding obeys depth limits. Native HasProperty and Get failures stop
before later callbacks; their observable ordering has embedding tests. Normal
and partitioned guard-allocator tests assert successful cleanup. The pinned
Test262 selection adds sixteen unchanged files, including explicit unsupported
neighbors requiring literal elisions, property deletion and sloppy mapped
arguments. Symbols, Proxy and custom species are still unsupported; `map` and
`filter` preserve the constructor read and reject invalid primitive constructors,
then produce ordinary arrays in this profile.

Algorithms follow [ECMA-262 indexed collections](https://tc39.es/ecma262/multipage/indexed-collections.html).
