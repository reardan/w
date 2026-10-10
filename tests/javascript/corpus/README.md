# JavaScript compatibility corpus

Run the dedicated target after building the inspector:

```sh
./wbuild javascript_compatibility
# Native Darwin equivalent:
python3 tools/javascript_compatibility.py --parser bin/javascript_inspect_darwin
```

This requires Python 3 and **Node v20.19.3**, pinned in `manifest.json`. A
missing parser, missing Node, wrong version, changed source hash, unsupported
metadata, timeout, or oracle disagreement fails the command. Normal runs never
fetch data. The JSON report defaults to `bin/javascript-compatibility.json`.

The manifest vendors 18 unmodified Test262 files at commit
`2e0a56762801e275a9fdf96dc49d90ba0cddcf63`, with the upstream BSD license and
individual SHA-256 hashes. This is a deliberately small syntax regression
subset covering nullish-coalescing restrictions, nested templates, regex
boundaries, optional chaining, exponentiation, strict assignment targets,
destructuring and module exports. It is not a Test262 conformance claim.

The runner reads each original Test262 frontmatter block. Default script tests
run in both sloppy and strict mode; `onlyStrict`, `noStrict`, `module` and
`raw` select the appropriate variants. `generated` is recognized as provenance.
Unknown flags/formats fail instead of silently changing the test meaning.
Parse/early-error negatives must reject with a syntax error; runtime and
resolution expectations are separate from syntax acceptance. Test262 harness
code is only parsed. Module imports are not resolved or executed.

A pinned MIT-licensed real source, `is-number` v7.0.0, is included under `real/`
with its source revision, URL, license and hashes. Three small controlled
programs separately check Node execution results for division/exponentiation
associativity and nested interpolation; no external corpus code is executed.

The report lists each source/mode/expectation and both parser results, time and
peak resident memory measured per child with POSIX `wait4`. Increasing complete
programs of 16, 64 and 256 declarations expose growth across input sizes. These
figures include process startup and are measurements, not machine-independent
performance thresholds. The report preserves disagreements and diagnostic
text; exclusions are printed with their reasons and never counted as passes.

Before any corpus work, the runner verifies all pinned ANTLR grammar/base-class
hashes and every exact source anchor in the checked-in `ADAPTATIONS.json` ledger.
An upstream source change therefore requires explicit review before a report
can pass. Native grammar generation remains a reviewed hand adaptation; the
ledger does not imply that `antlr_to_pg` can automatically translate host code.
