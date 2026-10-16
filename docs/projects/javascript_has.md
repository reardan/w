# Bounded property presence

The next unsupported executable operation in the unchanged Preact 10.27.2 module,
after loose equality, was `in` at source offset 3739. The runtime implements the
[ECMA-262 evaluation order](https://tc39.es/ecma262/#sec-relational-operators-runtime-semantics-evaluation)
and [OrdinaryHasProperty traversal](https://tc39.es/ecma262/#sec-ordinaryhasproperty)
for its existing property descriptor and prototype model.

Both operand expressions run before checking that the right operand is an object.
That check precedes left-operand string-hint property-key conversion. Primitive
keys use the existing UTF-16/Number/BigInt string conversion; explicit ordinary
`toString`/`valueOf` methods retain receiver, side effects and abrupt completion.
Symbols and missing intrinsic default conversion methods remain unsupported.

Presence is independent of property value, enumerability or getter. Own and
inherited accessor descriptors count without calling the accessor. Array `length`
is present; an absent index below the array length is still a hole. UTF-16 keys
preserve embedded NUL and lone surrogates. The runtime's currently absent shared
Object/Function prototype defaults are not synthesized by this operation.

Native property reads cannot be used to infer existence. A new optional
`js_runtime_set_host_has(rt, object, callback)` installs a native own-property
reflection callback. The callback type is:

```text
fn(void* runtime, void* context, js_value* receiver, js_text* key) -> int
```

It shares the object's `host_context`; receiver is the original right operand and
key is borrowed for the call. Positive returns present, zero delegates to the
object's ordinary descriptors and prototype, and negative reports unsupported.
The callback may set completion for an exception. It must report native presence
without invoking a property getter. It runs within the existing bounded property
entry scope: collection and reentrant evaluation are unavailable, and recursive
reflection shares depth/fuel. A getter/setter-backed object with no presence
callback, or an unimplemented binary exotic object, reports unsupported instead
of guessing. A presence-only callback does not authorize `for-in` enumeration.

`js_runtime_has_property(rt, object, key)` is the reusable operation for callers
already within an evaluation or an explicitly established `js_runtime_begin`
budget. Prototype traversal, descriptor scans and key comparisons charge fuel;
prototype depth and property-key length retain their existing bounds. The
operation adds no native per-runtime allocations or GC roots.

`javascript_runtime_has_test` covers undefined-valued and nonenumerable properties,
getters that must not run, inheritance, array holes, key coercion order, RHS type
errors, native callback delegation/errors/receiver identity, unavailable reflection,
collection rejection, recursion/depth/fuel and key limits. All cases run normally
and in three allocator-debug groups with zero-leak assertions.
