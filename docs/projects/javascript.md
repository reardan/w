# JavaScript parsing, ASTs, and embedded execution

The JavaScript integration combines a generated parser with a JavaScript-aware
lexer. It is an initial compatibility implementation, not a claim of complete
ECMAScript conformance. Its grammar is explicitly adapted from pinned upstream
sources; importing the upstream ANTLR grammar directly in strict mode fails
with an actionable semantic audit.

## Try the examples

```sh
./wbuild javascript_inspect javascript_build_example javascript_transform
bin/javascript_inspect --module examples/javascript/sample.mjs
bin/javascript_build_example > bin/greet.mjs
bin/javascript_transform examples/javascript/sample.mjs old-package new-package
```

`inspect.w` reports function/class declarations and static module references;
`--check` performs validation only. `build.w` constructs an owned AST for an
exported greeting function, prints it, reparses it, and verifies structural
agreement. `transform.w` rewrites decoded static import/re-export specifiers,
preserving every other source byte, including comments and whitespace. Dynamic
imports and ordinary strings are unaffected. CLI failures return nonzero and
write diagnostics to stderr.

## Parse and inspect

Generate the parser with `./wbuild javascript_parser`, then import
`libs.extras.javascript.parser`:

```w
pg_parse_result* result = js_parse(source, length, c"input.mjs", 1)
if (result.success):
	# Inspect result.root and its children, tokens, and byte spans.
	println(result.root.name)
else: pg_diagnostics_print(result.diagnostics)
pg_parse_result_free(result)
```

The final argument selects Module (1) or Script (0). The explicit-length API
copies the input and diagnoses embedded NUL bytes. `js_parse_script` and
`js_parse_module` are conveniences for NUL-terminated input. A result owns the
source, token stream, generated concrete syntax tree, and diagnostics; borrowed
nodes and tokens remain valid until `pg_parse_result_free`. Lines and columns
are one-based; offsets, lengths, and columns count UTF-8 bytes. Trivia remains
available in `result.stream.all_tokens`. `success` requires complete parsing,
clean lexer diagnostics, and the implemented early-error checks.

The lexer distinguishes regular expressions from division using parser-selected
lexical goals. A mode stack and interpolation brace context handle nested
templates. Unicode 12.1 identifier tables are vendored and reproducibly generated
by `bin/javascript_unicode --check`. Comments retain line-break
information for automatic semicolon insertion and restricted productions.

The grammar handles expressions and precedence, optional chaining and nullish
coalescing, templates, declarations and destructuring, control flow, functions,
arrows, generators, async functions, classes, and static/dynamic module syntax.
Contextual validation covers strict directives, binding conflicts, restricted
productions, assignment targets, and several function/class/module early errors.
These families describe implemented syntax, not exhaustive coverage of each
ECMAScript static-semantics rule.

## Build and lower ASTs

Import `libs.extras.javascript.ast`, `printer`, and optionally `lower`.
`js_node_new(kind, text)` creates an owned node. Add children with `js_node_add`;
each child must have exactly one parent. `js_node_replace` returns the detached
old child, which the caller must free. `js_node_walk` visits nodes and
`js_node_equal` compares structure without spans. `js_node_free` recursively
frees the tree. Constructed nodes have offset -1; lowered nodes carry source
byte spans.

`js_lower(result)` returns an independent semantic AST for the supported facade
or reports an unsupported shape. `js_print(root, diagnostics)` accepts a program
or statement root and returns owned text; unsupported/invalid node shapes return
null with diagnostics. Its output is deterministic, with explicit expression
parentheses. Reparse printed output when a validated JavaScript program is
required: node-shape validation is not a full contextual validator.

The facade supports simple variables, function declarations/expressions and
parameters, synchronous arrows, blocks, return, throw, if, while/do/for loops,
lexical `for-of`, labelled statements and labelled/unlabelled
break/continue, try/catch/finally, expressions, assignments and prefix/postfix
updates, calls/members, dense arrays, ordinary named/string-keyed
objects (including distinct shorthand properties), templates, simple imports,
and exported declarations. Lowering preserves escaped non-directive strings so
printing cannot accidentally introduce a strict-mode directive. Parsing is
broader: lowering intentionally rejects classes, async/generator functions,
computed object keys and richer module declarations. Runtime-oriented lowering
also supports binding patterns, rest/default parameters, `new`, optional chains,
spread and object methods. These newer nodes are not yet supported by every
printer/rewrite operation; `js_print` reports an explicit unsupported shape.
Node shapes are documented in `libs/extras/javascript/printer.w` and exercised
in `tests/javascript/roundtrip_test.w`. Additional shapes are:

