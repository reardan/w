# JavaScript parsing, building, and transforming

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

The facade supports simple variables, functions/parameters, blocks, return,
throw, if, expressions, calls/members, dense arrays, ordinary named/string-keyed
objects (including distinct shorthand properties), templates, simple imports,
and exported declarations. Lowering preserves escaped non-directive strings so
printing cannot accidentally introduce a strict-mode directive. Parsing is
broader: lowering intentionally rejects classes, arrows, async/generator
functions, destructuring, rest/default parameters, `new`, optional chains,
computed/numeric/method object properties, and richer module declarations.
Node shapes are documented in `libs/extras/javascript/printer.w` and exercised
in `tests/javascript/roundtrip_test.w`. Decoded text uses W's `char*` convention;
NUL and lone-surrogate string values are diagnosed instead of silently truncated.
The concrete tree retains their original spelling.

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
  javascript_roundtrip_test javascript_transform_test
./wbuild javascript_compatibility
# Native Apple Silicon equivalent, including generic runtime/importer gates:
tools/mac/run_javascript_tests.sh
```

The ordinary test targets require no Node installation. The explicit compatibility
target requires Node v20.19.3 and fails visibly if it is missing or differs. It
runs pinned Test262 syntax variants (respecting test metadata), a pinned real
source fixture, bounded growth cases, and controlled execution comparisons.
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
