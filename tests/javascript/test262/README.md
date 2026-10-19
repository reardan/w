# Bounded upstream Test262 execution

From the W repository root:

```sh
./wbuild javascript_test262
python3 tools/test262_conformance.py --json bin/test262-conformance.json
python3 tools/test262_conformance.py --require-all
```

This target executes **unmodified upstream Test262 tests in W's x64 interpreter**,
with a new process and realm for each variant. Python supervises execution; Node
is not involved. The default target also runs the adapter's contract tests and writes the full
report to `bin/test262-conformance.json`. No
network access or third-party Python packages are needed to run it.

The selected corpus contains 77 upstream files expanded into 151 variants:
**118 PASS, 0 FAIL, 33 UNSUPPORTED, 0 ERROR**. Of those passes, 109 reach runtime
execution (including eight genuine ReferenceError negatives) and nine verify
syntax errors. Positive cases execute 325 native assertions across strict/sloppy
variants; older upstream cases also use conditional throwing checks. These
numbers describe this selected corpus, **not full Test262 coverage or a browser
standards pass rate**. Unsupported examples remain in the report.

The modern-browser expansion adds Array construction/identity and `isArray`,
`some` callback arguments/short circuiting/mutation, function `call`/`apply`/`bind`,
addition and bitwise operand/coercion order, and conditional branch behavior.
Adjacent cases explicitly retain unsupported numeric object-literal property
names, array literal elisions, sloppy mapped arguments, Object reflection,
Reflect/new.target, and the broad BigInt feature tag. Runtime tests separately
exercise supported generic slice/array-like operations through the embedding
API; the pinned slice case here requires the unavailable Object global.

The array-iteration expansion adds sixteen files for map/filter/every/forEach,
forward/reverse reduction and find/findIndex callback arguments and empty inputs.
Twenty new variants pass. Twelve adjacent variants explicitly retain unsupported
array literal elisions, property deletion or sloppy mapped arguments; existing
passes and expected statuses remain unchanged.

## Provenance