| Kind | Text | Ordered children |
| --- | --- | --- |
| `while`, `do_while` | empty | condition, body |
| `for` | empty | initializer, condition, update, body |
| `label` | decoded label name | statement |
| `break`, `continue` | optional decoded target label | none |
| `function_expression` | optional name | parameters, block |
| `arrow` | empty | parameters, expression or block |
| `for_of` | `let` or `const` | binding pattern, iterable expression, body |
| `object_pattern`, `array_pattern` | empty | binding entries |
| `pattern_property` | decoded property name | binding pattern |
| `default_pattern` | empty | binding pattern, initializer |
| `rest`, `spread` | empty | binding pattern or expression |
| `optional_chain` | empty | complete chain expression |
| `optional_member`, `optional_computed_member`, `optional_call` | empty | same children as ordinary operation |
| `bigint` | integer spelling without `n` | none |
| `try` | empty | block, catch or empty, finally block or empty |
| `catch` | optional identifier | block |
| `string_utf16` | empty | none; value in `string_units` |

An omitted for clause/catch/finally uses an `empty` node with offset -1;
source-backed nodes preserve byte spans. `for-in`, assignment-target/`var` for-of bindings and
catch destructuring remain explicit lowering failures. The printer handles
loop bodies and label wrappers when protecting against a dangling `else`.

`libs.extras.javascript.text` supplies owned `js_text` values, with explicit
UTF-16 code units in `units`. `js_text_decode(bytes, byte_length)` decodes a
complete quoted token, retaining embedded NUL and unpaired surrogates.
`js_text_from_utf8(bytes, byte_length)` strictly validates UTF-8 and accepts NUL;
`js_text_to_utf8(value, &byte_length)` returns an owned terminated buffer and
explicit byte count, or null for an unpaired surrogate/invalid code unit. It
never substitutes U+FFFD. Free buffers with `free` and texts with `js_text_free`.
Do not use `strlen` for the UTF-8 result's content length.

`js_string_utf16` copies this representation into the AST. Scalar, non-NUL
values keep the existing `string` kind and `text` field for compatibility;
other values use `string_utf16` and owned `string_units`. The printer escapes
every code unit of those nodes, permitting lossless parse/print round trips.
The older `js_string_decode` char-pointer API still rejects unrepresentable
strings; module-specifier edits and literal object property names retain that
contract. Runtime computed property keys use UTF-16 and can contain NUL.

`js_parse_with_limits(source, length, filename, module, limits)` exposes
`js_parse_limits_new()` defaults: one million cumulative token and AST
allocations and 4096 nested checkpoints. Change the three fields before
parsing and free the limits independently. Speculative allocations count and
resource errors remain sticky across rollback. `js_parse` uses the same defaults.
Null limits select defaults; nonpositive limits, negative lengths and a null
buffer with positive length produce an owned failed result with diagnostics.
A null buffer of length zero is an empty program.

## Embed the interpreter

Import `libs.extras.javascript.runtime` after generating the parser. The
interpreter requires a 64-bit W target because its number representation is
IEEE-754 binary64; the parser, AST and UTF-16 APIs still support x86.

```sh
./wbuild javascript_embed_example javascript_runtime_test
bin/javascript_embed_example
```

[`examples/javascript/embed.w`](../../examples/javascript/embed.w) binds a
native `doubleNumber` callback and evaluates a script producing 42. It imports
only reusable library APIs, with no DOM, renderer, timers or browser policy.
Pinned consumers must generate `bin/generated_javascript_parser.w` in the W
dependency checkout (`./wbuild javascript_parser`) before compiling the example
or their runtime consumer. No Node installation is required for execution.

