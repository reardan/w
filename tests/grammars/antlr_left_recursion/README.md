# Left-recursion Wave 0 evidence

This is the immutable starting inventory for issue/PR #710. It changes no W
acceptance expectations and promotes no corpus baseline. The 21 original roots
contain 25 refused rules and are copied byte-for-byte from grammars-v4 commit
`89fd36482e8cb68a4e55df021a8adbc7541b52f2`, with their embedded license notices intact. Original trailing whitespace and blank
lines are intentionally preserved to keep those byte hashes unchanged.
`manifest.json` pins every source hash and records the historical W findings at
`b1887a858969ba341fb1449793dfd69ed4113677`. Thirteen roots had only left-recursion
findings; eight also had other findings. Shape hypotheses are marked as inferences,
not explanations established by the historical generic diagnostic.

`current_refusals.json` separately records the newly instrumented actual guard
exits for every refused rule, along with the original source plan/graph and
remaining graph. `normalization_guards` names the expression/list normalizer,
stable reason code and original source alternative (0 for a rule-wide guard).
These are observed first guard exits, not inferred root causes or proof that fixing
one guard is sufficient. The report records its measured translator binary hash
and clean source revision `fe55c0df9091e24e6f4aa89e1a8aa00f4bb71405`. All 21 failures preserved an existing output sentinel.

`snapshots.json` records independently observed ANTLR 4.13.2 results. Both `java`
and `javac` were checked as major 17 (OpenJDK 17.0.20.1). All 21 roots generated;
15 compiled with Java 17. AWK, Eiffel, GVPR, Kirikiri-TJS, Rust and Z generated Java
that cannot compile with only the grammar inputs and ANTLR runtime: their host
support is absent. Compiler diagnostics are retained, not rewritten as successful
runtime tests. **No original upstream parser was executed.** Minimal fixtures are
separately attributed runtime evidence, not upstream runtime coverage.

Each original rule records all source alternatives with original locations, labels,
actual ANTLR walker classification, precedence, association, and rewritten text.
The alternatives array follows transformed decision order (primary alternatives,
then recursive decisions); `source_alt` retains original identity. Owner references
carry their original AST child path, source token index and actual rewritten
binding; `removed_left_operand` identifies the stripped recursion operand. An
ordinary retained call has binding 0. An alternative's numeric `precedence` is the
analyzer's `N - source_alt + 1`, not a claim that an `other` primary has an implicit
binding constraint. `next_precedence` and each occurrence's binding preserve that
distinction.

`Inspect.java` subclasses the pinned ANTLR tool and analyzer. The observations do
not use the W classifier. The reference shows binary decisions before suffix
decisions, even when their original alternatives interleave. In PeopleCode,
options at the beginning of nested group alternatives are silently ignored and
outer operators remain left associative. The separate `NestedAssoc`,
`MisplacedAssoc`, `AttachedAssoc`, and `RightAssoc` fixtures distinguish that case
from terminal-option warnings, rejected recursive-reference options, and a proper
right-associative outer alternative. Plucid's original generation emits 12
unreachable-token warnings; all other original roots generate without warnings.

The 13 minimized fixtures cover adjacent operands, omitted separators, grouped and
optional/repeated owner references, guarded primaries, competing suffix/binary
operators, option placement, nullable bases, and direct/mutual/stationary negative
cases. Nine generated fixtures execute 33 positive and negative inputs. Their
canonical context/operand trees preserve nesting, context labels and terminal
text, so association can be inspected independently of token acceptance. They do
not yet compare W trees, spans, label fields or reconstruction; those are later
implementation gates. The negative fixtures preserve ANTLR diagnostic codes.

`original_graph.json` comes from the maintained W diagnostic tool
`tools/antlr_parser_progress_inventory.w`, initially commit `72578a81`. It analyzes
the original, unnormalized grammar, retaining every rule's nullability,
productivity, nullable-prefix edges and cycle witnesses. All 21 analyses completed;
none has a multi-rule nullable-prefix SCC. This observation does not prove progress
of a future lowering. The largest analysis uses 71,769 units of its 1,000,000-unit
budget (GQL). The graph can be reproduced independently of Java.

## Commands

Normal offline tests never download tools or modify snapshots:

```sh
python3 tests/antlr_left_recursion_oracle.py
python3 tests/antlr_left_recursion_oracle_test.py
python3 tests/antlr_left_recursion_refusals.py --tool bin/antlr_to_pg
```

To reproduce the original graph, build the maintained inventory driver and pass its
path (the integrator owns build target wiring):

```sh
python3 tests/antlr_left_recursion_oracle.py --progress-tool bin/antlr_parser_progress_inventory \
  --plan-tool bin/antlr_precedence_plan_test
```

Live reference verification requires a locally supplied jar with SHA-256
`eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76` and both Java tools
on PATH. It generates and compiles originals and executes minimal fixtures, compares all stable
results to committed snapshots, and writes an external provenance/artifact directory:

```sh
PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:$PATH \
  python3 tests/antlr_left_recursion_oracle.py --jar /path/antlr-4.13.2-complete.jar \
  --work /tmp/empty-lr-reference-directory
```

The separate refusal runner requires `--refresh` to replace its measured report;
ordinary runs compare every original finding and check atomic output preservation.

Only an explicit `--refresh-snapshots --jar ...` writes `snapshots.json` and updates
its manifest hash. Refreshes require review; ordinary tests cannot bless changed
reference behavior. The runner checks exact Java major versions, jar hashes,
upstream hashes and fixture hashes before work. It retains 90-second stage
limits. Artifact provenance includes exact tool versions and runner/manifest hashes.
The optional `--plan-tool` checks all 469 original source alternatives and the successful minimal fixtures against the independent
ANTLR snapshot, including transformed decision priority and every owner-reference
binding. The tool analyzes source without changing accepted grammars.

Numeric performance bounds for W lowering and runtime remain unmeasured; this
inventory does not claim to pass those later-wave gates.
