# Generic Array.prototype.some

Pinned unchanged Preact calls `some` on its commit queue on every render,
including an empty first queue. This implementation follows the generic
[Array.prototype.some algorithm](https://tc39.es/ecma262/#sec-array.prototype.some):
coerce the receiver, obtain length once, validate the callback, then perform
HasProperty and Get in ascending index order. Each callback receives the value,
index, and original object, with the supplied thisArg. The first truthy result
ends iteration. Holes are skipped; inherited/native indices participate.

Length snapshotting excludes appended entries. Deletion and changes before an
index is visited affect that index. Exceptions from length, presence, Get, or
callback end evaluation immediately. Callback promises are ordinary truthy
objects; some does not await them. Async callbacks retain their arguments
through the existing task/arguments roots. A native forwarding depth guard
prevents recursive host callbacks from bypassing the execution depth limit.

Receiver conversion shares the bounded array-like machinery used by slice;
length/property/heap/fuel limits remain enforced. Symbols, proxies and general
boxed-primitive unboxing remain outside that machinery's documented profile.
Tests cover empty queues, generic receivers, callback arguments and receivers,
holes/prototypes, mutation and early exit, async continuation across GC,
native Has/Get/callback order, abrupt completion and depth/fuel/length bounds.