Every vendored file is byte-for-byte upstream Test262 revision
[`2e0a56762801e275a9fdf96dc49d90ba0cddcf63`](https://github.com/tc39/test262/tree/2e0a56762801e275a9fdf96dc49d90ba0cddcf63),
matching the existing syntax corpus's revision. `manifest.json` records source
paths and SHA-256 hashes. It includes the BSD `LICENSE`, upstream
`INTERPRETING.md`, and the `assert.js`/`sta.js` harness references. The supervisor
checks all pins, source containment, duplicate entries, and required provenance
before execution. Test files retain their original copyright notices.

## Explicit harness profile

The profile is `native-assertions-async-v2` (expanded from `native-boolean-samevalue-v1`). Upstream
[INTERPRETING.md](upstream/INTERPRETING.md) permits consumers to override harness
functions. This driver installs native W overrides for `assert`,
`assert.sameValue`, `assert.notSameValue`, and `$DONOTEVALUATE`; the pinned harness
JavaScript is a reference contract and **is not evaluated**. `assert` requires the
boolean value `true`, and SameValue distinguishes signed zero and equates NaN.
Assertion failures throw a distinct host Test262Error value. Diagnostic message
formatting, construction/prototypes of Test262Error, comparison
helpers, `print`, and `$262` host operations remain unsupported. `assert.throws`
executes its callback and compares real constructor identity. Async scripts use
`$DONE` and a fuel-bounded Promise/microtask drain; see the expansion below. Calls
to the installed unsupported helper stubs or missing assertion/host properties
produce UNSUPPORTED, never a passing no-op. Full harness-object introspection is
outside this profile. Constructor syntax now lowers, allowing unreachable
`new Test262Error` branches in the two newly passing short-circuit variants;
executing that constructor remains unsupported.

Manifest version 2 records built-in requirements for four hash-pinned cases:
addition `S11.6.1_A1` needs `eval`; `S11.6.1_A4_T1` and `S11.6.1_A4_T2` need
`Number` and `isNaN`; slice `create-non-array` needs `Object` reflection. The
adapter advertises the selected Object reflection requirement, but not the other capabilities (bounded Number helpers
lack the required constants/global `isNaN`), so six variants report explicit
metadata UNSUPPORTED reasons. This is a declared capability boundary, not an
exception filter: unknown identifiers and direct uses of missing built-ins
still throw ReferenceError and classify as FAIL. A regression test advertises
all four capabilities and verifies that execution exposes all six remaining failures.
Source bytes and hashes remain unchanged.

The native callbacks count real assertion invocations. Contract tests verify
both passing and failing assertion paths, signed zero, NaN, boolean strictness,
fresh realms, runtime error identity, syntax/runtime phase separation, malformed
runner output, crashes, timeouts, budgets, metadata, and source pins.

## Metadata and results

- Ordinary scripts run once unchanged and once with `"use strict";` prepended.
  `onlyStrict`, `noStrict`, and `raw` select their appropriate single variant.
  Raw scripts receive no harness bindings and no source prefix.
- Modules/resolution, includes, blocking/non-deterministic flags,
  and features outside the declared profile produce explicit UNSUPPORTED
  results. No missing include is silently ignored. Only the
  `coalesce-expression` feature tag is currently enabled; untagged cases still
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

## Phase 1 native harness expansion (2026-10-19)

Profile `native-assertions-async-v2` preserves the earlier strict boolean/SameValue
assertions and adds real `assert.throws` callback execution with constructor
identity, plus `$DONE` and Promise/microtask execution for async scripts. The
same total fuel covers evaluation and the microtask drain. Limits cannot be
caught as an assertion success. Missing completion is ERROR; duplicate `$DONE`
and `$DONE(error)` fail even when called inside a Promise reaction. Realms are
still fresh processes. Modules, realm creation, timers and arbitrary upstream
includes remain unsupported; the original assert.js/sta.js files are still
reference contracts, not executed harness source. Async support is not a claim
of complete Promise semantics.

The selected corpus now adds all three upstream empty-input Promise.all tests
(A2.3_T1–T3) unchanged. The existing array slice Object-descriptor requirement
is promoted only after its real execution passes with A's Object implementation.
Current selected expectation is 77 files / 151 variants: 118 PASS and 33
UNSUPPORTED (109 runtime passes, 325 native assertions). The prior profile recorded 110 PASS/35 UNSUPPORTED before these changes. Default exit 0 still allows explicit unsupported
results; `--require-all` remains nonzero until they are implemented.

`inventory.json` records the complete pinned upstream archive: 57,013 regular
files and 53,616 JavaScript test candidates after `_FIXTURE` exclusion. Each
report retains the selected and unselected file counts, independently from
executed variants. Full-suite applicability and variant expansion are not yet
known and are recorded as null, never replaced by the small selected denominator.
Reports include fresh UTC timestamps, both repository SHAs and the executed
runner's SHA-256. Source revision evidence does not imply a clean worktree or
that the binary was rebuilt from those revisions.

To audit complete families, obtain the exact archive URL in `inventory.json`
and check its SHA-256, then run for example:

```sh
python3 tools/test262_conformance.py --archive /path/to/test262.tar.gz \
  --family test/built-ins/Object/create/ \
  --family test/built-ins/Object/getOwnPropertyDescriptor/ \
  --family test/built-ins/Reflect/get/ --family test/built-ins/Reflect/set/ \
  --require-all --json bin/test262-object-families.json
```

This enumerates every non-fixture JS file in each directory from the pinned
archive, with no favorable-case selection or expected-status mask. Unsupported
metadata/includes/features and genuine runtime failures remain reported. Unknown
metadata remains ERROR, and makes the expanded variant denominator unknown;
all source files still remain in the report. The normal selected regression
profile stays separate. The application tool `win/tests/wpt_inventory.py` can
reproduce the archive and full sorted file/hash index; `inventory.json` pins both
archive and index hashes. Ordinary runs remain offline.
