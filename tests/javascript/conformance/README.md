# Native ECMAScript execution ledger

Run from the W repository root:

```sh
./wbuild javascript_conformance
python3 tools/javascript_conformance.py --json bin/javascript-conformance.json
```

The build target compiles the generated parser and the x64 W interpreter driver,
executes this pinned native corpus, then runs the Python runner's contract tests.
Python 3.9+ is required. Node, downloads and external harness libraries are not
required. Every case uses a new process and a new realm. The CLI can also execute
one file: `bin/javascript_runtime_runner FILE script 10000`.

These 22 locally authored audit fixtures are **not Test262 tests**. Each carries
a normative ECMA-262 section reference, a SHA-256 source pin and an independent
expected result. The initial ledger has six passes (four execution cases and two
syntax negatives) and sixteen known failures. This is a regression baseline,
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
message strings. Currently native thrown values are compared directly; typed
runtime-error assertions need the runtime's error-object support. Numbers use
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
When a fix advances only one stage (for example an early-error correction makes
chained labels reach an unsupported lowerer), inspect that new result before
updating its fingerprint. Do not remove the normative expectation.

The manifest reader rejects unknown metadata, unpinned source changes, escaped
paths, duplicate ids, invalid budgets, malformed expected values and unsupported
suite kinds. Full reports include both expectations and observations and grouped
phase/outcome counts. Contract tests cover real execution, fresh realms, phase
separation, budget exhaustion, metadata failures, changed failures, XPASS,
crashes and timeouts.

## Deferred upstream adapter

A real Test262 adapter must pin the upstream revision and harness files, expand
strict/sloppy variants, honor includes and raw/async/module flags, implement
assertions, `$DONE` and host hooks, and compare negative error type and phase.
None of those harness capabilities is claimed by this native runner. A
`kind: test262` manifest or Test262 flags/includes metadata is an explicit harness
error rather than an implicit skip or a passing result. Keep the existing
licensed syntax corpus unchanged until that adapter can honor its contracts.

CSS computed-style/geometry fixtures belong to Win's CSS implementation track;
this target measures only the W JavaScript engine.
