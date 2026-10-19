# Bounded JavaScript for-in

The runtime supports `for (var key in value)`, `let`/`const` identifier
bindings, and existing identifier/member assignment targets. The original
Preact 10.27.2 production helper `function d(n,l){for(var u in l)n[u]=l[u];return n}`
is a regression case. This removes its first executable-statement AST lowering
failure; it does not establish Preact runtime support.

Enumeration follows the ordinary-object algorithm in
[ECMA-262 14.7.5.9–10](https://tc39.es/ecma262/multipage/ecmascript-language-statements-and-declarations.html#sec-enumerate-object-properties):

- Snapshot each object's own string keys when that prototype level is reached.
  Array indices precede other strings; indices sort numerically, other names keep
  insertion order.
- Recheck each own descriptor before processing. Deleted properties are skipped.
  Every still-present name is visited, even if nonenumerable, so a nonenumerable
  own property shadows an enumerable inherited property of the same name.
- Yield a name at most once. New names on a level already snapshotted are ignored;
  later prototype levels are discovered lazily. Getters are not called merely to
  enumerate their descriptors.

The current implementation handles ordinary objects, arrays, callable objects,
and string primitive UTF-16 indices. Array/string length is nonenumerable.
Null and undefined produce no iterations; other supported primitives have no
own enumerable keys. Native property-hook objects and binary/typed-array exotic
objects are explicitly unsupported. Symbols, proxies, destructuring loop heads,
Annex B initializers, and general native own-key hooks remain outside this slice.
Assignment targets retain the existing runtime rule that unresolved names fail.

Lexical heads have a TDZ while the right-hand expression runs and fresh bindings
for each iteration. Var heads participate in the enclosing scope's ordinary
hoisting. Break, labelled continue, throws, return, and genuine await suspension
use the existing completion machinery.

Snapshot/visited lists own cloned UTF-16 names and are released on every exit,
including terminal async cancellation. Suspended object references use the
runtime's existing conservative roots. `max_properties` bounds each snapshot and
the aggregate visited set; `max_depth` bounds prototype traversal. Key copies,
sorting, duplicate checks and iteration charge the execution budget. Enumeration
does not create an unbounded hidden iterator or invoke nested host checkpoints.

Focused tests include ordering, nonenumerable shadowing, deletion/addition and
attribute mutation, getter avoidance, null/primitive cases, lexical capture,
labelled control flow, GC across await, cancellation, and resource limits.
