# Ordinary function construction

After Array installation, the unchanged Preact module reached bootstrap writes to
`x.prototype.setState`. Ordinary, non-async function declarations and expressions
now have an own prototype object. Its `constructor` points to the function;
`function.prototype` is writable, nonenumerable and nonconfigurable. Arrows, async
functions and class methods receive no constructor prototype.

`new` uses the existing bounded constructor execution path. It allocates a receiver
from the current constructor prototype, initializes `this` before parameters and
the body, preserves thrown completions, returns an explicit object result when
present, and otherwise returns the receiver. A primitive replacement prototype
uses the runtime's existing ordinary-object default (currently a null prototype,
until the shared Object prototype is implemented). Ordinary functions can also be
class heritage constructors; `super` receives the derived class's prototype.
Normal calls retain their prior behavior. Function length now stops at the first
default/rest parameter, matching the existing class constructor length behavior.

This follows the supported parts of
[ECMAScript function construction](https://tc39.es/ecma262/#sec-ecmascript-function-objects-construct-argumentslist-newtarget)
and [MakeConstructor](https://tc39.es/ecma262/#sec-makeconstructor).
Dynamic Function construction, generators, implicit arguments objects and shared
Function.prototype call/apply/bind are separate work. Sloppy primitive/global this
conversion retains its existing explicit unsupported completion.

Prototype/constructor cycles use ordinary traced values. Construction and nested
`super` calls share execution fuel/depth; prototype creation uses existing property
and heap bounds. `javascript_runtime_function_construct_test` covers descriptor
attributes, normal call versus construction, primitive/object returns, default
parameters, replacement prototypes, derived classes, lexical this capture,
nonconstructable callable forms, exceptions, recursion and allocation exhaustion.
All cases run normally and in three allocator-debug groups with zero-leak checks.

The unchanged full Preact module now advances past prototype mutation and fails
at a noncallable method during the `Promise.prototype.then.bind(...)` bootstrap.
