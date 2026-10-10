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
by `python3 tools/javascript_unicode.py --check`. Comments retain line-break
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
lexical `for-of`, unlabelled
break/continue, try/catch/finally, expressions, assignments and prefix/postfix
updates, calls/members, dense arrays, ordinary named/string-keyed
objects (including distinct shorthand properties), templates, simple imports,
and exported declarations. Lowering preserves escaped non-directive strings so
printing cannot accidentally introduce a strict-mode directive. Parsing is
broader: lowering intentionally rejects classes, async/generator
functions, destructuring, rest/default parameters, `new`, optional chains,
computed/numeric/method object properties, and richer module declarations.
Node shapes are documented in `libs/extras/javascript/printer.w` and exercised
in `tests/javascript/roundtrip_test.w`. Additional shapes are:

| Kind | Text | Ordered children |
| --- | --- | --- |
| `while`, `do_while` | empty | condition, body |
| `for` | empty | initializer, condition, update, body |
| `break`, `continue` | empty | none |
| `function_expression` | optional name | parameters, block |
| `arrow` | empty | parameters, expression or block |
| `for_of` | `let` or `const` | identifier, iterable expression, body |
| `try` | empty | block, catch or empty, finally block or empty |
| `catch` | optional identifier | block |
| `string_utf16` | empty | none; value in `string_units` |

An omitted for clause/catch/finally uses an `empty` node with offset -1;
source-backed nodes preserve byte spans. `for-in`, assignment-target/`var` for-of bindings, labelled jumps and
catch destructuring remain explicit lowering failures. The printer handles
loop bodies when protecting against a dangling `else`.

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
instance-owned and overwritten by the next evaluation:

| Status | Meaning |
| --- | --- |
| 0 | normal; value of the final statement (declarations produce undefined) |
| 2 | thrown value or runtime error; diagnostic in `message` |
| 5 | execution, parser or allocation limit; terminal for this evaluation |
| 6 | syntax/operation outside the implemented subset |

Statuses 1, 3 and 4 are internal return/break/continue completions. User-thrown
values and host exceptions are catchable. Runtime errors currently carry an
undefined value and a diagnostic message, rather than Error-prototype objects.
Resource/unsupported failures cannot be caught and do not execute finalizers.
Normal return/throw/break/continue completions do execute `finally`, and an
abrupt finalizer overrides the earlier completion.

The initial semantic subset is deliberately explicit:

- Undefined, null, booleans, binary64 decimal numbers, UTF-16 strings; truthiness,
  strict equality (including NaN), numeric `+ - * /` and comparisons, string
  concatenation, `!`, numeric unary `+ -`, `void`, `typeof`, `&& || ??`, comma and ternary.
  `typeof` returns `undefined` for missing names while preserving TDZ failures.
- `let`/`const` with temporal dead zones and immutable bindings, lexical blocks,
  hoisted ordinary function declarations within each block, named/anonymous
  function expressions, synchronous arrows with simple parameters and expression
  or block bodies, recursive calls, captured mutable environments and
  per-iteration `for (let ...)` environments.
- Dense array literals, bounded index writes and readable `length`; plain data
  objects, shorthand properties, dot/computed property access and mutation.
  String length/indexing use UTF-16 code units.
- Lexical `for (let/const name of value)` over arrays and strings. Arrays read
  their live length each iteration; holes yield undefined. Strings iterate Unicode
  code points, preserving lone surrogates. Each iteration creates a fresh binding
  for captured closures; the iterable expression sees the binding in its TDZ.
- Cooked templates normalize raw CR/CRLF, decode escapes into UTF-16, and
  interpolate undefined, null, booleans, numbers and strings. Number spelling uses
  JavaScript decimal/exponent thresholds, including negative zero, NaN and infinity.
  Substitutions execute once in source order; object conversion remains unsupported.
- `= += -= *= /=`, prefix/postfix `++ --`, if/while/do/for, unlabelled
  break/continue, return, throw and try/catch/finally.

Unsupported syntax is rejected before execution, including `var`, modules,
classes, generators/async, `this`, regex execution, tagged templates, `new`,
destructuring, prototype-literal `__proto__`, loose equality, bitwise operators
and additional numeric operators. Custom iterators, default/rest/destructured
arrow parameters, implicit operator coercions, prototype chains,
accessors, standard built-ins, array length writes and exotic property-key
conversions are also outside this subset and report unsupported status when
encountered. Objects expose only their own data properties. Function declarations
are lexical bindings and duplicate declarations across evaluations fail. These
boundaries are not claims of complete ECMAScript semantics; #492 remains the
broader syntax/conformance track. Arrows capture the lexical environment;
`this`, `super` and ordinary functions’ implicit `arguments` object are not yet
implemented. No DOM, task queue, module loader or browser authority is installed.

`js_runtime_bind(rt, name, callback)` installs a host function. Its W signature
is `fn(void*, list[js_value*]) -> js_value*`; cast the context to `js_runtime*`.
Arguments and their list are borrowed for the callback, and the callback must
return a value owned by this same instance. Use `js_runtime_number`,
`js_runtime_boolean`, `js_runtime_string` or the instance's `undefined_value`.
`js_runtime_throw` supplies a thrown value. `js_runtime_get/set` provide UTF-8
host property names; `js_runtime_property/put` accept explicit UTF-16 keys.
Foreign-instance values are rejected. Host code must cooperate with its own
cancellation/deadlines; the interpreter cannot preempt native code. Recursive
evaluation of the same instance returns null.

`js_runtime_invoke(rt, callback, arguments, step_budget)` invokes a retained
script or host callback synchronously, using the same completion and execution
limits as evaluation. This gives an external browser event loop a way to dispatch
native event data without constructing JavaScript source. It validates instance
ownership for the callable and each argument, and rejects recursive invocation
of the same instance with null. The argument list and values are borrowed during
the call; retain handlers across collection with `js_runtime_root`. Invocation
retains no new script and does not consume `max_scripts`. Host callbacks still
must cooperate with cancellation. An argument count above `max_properties`
returns status 5.

[`examples/javascript/events.w`](../../examples/javascript/events.w) retains an
arrow handler, performs collection, and dispatches a plain event object whose
result is formatted by a template. Run `./wbuild javascript_events_example`.
The host owns scheduling, event schemas and the exposed capabilities.

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
  javascript_runtime_test javascript_browser_runtime_test
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

Remaining compatibility work includes full regular-expression pattern validation
(the lexer validates boundaries and flags), complete ECMAScript early errors and
module export resolution, Annex B behavior, and broader contextual keyword
handling. Function-call assignment targets are rejected; Node permits some of
these forms and defers their failure until execution. Sloppy-context uses of `await`/`yield` as identifiers are not generally
accepted. This integration does not support TypeScript, JSX, or post-ES2020 syntax
as a compatibility contract. Full-edition acceptance requires expanding the
pinned corpus and eliminating these exclusions before closing #492 as complete
ECMAScript compatibility.

Generic infrastructure and restrictions are documented in
[ParserGenerator](parser_generator.md): stateful mode is opt-in, lexer guards and
AST predicates must be pure, custom host state must participate in snapshots,
and stateful recovery/streaming and ANTLR `more` remain unsupported. Existing
eager grammars retain their generation behavior.
