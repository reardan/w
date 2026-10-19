# Bounded string coercion

`js_runtime_string_text(rt, value)` returns owned UTF-16 text or null with the
runtime completion set. `String(value)` and Error message construction use this
helper. The existing `js_runtime_primitive_text` deliberately remains
primitive-only, so numeric, regex, and other APIs do not silently acquire new
observable coercion behavior.

For ordinary objects with explicit conversion methods, the helper reads
`toString` then `valueOf`, skipping non-callables, calling each with the original
receiver and no arguments, and stopping at the first primitive result. Getter
and call exceptions propagate unchanged. A callable returning an object does
not recursively convert that result. When neither method yields a primitive,
a TypeError is thrown. Recursive user calls to String consume execution budget
and the runtime depth limit; they cannot recurse on the native stack forever.

`Error.prototype.toString` is generic over object receivers. It reads and
converts `name` before reading and converting `message`; undefined defaults to
`Error` and the empty string, respectively. Empty components suppress the
separator. All text operations preserve embedded NUL and lone UTF-16 surrogates.
The existing string-size limit bounds combined output. Error subclasses inherit
the method, so the unchanged host's `String(e)` preserves the actual caught
error message.

This is not complete ToPrimitive support. Symbol values/protocols and exotic
intrinsic/host coercion are unsupported. The runtime has no shared default
Object/Function/Array prototype conversion methods. An absent `toString`
therefore reports unsupported status 6; explicitly present undefined or other
non-callables correctly fall through to `valueOf`. This prevents silently
changing the precedence of the missing default Object.prototype.toString.
New boxed String objects are still unsupported. Resource exhaustion is terminal
status 5. These limits are distinct from catchable conversion TypeErrors.

Run `./wbuild javascript_runtime_string_coercion_test`. It covers method order,
receivers, inherited methods, primitive results, throws, failed conversion,
Error defaults/subclasses, observable getters, recursive limits, and debug
allocator cleanup. The semantic snippets were checked with Node against
[OrdinaryToPrimitive](https://tc39.es/ecma262/multipage/abstract-operations.html#sec-ordinarytoprimitive)
and [Error.prototype.toString](https://tc39.es/ecma262/multipage/fundamental-objects.html#sec-error.prototype.tostring).