Create an independent instance with `js_runtime_new`, call
`js_runtime_eval(rt, source, byte_length, step_budget)`, and destroy it with
`js_runtime_free`. Instances have separate heaps, global lexical environments,
script storage and roots. Do not share an instance concurrently. Distinct
instances share no mutable runtime state. The returned `js_completion` is
instance-owned and overwritten by the next evaluation or host invocation:

| Status | Meaning |
| --- | --- |
| 0 | normal; last nonempty statement value (declarations preserve an earlier value) |
| 2 | thrown value or runtime error; diagnostic in `message` |
| 5 | execution, parser or allocation limit; terminal for this evaluation |
| 6 | syntax/operation outside the implemented subset |

Statuses 1, 3 and 4 are internal return/break/continue completions. User-thrown
values and host exceptions are catchable. Runtime errors carry an object with
`name` and `message` properties (ReferenceError,
TypeError or SyntaxError); full Error intrinsics/prototypes remain unimplemented.
Runtime-created error values also carry a host-visible `intrinsic_error_name`
brand, a borrowed static string independent of mutable JavaScript `name`
properties. Ordinary values have an empty brand. The Test262 driver uses this
identity for negative error checks, so a user-created object with a matching
`name` cannot imitate an engine exception.
If the configured heap/property limits cannot accommodate that object, the
thrown value is undefined and the diagnostic remains in `message`.
Resource/unsupported failures cannot be caught and do not execute finalizers.
Normal return/throw/break/continue completions do execute `finally`, and an
abrupt finalizer overrides the earlier completion.

Labelled break exits its enclosing labelled statement; labelled continue targets
the loop wrapped by one or more labels. Targets survive `finally` unless its
abrupt completion overrides them, and labels cannot cross a function boundary.
Labelled function declarations remain unsupported (Annex B semantics).

The initial semantic subset is deliberately explicit:

- Undefined, null, booleans, binary64 decimal/hex/binary/octal numbers, UTF-16 strings; truthiness,
  strict equality (including NaN), numeric `+ - * /` and comparisons, string
  concatenation, `!`, numeric unary `+ -`, `void`, `typeof`, `&& || ??`, comma and ternary.
  Bitwise `& | ^ ~ << >> >>>` use 32-bit JavaScript integer semantics.
  `typeof` returns `undefined` for missing names while preserving TDZ failures.
- Function/global `var` hoisting and redeclaration, parameter/var sharing, and
  duplicate body function declarations with the last declaration winning.
  Nested block functions remain lexical; Annex B semantics are not implemented.
- `let`/`const` with temporal dead zones and immutable bindings, lexical blocks,
  hoisted ordinary function declarations within each block, named/anonymous
  function expressions, synchronous arrows with expression or block bodies,
  object/array binding patterns and default/rest parameters, recursive calls, captured mutable environments and
  per-iteration `for (let ...)` environments, including a separate initializer
  environment for captured bindings.
- Dense array literals, bounded index writes and writable `length`; plain data
  objects, shorthand properties and methods, dot/computed property access,
  optional chains and mutation. Array/call spread accepts arrays and strings;
  object spread copies enumerable own properties. Shared non-enumerable array
  methods include `push`, `shift`, `slice`, `splice`, and `includes`; string
  methods include `slice`, `codePointAt`, `startsWith`, and `indexOf`.
  String length/indexing use UTF-16 code units. Host-installed prototypes, data
  descriptors and accessors participate in property reads/writes; inherited
  accessors receive the original receiver. Read-only writes are ignored in
  sloppy code and throw in strict code. Function values expose `name`/`length`.
  Method calls pass `this`; arrows retain their enclosing receiver.
- Lexical `for (let/const pattern of value)` over arrays and strings. Arrays read
  their live length each iteration; holes yield undefined. Strings iterate Unicode
  code points, preserving lone surrogates. Each iteration creates a fresh binding
  for captured closures; the iterable expression sees the binding in its TDZ.
- Cooked templates normalize raw CR/CRLF, decode escapes into UTF-16, and
  interpolate undefined, null, booleans, numbers and strings. Number spelling uses
  JavaScript decimal/exponent thresholds, including negative zero, NaN and infinity.
  Substitutions execute once in source order; object conversion remains unsupported.
