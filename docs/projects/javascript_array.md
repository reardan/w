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

A native probe of the unchanged full Preact module advances to its next runtime
failure, ordinary function prototype mutation at `x.prototype.setState=...`.
Ordinary function construction/prototype and Function.prototype call/apply/bind
remain subsequent work; this slice does not claim successful Preact bootstrap.
