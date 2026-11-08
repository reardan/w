# Bounded upstream Test262 execution

From the W repository root:

```sh
./wbuild javascript_test262 javascript_test262_upstream
bin/test262_conformance --json bin/test262-conformance.json
bin/test262_conformance --require-all
```

This target executes **unmodified upstream Test262 tests in W's x64 interpreter**,
with a new process and realm for each variant. Python supervises execution; Node
is not involved. The default target also runs the adapter's contract tests and writes the full
report to `bin/test262-conformance.json`. The wbuild targets split the two
profiles so they run in parallel: `javascript_test262` runs the native profile
(`--native-only`) and `javascript_test262_upstream` the upstream-harness profile
(`--upstream-only`, report in `bin/test262-upstream.json`); a bare
`bin/test262_conformance` still runs both. No
network access or third-party Python packages are needed to run it.

The corpus contains 1811 upstream test files (plus module fixtures) expanded
into 3550 variants. The native profile reports **3301 PASS, 0 FAIL, 249
UNSUPPORTED, 0 ERROR**; 2228 passes reach runtime execution and the rest verify
syntax and module-resolution errors. The upstream-harness profile (below)
reports **3066 PASS, 0 FAIL, 484 UNSUPPORTED, 0 ERROR (86.36%)**; the 452
property-escape variants (below) are UNSUPPORTED there because
`regExpUtils.js` is not pinned. The positive cases execute 9368 assertions
across strict/sloppy variants. 182 of the files are RegExp tests (reardan/w#839): pattern early
errors under `test/language/literals/regexp/` (escape values, class ranges,
quantifiers, lookbehind), its `named-groups/` negatives (duplicate, dangling,
incomplete and invalid group names), the `test/built-ins/RegExp/property-escapes/`
grammar negatives (unknown, loose or unsupported property names and values,
class ranges with property escapes), and literal matching tests for `u`-mode
escapes, astral characters, case mapping, surrogate pairs, sticky `^` and
forward named references. reardan/w#841 added `instanceof` and `switch` tests
(`test/language/expressions/instanceof/`, `test/language/statements/switch/`),
two module tests with their fixtures, and the `tcoHelper.js`/`compareArray.js`
includes. Tests that need `eval` or other harness includes
(`propertyHelper.js`, `regExpUtils.js`) were not vendored (the property-escape
files below use native `regExpUtils.js` overrides instead). These numbers describe this small selected corpus, **not full Test262
coverage or a browser standards pass rate**. The unsupported examples remain in
the report rather than being removed to improve the result.

### Classes (reardan/w#905)

912 of the files are the `test/language/statements/class/` and
`test/language/expressions/class/` tests that pass in both profiles once the
interpreter executes classes: declarations/expressions, accessors, static and
computed keys (`cpn-*`, `accessor-name-*`), method definitions and their
default/destructured parameters (`dstr/`, `method*/`), `subclass/`, `super/`,
`definition/`, `syntax/`, `elements/`, `subclass-builtins/` (Error subclasses
and syntax), and the class early errors, including the `gen-method*/` and
`async-method*/` negatives.
They were selected by running all 8426 class tests of the pinned revision;
the rest are left out because they need class fields, private names, static
blocks, generator/async methods, `propertyHelper.js`/`compareArray.js`, or
built-ins outside the bounded realm (`Object.prototype`, `Function.prototype.bind`,
`eval`, primitive wrapper and Array/Date/Map/... subclassing), or hit
non-class gaps (generator execution for `yield` in computed keys, numeric
separators, separate parameter scopes). The `class`, `computed-property-names`,
`new.target`, `default-parameters`, `rest-parameters`, `arrow-function` and
`destructuring-binding` feature tags are enabled for them.

### String and RegExp Symbol methods (reardan/w#902)

336 of the files are the `test/built-ins/String/prototype/{match,matchAll,
replace,search,split}/` and `test/built-ins/RegExp/prototype/Symbol.{match,
matchAll,replace,search,split}/` tests that pass in at least one profile with no
FAIL in either: Symbol dispatch, coercion order, `lastIndex` handling for
global/sticky RegExps, RegExpExec with user `exec`, GetSubstitution, species
construction, the RegExp String Iterator and result shapes. The `Symbol`,
`Symbol.iterator`, `Symbol.match`, `Symbol.matchAll`, `Symbol.replace`,
`Symbol.search`, `Symbol.species`, `Symbol.split`, `Symbol.toPrimitive`,
`String.prototype.matchAll` and `arrow-function` feature tags are enabled.
The native profile reports `assert.throws` and includes such as `compareArray.js`
as UNSUPPORTED; the upstream-harness profile passes most of those. Not pinned
(174 files): tests needing `propertyHelper.js`, `isConstructor.js`/`Reflect`,
`compareIterator.js`, other built-ins (`Number.prototype`, `Boolean`,
`Object.prototype`, `Function.prototype.bind`, `lastIndexOf`, `charAt`,
`Math.pow`, `eval`), the `arguments` object, global `this`, implicit `+`
coercion, `v`-flag or duplicate-named-group syntax, and tests of post-ES2020
algorithm changes (`matchAll` rejecting non-global RegExps, `Symbol.match`/
`Symbol.replace` reading `flags`, primitive arguments skipping `Symbol.*`
lookup; see "String and RegExp Symbol methods" in
`docs/projects/javascript.md`).

### Static semantics, module linking and Annex B (reardan/w#840)

109 of the files pin #840's static-semantics work: module linking negatives
under `test/language/module-code/` (`instn-*` indirect-export, named-import,
star-import and resolution-order failures, default-through-star, re-export
cycles and dependency syntax errors, with their `_FIXTURE.js` modules), the
module goal's HTML-like comment negatives, contextual `yield`/`await` tests
(`reserved-words/await-*`, `labeled/value-*`, generator, async and `await`
expression binding/reference/label cases), `__proto__` duplicates, `let` bound
names, `for-of` heads, IsLabelledFunction (`labelled-fn-stmt*` in if and loop
bodies), the optional-chain template early error, legacy octal and
NonOctalDecimal literals and escapes, and Annex B block, if-clause, switch and
labelled function declarations under `test/annexB/`. The pinned revision has no
ambiguous-star-export negative; `javascript_module_graph_test` covers that case.
Annex B tests that need `assert.throws`, global error constructors, the
`arguments` object or `new Test262Error()` were either left out or remain
UNSUPPORTED with their reason; generator and async bodies that the lowering
subset cannot run report UNSUPPORTED after parsing and early errors succeed.

Negative module tests (`flags: [module]` with a parse or resolution negative)
run: the supervisor writes the case under its upstream path with its pinned
sibling `_FIXTURE.js` files, and the runner links the graph with
`libs/extras/javascript/module_graph.w` after early errors. A link failure is a
`resolution` phase SyntaxError (or ReferenceError for an unloadable
specifier). Positive module tests remain UNSUPPORTED. The `async-functions`,
`generators` and `optional-chaining` feature tags are enabled; their runtime
support is still decided by lowering and preflight.

### Unicode property escapes (reardan/w#901)

226 files pin `test/built-ins/RegExp/property-escapes/generated/`: the files
whose Unicode 17.0 expectations agree with the Unicode 12.1 data the runtime
pins (see [javascript.md](../../../docs/projects/javascript.md), "Unicode version
pin", for the split and the 215 that differ). Each builds the strings of
matching and non-matching code points (up to 1.1M of them) with
`regExpUtils.js` and tests `/^\p{...}+$/u` and `/^\P{...}+$/u` against them.
INTERPRETING.md lets a host override harness functions, and the native profile
does: the runner's `buildString` keeps the code points host-side (the strings
exceed the runtime's string length cap) and its `testPropertyEscapes` runs the
RegExp's matcher over the whole string like `RegExp.prototype.test` and, if
that fails, over each symbol, failing the test when any symbol does not match.
That matching has its own step budget. The other `regExpUtils.js` helpers are
unsupported. In the upstream-harness profile these files stay UNSUPPORTED,
since `regExpUtils.js` is not pinned (the interpreter has no
`String.fromCodePoint` and its loops would exceed the step budget).

## Provenance

Every vendored file is byte-for-byte upstream Test262 revision
[`2e0a56762801e275a9fdf96dc49d90ba0cddcf63`](https://github.com/tc39/test262/tree/2e0a56762801e275a9fdf96dc49d90ba0cddcf63),
matching the existing syntax corpus's revision. `manifest.json` records source
paths and SHA-256 hashes. It includes the BSD `LICENSE`, upstream
`INTERPRETING.md`, and the `assert.js`/`sta.js` harness references. The supervisor
checks all pins, source containment, duplicate entries, and required provenance
before execution. Test files retain their original copyright notices.

## Upstream-harness profile

The default target runs a second pass, `upstream-harness-v1`, recorded under
`full_harness` in the report with its own counts, `execution_passes`,
`pass_rate` and per-variant results. The runner (`upstream` mode) evaluates the
pinned `harness/sta.js`, `harness/assert.js` and each declared include from
`upstream/harness/` unmodified in the test's realm before the test; a harness
script that fails is an ERROR (or UNSUPPORTED when it needs syntax outside the
runtime subset). Includes that are not pinned remain UNSUPPORTED. Module tests
are staged beside their pinned `*_FIXTURE.js` siblings and evaluated through
`libs/extras/javascript/modules.w` with a relative-path file resolver, so
loader limits (cycles, default/namespace imports) report UNSUPPORTED. A
runtime-negative `Test262Error` is identified by inheritance from the harness's
`Test262Error.prototype`, never by forgeable properties. This pass is not gated
by the native per-variant baseline; an ERROR in it fails the target, and the
contract test pins its counts. Its assertion count is 0 because assertions are
ordinary JavaScript calls. Pass `--native-only` to skip it.

## Explicit native harness profile

The profile is `native-boolean-samevalue-v1`. Upstream
[INTERPRETING.md](upstream/INTERPRETING.md) permits consumers to override harness
functions. This driver installs native W overrides for `assert`,
`assert.sameValue`, `assert.notSameValue`, and `$DONOTEVALUATE`; the pinned harness
JavaScript is a reference contract and **is not evaluated**. `assert` requires the
boolean value `true`, and SameValue distinguishes signed zero and equates NaN.
Assertion failures throw a distinct host Test262Error value. Diagnostic message
formatting, construction/prototypes of Test262Error, `assert.throws`, comparison
helpers, `$DONE`, `print`, and `$262` host operations are not implemented. Calls
to the installed unsupported helper stubs or missing assertion/host properties
produce UNSUPPORTED, never a passing no-op. Full harness-object introspection is
outside this profile. Constructor syntax now lowers, allowing unreachable
`new Test262Error` branches in the two newly passing short-circuit variants;
executing that constructor remains unsupported.

Manifest version 2 records built-in requirements for three hash-pinned addition
cases: `S11.6.1_A1` needs `eval`; `S11.6.1_A4_T1` and `S11.6.1_A4_T2` need
`Number` and `isNaN`. The adapter capability inventory does not yet advertise
these complete capabilities (the bounded Number helpers do not provide the
required Number constants or global `isNaN`), so those six variants report an explicit metadata UNSUPPORTED
reason before execution. This is a declared capability boundary, not an exception
filter: unknown identifiers and direct uses of missing built-ins still throw
ReferenceError and classify as FAIL. A regression test advertises all three
capabilities and verifies that execution exposes all six failures. Source bytes
and hashes are unchanged. The `instanceof` addition case now executes.

The native callbacks count real assertion invocations. Contract tests verify
both passing and failing assertion paths, signed zero, NaN, boolean strictness,
fresh realms, runtime error identity, syntax/runtime phase separation, malformed
runner output, crashes, timeouts, budgets, metadata, and source pins.

## Metadata and results

- Ordinary scripts run once unchanged and once with `"use strict";` prepended.
  `onlyStrict`, `noStrict`, and `raw` select their appropriate single variant.
  Raw scripts receive no harness bindings and no source prefix.
- Async tests, positive modules, includes, blocking/non-deterministic flags,
  and features outside the declared profile produce explicit UNSUPPORTED
  results. No missing include is silently ignored. Only the
  `coalesce-expression`, `regexp-named-groups`,
  `regexp-unicode-property-escapes`, `async-functions`, `generators`,
  `optional-chaining`, `arrow-function`, `String.prototype.matchAll`, `Symbol`,
  the `Symbol.*` tags listed above, `class`, `computed-property-names`,
  `new.target`, `default-parameters`, `rest-parameters` and
  `destructuring-binding` are currently enabled; untagged cases still
  undergo the interpreter's actual syntax/runtime support checks.
- A deliberately restricted frontmatter reader supports the inline/block
  sequences and negative mappings used here, plus descriptive block text.
  Unknown keys, duplicate metadata, conflicting flags, and unsupported YAML
  forms produce ERROR; this is not a general YAML parser or full-suite loader.
- Negative parse tests pass only for actual parser/early SyntaxError results.
  Runtime negatives require an uncaught exception at execution with the exact
  engine-issued error identity. Changing or inventing an object's `.name`
  cannot forge that identity. No error identity is inferred from message text.
- Unsupported lowering/execution stays UNSUPPORTED. Crashes, timeouts,
  malformed protocol results, and execution limits are ERROR, including for
  negative tests. A normal completion cannot pass a negative test.

The reviewed `baseline` in `manifest.json` names every variant and its expected
PASS or UNSUPPORTED status; every unsupported entry requires a concrete reason.
Missing/extra baseline entries and invalid reasons fail validation. Any status
change fails the gate, including PASS becoming UNSUPPORTED and newly supported
variants becoming PASS. Review the evidence and update the baseline deliberately
when implementing support; there is no automatic baseline update.

Reports always contain all four actual status counts, per-variant evidence, modes,
negative expectations, execution-pass counts, assertion counts, upstream
revision, profile, expected statuses and `baseline_changes`. Default exit status
0 means no FAIL/ERROR and no baseline changes in the selected profile; **it does not mean every variant passed**. Exit 1 indicates FAIL/ERROR, a baseline status change,
or UNSUPPORTED with `--require-all`; exit 2 indicates manifest/setup failure.
The strict `--require-all` command currently exits 1 by design. No xfail mask or
automatic baseline update exists.

`tools/test262_runtime_runner.w` uses the same generated parser, validators,
lowerer, and `js_runtime_eval` as the native ledger and browser embedding.
Keep its parser/validator observation sequence synchronized with `js_parse`.
Its step budget defaults to 100,000; the supervisor also enforces a ten-second
wall-clock timeout per variant. This adapter is a foundation for extending
coverage as the runtime and harness capabilities grow.
