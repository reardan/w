# ANTLR runtime differential fixtures

`./wbuild antlr_differential_test antlr_differential_harness_test` runs W against
committed ANTLR 4.13.2 observations without Java or network access. The manifest
pins grammar and driver bytes, the reference jar checksum, start rules, explicit
stateful translation, and input text. Small original regression grammars are supplemented by unmodified pinned
upstream corpora; each corpus case records its upstream paths and hashes and
retains its original license header.

The separate `pinned-runtime-oracle` CI job uses Java 17 and a checksum-verified
ANTLR jar to generate and compile Java and execute every input against the
snapshots. Local live verification records the actual Java/Javac versions and
requires Java 17 or newer:

```
python3 tests/antlr_differential.py --jar /path/to/antlr-4.13.2-complete.jar
```

The runner never downloads or silently skips an unavailable oracle. Ordinary
runs cannot change snapshots. Reviewed snapshot regeneration requires both
`--jar` and `--oracle-only --refresh-snapshots`.

Observations compare zero-error recognition with complete input consumption,
symbolic token names, UTF-8 byte spans, source spelling and channels.
Zero-span named EOF tokens normalize ANTLR's synthetic `<EOF>` text to empty
source spelling. User channels normalize to their declared names, preserving
PG's distinct reserved error-channel number. W's retained
`skip` trivia is removed by explicitly named token identities; hidden-channel
comments remain observable. Selected AST rule names and spans check ambiguity
selection and dangling-else grouping, without comparing generated helper trees.
No claim of full ANTLR context/listener API compatibility follows from this gate.

Known incompatibilities name the exact differing fields and their causes in the
manifest. New differences fail, and an unexpected fix fails until the ledger is
updated. A valid ANTLR input remains valid even when W currently rejects it.
`--exact` enables both opt-in backends and requires every witness to match; the
normal build target runs both legacy and exact paths. `--require-compatible` removes allowances; `--translator-flag=--prediction` and
`--translator-flag=--exact-lexer` exercise opt-in backends. `--case NAME` limits a
run to one or more grammar families.

The token family includes 24 bounded generated/mutated inputs from seed
689690692. The harness verifies the stored inputs against the versioned recipe;
all observations remain reviewable. These are deterministic regression cases,
not an unbounded fuzzing claim.

Every run creates a fresh artifact directory under `bin/antlr_differential/`
(or an empty explicit `--work` directory). `results.json` separates configured
and completed inputs, known mismatches, generation/compilation/execution stages,
reference provenance and tool hashes. Logs include per-input wire observations.
Crashes, timeouts, unavailable tools and missing artifacts are failures.

EOF fixtures check that a consuming match reaching EOF suppresses a later named
EOF token, while a pending `more` sequence may still finish with an EOF rule in
the same call. Malformed custom-channel input checks that recovery skips the failed transition
endpoint before resuming tokenization.

`STRICT_RECLASSIFICATIONS.json` records five historically strict-accepted grammars
with confirmed counterexamples. Their unmodified pinned sources, entry rules,
inputs and snapshots are checked offline and against the live Java oracle.
SPASS deliberately exercises its public `term` entry; the other four use their
original grammar entry. Explicit implicit-literal name mappings reconcile W's
`KW_IF` spelling with ANTLR's `'if'` vocabulary identity without hiding token
text, channel or span differences. These records support per-case baseline
review; they do not automatically remove historical sweep expectations.
