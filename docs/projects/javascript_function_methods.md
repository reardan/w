# Shared callable methods

The unchanged Preact 10.27.2 module reaches successful native module evaluation
with Function.prototype call/apply/bind. Its bootstrap uses
`Promise.prototype.then.bind(Promise.resolve())`; the shared implementation follows
[call](https://tc39.es/ecma262/#sec-function.prototype.call),
[apply](https://tc39.es/ecma262/#sec-function.prototype.apply) and
[bind](https://tc39.es/ecma262/#sec-function.prototype.bind) for supported values.

Every ordinary, class and native callable inherits the shared callable prototype.
Call forwards the supplied receiver and arguments. Apply accepts null/undefined
as an empty list, otherwise reads an array-like object's length once, converts it
to bounded length, and Gets each indexed argument in order. Holes become undefined;
getters and exceptions are observable. Primitive string argument lists are rejected.
Ordinary numeric-hint length conversion reuses the bounded primitive conversion
helper, with BigInt rejected. Sloppy receiver boxing/global-this conversion remains
outside the existing runtime subset; strict receivers pass through unchanged.

Bind owns a native list of bound argument values and traces it alongside target
and receiver. It snapshots the target's prototype and obtains own length/name
metadata in specification order. Length is noncoercing, truncated and reduced by
the bound count; non-string names become empty. The resulting callable has no own
prototype property. Nested binding preserves the earliest bound receiver and
prefix argument order. Construction forwards to constructable targets while
ignoring the bound receiver and substituting the original new target as required;
instanceof follows the bound target. Custom native subclass construction remains
unsupported apart from the existing Error path. Getter/setter-backed native
callable metadata reflection remains unsupported.

The Function global exposes this shared prototype, while dynamic Function source
construction explicitly remains unsupported. Existing native constructability
restrictions are preserved. No Symbol/Proxy-specific callable hooks are added.

All forwarding paths charge fuel and depth, including native-to-native recursion.
Combined argument lists obey max_properties before copying; array-like length is
bounded before indexing. Temporary forwarding lists are freed on errors and normal
return; retained lists are freed with their callable and traced during collection.
Tests cover strict/native/arrow receivers, generic apply/Get order, metadata getter
order and exceptions, nested bound calls, ordinary/class/native construction,
instanceof, prototype snapshot, retained values and pending reactions across GC,
resource limits, and unsupported dynamic construction. Every case runs normally
and in four allocator-debug groups with zero-leak assertions.

Successful module evaluation is a bootstrap milestone. Calling Preact createElement
still requires an arguments object and generic Array.prototype.slice; rendering
and the workflow fixture are not claimed by this change.