- `= += -= *= /= &= |= ^= <<= >>= >>>=`, prefix/postfix `++ --`, if/while/do/for, labelled statements,
  labelled/unlabelled break/continue, return, throw and try/catch/finally.

Unsupported syntax is rejected before execution, including module declarations
through the script API, classes, generators/async, regex execution, tagged
templates, prototype-literal `__proto__`, loose equality and additional numeric
operators. Custom iterators, implicit operator coercions and exotic property-key
conversions remain outside this subset. Destructuring assignment, computed binding
keys and catch patterns remain unsupported. Global `this`, sloppy receiver
substitution/boxing, `super` and ordinary functions' implicit `arguments` object
are not implemented; accessing these receiver/arguments features reports
unsupported status. Explicit `arguments` parameters remain ordinary bindings.

Native Promise, binary buffers/views and text-codec constructors are supported;
other constructor capabilities depend on installed host hooks. The runtime also
installs bounded Number, Math and Date operations; this is not a complete standard
library. BigInt literals lower to a distinct node for the bounded binary-boundary
implementation; arbitrary-precision arithmetic is not implemented. No DOM, timer
task queue or browser authority is installed by the runtime. The separate
[module API](javascript_modules.md) provides bounded acyclic graph loading with
named const/function exports and live read-only imports. Browser module loading
does not yet support top-level await.

Scope conflicts are checked before installing bindings, so a rejected script
does not leave its otherwise fresh declarations in the temporal dead zone.
Named function-expression bindings ignore assignment in sloppy code and throw
in strict code. Strictness propagates into nested closures. The global environment
still combines lexical and variable bindings rather than implementing the full
ECMAScript Global Environment Record. These boundaries are not claims of complete
ECMAScript semantics; #492 remains the broader syntax/conformance track.

`js_runtime_bind(rt, name, callback)` installs a host function. Its W signature
is `fn(void*, list[js_value*]) -> js_value*`; cast the context to `js_runtime*`.
Arguments and their list are borrowed for the callback, and the callback must
return a value owned by this same instance. Use `js_runtime_number`,
`js_runtime_boolean`, `js_runtime_string` or the instance's `undefined_value`.
`js_runtime_throw` supplies a thrown value. `js_runtime_get/set` provide UTF-8
host property names; `js_runtime_member_read/write` accept explicit UTF-16 keys
and honor descriptors, prototypes and host hooks. `js_runtime_property/put` are
low-level own-property/binding operations, not descriptor-aware object access.
Foreign-instance values are rejected. Host code must cooperate with its own
cancellation/deadlines; the interpreter cannot preempt native code. Recursive
evaluation or invocation of the same instance returns null without changing the
active completion.

Use `js_runtime_invoke(rt, callable, arguments, step_budget)` to call a retained
JavaScript closure from a native event loop or another host entry point. Pass a
non-null borrowed `list[js_value*]` (an empty list means no arguments); the
callable and every argument must belong to the instance. The argument count is
bounded by `max_properties`. Foreign/null values or
non-callables return a thrown runtime error. The result uses the same completion
statuses and ownership as `js_runtime_eval`. Invocation consumes one dispatch
step plus the usual AST-visit steps, enforces depth/value limits, and propagates
JavaScript or host exceptions. Native callbacks remain cooperatively bounded.
It does not parse or retain a new script, so invoking a closure still works at
the retained-script cap. Register roots for any callable or arguments held by
host code across collection; the latest returned/thrown value is automatically
rooted by its completion. This entry point implements execution only: the host
owns event queues, timers and scheduling.

[`examples/javascript/events.w`](../../examples/javascript/events.w) retains an
arrow handler, performs collection, and dispatches a plain event object whose
result is formatted by a template. Run `./wbuild javascript_events_example`.
The host owns scheduling, event schemas and the exposed capabilities.

Host object integration uses fully specified descriptors, not partial ECMAScript
descriptor records. `js_runtime_define_data` takes a value and writable,
enumerable, configurable flags; `js_runtime_define_accessor` takes optional
same-instance getter/setter callables and enumerable/configurable flags.
`js_runtime_delete` respects configurability, and `js_runtime_set_prototype`
rejects foreign values, cycles and excessive chain depth. Prototype/accessor
edges participate in collection.

