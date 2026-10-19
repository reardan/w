# Native ECMAScript execution ledger

Run from the W repository root:

```sh
./wbuild javascript_conformance
bin/javascript_conformance --json bin/javascript-conformance.json
```

The build target compiles the generated parser and the x64 W interpreter driver,
executes this pinned native corpus, then runs the Python runner's contract tests.
Python 3.9+ is required. Node, downloads and external harness libraries are not
required. Every case uses a new process and a new realm. The CLI can also execute
one file: `bin/javascript_runtime_runner FILE script 10000`.

These 36 locally authored audit fixtures are **not Test262 tests**. Each carries
a normative ECMA-262 section reference, a SHA-256 source pin and an independent
expected result. The integrated baseline expects 36 passes (25 execution cases and
11 syntax negatives), with no expected failures.
This is a regression baseline,
not an estimate of standards coverage. The separate 18-file vendored Test262
corpus and `javascript_compatibility` remain a syntax differential gate; their
Node execution examples do not establish W execution conformance.

## Protocol and policy

JSON protocol 1 records the furthest observation boundary: `parse`, `early`,
`lower`, or `execute`. The W driver uses the existing generated parser, records
syntax acceptance before running the same validators as `js_parse`, then probes
AST lowering and executable-subset support. Actual execution calls
`js_runtime_eval`. It deliberately does not implement an alternative parser or
interpreter. Keep its validator sequence synchronized with `js_parse`.

Outcomes are `normal`, `error` (syntax), `throw`, `unsupported`, or `limit`.
The Python supervisor separately reports `crash`, `timeout`, and `harness_error`
at the process boundary. Runtime error objects/types are not synthesized from
message strings. Native thrown values are compared directly; runtime error names
are asserted by JavaScript reading the runtime-provided error object. Numbers use
lossless decimal strings (including signed zero and non-finite values); strings
use UTF-16 code-unit arrays, preserving NUL and unpaired surrogates.

- `PASS`: normative result matches. Only cases reaching execution contribute to
  `execution_passes`; successful syntax negatives are counted separately.
- `XFAIL`: the normative result fails and the documented observed fingerprint
  matches. Each entry names a bug/feature and its reason. An unsupported stage
  remains visible in `outcomes`, never becoming a conformance pass.
- `XPASS`: a known failure now meets the normative expectation. This fails the
  gate until a reviewer removes its obsolete `xfail` record.
- `FAIL`: an unexpected semantic result or changed known failure. This includes
  resource limits unless the case explicitly expects that limit.
- `ERROR`: timeout, crash, malformed driver output or harness failure. These
  cannot be hidden by an expected-failure record.

Exit status is 0 for a fully accounted baseline (PASS/XFAIL), 1 for FAIL/XPASS/
ERROR, and 2 for invalid manifest/setup. No automatic baseline update exists.
When a fix advances only one stage, inspect that new result before
updating its fingerprint. Do not remove the normative expectation.

The manifest reader rejects unknown metadata, unpinned source changes, escaped
paths, duplicate ids, invalid budgets, malformed expected values and unsupported
suite kinds. Full reports include both expectations and observations and grouped
phase/outcome counts. Contract tests cover real execution, fresh realms, phase
separation, budget exhaustion, metadata failures, changed failures, XPASS,
crashes and timeouts.

## Separate bounded upstream adapter

The [Test262 runtime profile](../test262/README.md) executes a separately pinned
upstream corpus using native W assertion overrides, strict/sloppy variants, and
phase/type-checked negatives. Run `./wbuild javascript_test262` to save its report
to `bin/test262-conformance.json`. The profile explicitly reports unsupported
includes, async/module tests and unsupported runtime/harness features; its
reviewed per-variant baseline rejects unexpected changes in support.

This native ledger remains a distinct locally authored regression suite; the two
result totals must not be combined into a Test262 pass-rate claim. A
`kind: test262` manifest or Test262 flags/includes metadata is still an explicit
harness error in this native runner. Full harness execution and full-suite
coverage remain deferred, and the licensed syntax corpus remains unchanged.

CSS computed-style/geometry fixtures belong to Win's CSS implementation track;
this target measures only the W JavaScript engine.

## Front-end checkpoint

Async/generator parameter expressions and duplicate parameter names, duplicate
module export names and undeclared local exports now have early-error checks.
Exports are checked after all module bindings are collected, including imports
and hoisted var declarations. Reexports do not require a local binding. Chained
iteration labels and escaped label names validate, lower, print and execute.
The execution fixtures cover nested labelled continue, finally overriding a jump,
labelled completion values and escaped target names. Additional cases cover
chained for-of iteration, continue overriding break in a finalizer, preservation
of a labelled completion through a normal finalizer, and early rejection of
continue to a non-iteration label or jumps across a function boundary.

RegExp literals now pass a structural Pattern grammar validator that handles
group/assertion nesting, escape and character-class boundaries, quantifier
placement, unbounded decimal bounds, lazy quantifiers and legacy non-Unicode
quantified lookahead. This is still an ES2020 syntax slice. Full escape-value,
character-class range, named-capture/backreference and Unicode-property early
errors remain unimplemented; this does not add RegExp execution or newer flags.
Positive and negative fixtures in `standards_early_test.w` exercise these
boundaries, including nested functions in parameter initializers.