`js_runtime_set_host_hooks(rt, object, context, getter, setter)` installs
synchronous property callbacks. Both receive `(runtime, context, receiver, key)`;
the setter additionally receives the value. A null getter result or zero setter
result delegates to ordinary property lookup; a negative setter result rejects
the write. Returned values must belong to the instance. Callback contexts and
keys are borrowed; values retained only by native contexts need explicit roots.
Callbacks cannot collect or reenter evaluation and share depth/execution limits.

`js_runtime_host_callable` creates a callback with context, receiver and argument
list. `js_runtime_invoke_receiver` supplies an explicit receiver when invoking a
retained function; its ownership and budget contract matches `js_runtime_invoke`.
This supports browser event receivers without putting event scheduling in W.

Every AST visit consumes a step. Depth defaults to 256, live heap values to
100000, properties per object and UTF-16 units per string/key to 10000, retained
scripts to 1000, and source bytes per evaluation to 1048576. Configure
`max_depth`, `max_values`, `max_properties`, `max_scripts`, `max_source_bytes`
and `parse_limits` before evaluation. Parser limits include speculative work.
Value/property/string caps bound allocations independently of execution steps.
A limit abort returns control synchronously to an embedding event loop and
leaves prior side effects visible; it is not a resumable continuation.

Heap values are borrowed. The global environment and latest completion are
roots; retain additional host values with `js_runtime_root` and release them
with `js_runtime_unroot`. Root registration is idempotent, not reference-counted.
`js_runtime_collect` traces environments, closures and object edges iteratively
and reclaims unreachable cycles. Collection is permitted between evaluations
only; attempts from a callback return -1. The interpreter does not collect
mid-evaluation, so a heap limit can abort a long script even when intermediate
values are unreachable. Script ASTs stay owned until instance destruction,
bounded by `max_scripts`, ensuring closure bodies remain valid. The tests cover
cyclic collection, closure survival, realm isolation, host exceptions, execution
limits, and zero outstanding allocations after teardown.

## Promises and microtask checkpoints

`js_runtime_new` installs `Promise`, `Promise.resolve`, `Promise.reject`,
`Promise.prototype.then/catch`, and `queueMicrotask`. `new Promise(executor)`
calls its executor synchronously with resolve/reject functions. Settlement is
first-call-wins, including adoption of a pending native promise. Reactions run
as FIFO microtasks, propagate missing handlers, adopt returned native promises,
reject direct self-resolution, and turn handler/executor throws into rejections.

Hosts create pending promises with `js_runtime_promise_new(rt)` and settle them
with `js_runtime_promise_settle(rt, promise, value, rejected)`, where `rejected`
is zero for resolution and nonzero for rejection. Both values must belong to
that runtime. Host-retained pending promises need ordinary roots. Settlement
never invokes JavaScript. Pending reactions, queued jobs, captured resolvers,
and settlement values participate in collection.

Call `js_runtime_drain_microtasks(rt, budget)` at a host checkpoint, such as after
a script, event, or timer callback. Evaluation does not drain automatically.
The returned instance-owned completion replaces the prior completion, so inspect
or retain its value first. Reentry returns null. Draining charges one step per
job plus normal AST work and shares one budget across recursively queued jobs.
A thrown `queueMicrotask` callback stops the checkpoint with status 2; Promise
handler throws are converted to rejection. Resource limits remain status 5.
Unstarted jobs stay queued and rooted; a started job is not replayed after an
abort. As elsewhere, a limit abort can leave prior effects or promises pending.
`max_microtasks` defaults to 10000 queued jobs; `max_properties` also caps each
pending promise's reactions. Queue storage compacts consumed entries.
`js_runtime_clear_microtasks(rt)` cancels queued jobs between executions; it does
not remove reactions attached to still-pending promises.

This is a native-promise subset: arbitrary thenable assimilation, Promise
combinators/finally, subclass/species behavior, unhandled-rejection reporting,
async/await, and general constructor semantics are not implemented. In particular,
objects with a `then` property are currently fulfilled as ordinary objects.
Constructor syntax is lowered and printed as `construct` AST nodes, with tests
for member callees and trailing method calls.

## Preserve source during edits

`js_rewrite_module_specifiers(result, from, to, &length)` returns an owned edited
buffer. It matches decoded static specifiers and escapes replacement strings.
For general edits, use `js_source_edit_new(offset, length, replacement,
replacement_length)` and `js_source_edits_apply`. Overlapping, ambiguous
same-offset, and out-of-range edits fail explicitly. Free edits and output when
done. The original parse result is unchanged; reparse edited text for new spans.
The AST printer produces fresh formatting; source edits preserve untouched
comments and formatting.

## Qualification and current boundaries

```sh
./wbuild javascript_lexical_test javascript_parser_test javascript_validation_test \
  javascript_bindings_test javascript_restrictions_test javascript_ast_test \
  javascript_roundtrip_test javascript_transform_test javascript_text_test \
  javascript_runtime_test javascript_runtime_invoke_test javascript_runtime_promises_test javascript_browser_runtime_test \
  javascript_runtime_objects_test javascript_runtime_environments_test \
  javascript_standards_early_test javascript_conformance javascript_test262
./wbuild javascript_compatibility
# Native Apple Silicon equivalent, including generic runtime/importer gates:
tools/mac/run_javascript_tests.sh
```

The ordinary test targets require no Node installation. The explicit compatibility
target requires Node v20.19.3 and fails visibly if it is missing or differs. It
runs pinned Test262 syntax variants (respecting test metadata), a pinned real
source fixture, bounded growth cases, and controlled execution comparisons. Nine additional cases compare actual W runtime
completion values with fresh Node realms, covering arrows, per-iteration capture,
Unicode iteration, template cooking/number spelling, abrupt completions and TDZ.
It also executes the actual builder and transformer, checks their output with
both parsers, and compares original/transformed behavior and untouched bytes.
`bin/javascript-compatibility.json` records results. This small corpus is a
regression gate, not a Test262 pass-rate claim. It does not execute arbitrary
Test262 runtime tests or resolve their module graphs.

Vendored upstream grammars/base helpers and their hashes, license, 188-site
adaptation ledger, and strict-import blockers live under
`libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript/`. Compatibility
fixtures and provenance live under `tests/javascript/corpus/`.

The [native execution ledger](../../tests/javascript/conformance/README.md)
executes pinned local fixtures in W with exact expected-failure accounting and
separate parse, early-error, lowering and execution observations. It is not a
standards pass-rate claim. The separate [bounded Test262 runtime profile](../../tests/javascript/test262/README.md)
executes pinned upstream tests with native W assertion overrides and explicit
PASS/FAIL/UNSUPPORTED/ERROR results. Run `./wbuild javascript_test262` to save its
report to `bin/test262-conformance.json`. Its reviewed per-variant baseline fails
on unexpected support changes. Use
`bin/test262_conformance --require-all` to fail on every unsupported
variant as well. Full upstream harness and full-suite execution remain deferred.

Early-error checks include async/generator parameter expressions and duplicate
parameters, duplicate module export names, missing local exports, chained labels
and structural RegExp groups/assertions/quantifiers. Remaining work includes
RegExp escape values, class ranges, named captures/backreferences and Unicode
properties, complete ECMAScript early errors and cross-module export resolution,
Annex B behavior, and broader contextual keyword handling. Function-call
assignment targets are rejected; Node permits some of
these forms and defers their failure until execution. Sloppy-context uses of `await`/`yield` as identifiers are not generally
accepted outside label names. Label names have their own contextual checks, so
strict `eval`/`arguments` labels are valid while generator `yield`, async `await`,
and module-reserved labels are rejected. This integration does not support TypeScript, JSX, or post-ES2020 syntax
as a compatibility contract. Full-edition acceptance requires expanding the
pinned corpus and eliminating these exclusions before closing #492 as complete
ECMAScript compatibility.

Generic infrastructure and restrictions are documented in
[ParserGenerator](parser_generator.md): stateful mode is opt-in, lexer guards and
AST predicates must be pure, custom host state must participate in snapshots,
and stateful recovery/streaming and ANTLR `more` remain unsupported. Existing
eager grammars retain their generation behavior.
